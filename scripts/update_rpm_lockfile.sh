#!/bin/bash

# Update rpms.lock.yaml using rpm-lockfile-prototype.
#
# rpms.in.yaml makes the Dockerfile the source of truth: rpm-lockfile-prototype
# scans RUN dnf/yum/microdnf install commands and then resolves their transitive
# RPM dependencies. For example, adding python3.12-psycopg2 to the Dockerfile
# causes libpq to be locked as well.
#
# Resolution uses the public UBI 9 repos, so NO Red Hat entitlement
# (subscription-manager / activation key) is needed to regenerate the lockfile.
# To satisfy Enterprise Contract's known-RPM-repo policy and match the legacy
# lockfile shape, the generated lockfile is emitted with the corresponding RHEL
# repo IDs and cdn.redhat.com download URLs. The RPM checksums remain the ones
# resolved from UBI.
#
# The only auth required locally is a registry.redhat.io pull secret so skopeo
# can inspect the Dockerfile's base image.
#
# Must run on linux/amd64 (rpm-lockfile-prototype resolves for the target arch).
# Prefer:
#
#   podman run --rm --platform linux/amd64 \
#     -v "$(pwd):/work:Z" -w /work \
#     registry.access.redhat.com/ubi9/ubi \
#     bash scripts/update_rpm_lockfile.sh
#
# On macOS, omit the SELinux relabel suffix and use -v "$(pwd):/work".
#
# Requires:
#   scripts/.dockerconfig.json  (registry.redhat.io pull auth, used by skopeo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INPUT_FILE="${REPO_ROOT}/rpms.in.yaml"
OUTPUT_FILE="${REPO_ROOT}/rpms.lock.yaml"
REPO_FILE="${REPO_ROOT}/redhat.repo"
DOCKERFILE="${REPO_ROOT}/Dockerfile"
DOCKERCONFIG_FILE="${SCRIPT_DIR}/.dockerconfig.json"
RPM_LOCKFILE_PROTOTYPE="${RPM_LOCKFILE_PROTOTYPE:-${HOME}/.local/bin/rpm-lockfile-prototype}"

print_podman_hint() {
    local volume_mount="${REPO_ROOT}:/work"
    if [ "$(uname -s)" = "Linux" ]; then
        volume_mount="${volume_mount}:Z"
    fi

    echo "Run it in a linux/amd64 UBI container with:" >&2
    echo "" >&2
    echo "  podman run --rm --platform linux/amd64 \\" >&2
    echo "    -v \"${volume_mount}\" -w /work \\" >&2
    echo "    registry.access.redhat.com/ubi9/ubi \\" >&2
    echo "    bash scripts/update_rpm_lockfile.sh" >&2
}

cd "${REPO_ROOT}"

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "Error: must run on Linux x86_64 (got $(uname -s)/$(uname -m))." >&2
    print_podman_hint
    exit 1
fi

if [ ! -f "${INPUT_FILE}" ]; then
    echo "Error: Input file not found: ${INPUT_FILE}" >&2
    exit 1
fi

if [ ! -f "${DOCKERFILE}" ]; then
    echo "Error: Dockerfile not found: ${DOCKERFILE}" >&2
    exit 1
fi

if [ ! -f "${DOCKERCONFIG_FILE}" ]; then
    echo "Error: Registry auth file not found: ${DOCKERCONFIG_FILE}" >&2
    echo "Required so skopeo can pull the base image from registry.redhat.io." >&2
    exit 1
fi

BASE_IMAGE="${BASE_IMAGE:-$(awk '
    toupper($1) == "FROM" {
        for (i = 2; i <= NF; i++) {
            if ($i !~ /^--/) {
                print $i
                exit
            }
        }
    }
' "${DOCKERFILE}")}"

if [ -z "${BASE_IMAGE}" ]; then
    echo "Error: could not determine base image from ${DOCKERFILE}" >&2
    exit 1
fi

IMAGE_DIR="$(mktemp -d)"

echo "Updating RPM lockfile..."
echo "Input:      ${INPUT_FILE}"
echo "Dockerfile: ${DOCKERFILE}"
echo "Base image: ${BASE_IMAGE}"
echo "Output:     ${OUTPUT_FILE}"
echo ""

# The transient redhat.repo is referenced by rpms.in.yaml but not committed. It
# is generated from the base image's public UBI repo definitions with RHEL repo
# IDs, so dependency resolution still uses UBI content while the lockfile records
# Enterprise Contract-known repository IDs.
cleanup() {
    rm -f "${REPO_FILE}"
    rm -rf "${IMAGE_DIR}"
}
trap cleanup EXIT

dnf install -y python3-pip python3-dnf skopeo git
# pip --user installs the rpm-lockfile-prototype console script under ~/.local/bin
# in the UBI container. RPM_LOCKFILE_PROTOTYPE can override that path when the
# tool is preinstalled elsewhere.
python3 -m pip install --user git+https://github.com/konflux-ci/rpm-lockfile-prototype.git

export REGISTRY_AUTH_FILE="${DOCKERCONFIG_FILE}"

# rpm-lockfile-prototype reads the repo definitions from ./redhat.repo. Build it
# from the base image's /etc/yum.repos.d/ubi.repo so package metadata and hashes
# come from public UBI, but rename repo section IDs to their RHEL counterparts.
skopeo copy --override-arch amd64 "docker://${BASE_IMAGE}" "dir:${IMAGE_DIR}"
python3 "${SCRIPT_DIR}/lib_rpm_lockfile.py" extract-repo "${IMAGE_DIR}" "${REPO_FILE}"

"${RPM_LOCKFILE_PROTOTYPE}" "${INPUT_FILE}" --outfile "${OUTPUT_FILE}"

# The resolver used public UBI baseurls above. Emit legacy/RHEL download URLs in
# the lockfile while preserving the UBI-resolved package checksums.
python3 "${SCRIPT_DIR}/lib_rpm_lockfile.py" rewrite-lockfile "${OUTPUT_FILE}"

if [ ! -s "${OUTPUT_FILE}" ]; then
    echo "Error: Output file is empty or was not created" >&2
    exit 1
fi

echo "Successfully updated ${OUTPUT_FILE}"
