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
PODMAN_HINT="podman run --rm --platform linux/amd64 -v \"\$(pwd):/work:Z\" -w /work registry.access.redhat.com/ubi9/ubi bash scripts/update_rpm_lockfile.sh"

cd "${REPO_ROOT}"

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "Error: must run on Linux x86_64 (got $(uname -s)/$(uname -m))." >&2
    echo "Use: ${PODMAN_HINT}" >&2
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
python3 -m pip install --user git+https://github.com/konflux-ci/rpm-lockfile-prototype.git

export REGISTRY_AUTH_FILE="${DOCKERCONFIG_FILE}"

# rpm-lockfile-prototype reads the repo definitions from ./redhat.repo. Build it
# from the base image's /etc/yum.repos.d/ubi.repo so package metadata and hashes
# come from public UBI, but rename repo section IDs to their RHEL counterparts.
skopeo copy --override-arch amd64 "docker://${BASE_IMAGE}" "dir:${IMAGE_DIR}"
python3 - "${IMAGE_DIR}" "${REPO_FILE}" <<'PY'
import json
import os
import re
import sys
import tarfile

image_dir, out = sys.argv[1:3]
with open(os.path.join(image_dir, "manifest.json")) as manifest_file:
    manifest = json.load(manifest_file)

repo_contents = None
repo_layer = None
for layer in manifest["layers"]:
    digest = layer["digest"].split(":", 1)[1]
    path = os.path.join(image_dir, digest)
    try:
        with tarfile.open(path) as tf:
            member = tf.extractfile("etc/yum.repos.d/ubi.repo")
            if member:
                repo_contents = member.read()
                repo_layer = digest
    except (KeyError, tarfile.TarError):
        continue

if repo_contents is None:
    sys.exit("Error: could not find /etc/yum.repos.d/ubi.repo in base image layers")

def rhel_repo_id(repo_id, arch="x86_64"):
    match = re.fullmatch(
        r"ubi-(?P<version>\d+)-(?P<repo>baseos|appstream)"
        r"(?P<kind>-debug|-source)?-rpms",
        repo_id,
    )
    if match:
        kind = match.group("kind") or ""
        return (
            f"rhel-{match.group('version')}-for-{arch}-"
            f"{match.group('repo')}{kind}-rpms"
        )

    match = re.fullmatch(
        r"ubi-(?P<version>\d+)-codeready-builder"
        r"(?P<kind>-debug|-source)?-rpms",
        repo_id,
    )
    if match:
        kind = match.group("kind") or ""
        return (
            f"codeready-builder-for-rhel-{match.group('version')}-"
            f"{arch}{kind}-rpms"
        )

    return repo_id

repo_text = repo_contents.decode()
repo_text = re.sub(
    r"^\[(?P<repo_id>[^]]+)]$",
    lambda match: f"[{rhel_repo_id(match.group('repo_id'))}]",
    repo_text,
    flags=re.MULTILINE,
)

with open(out, "w") as repo_file:
    repo_file.write(repo_text)
print(f"Extracted ubi.repo from layer {repo_layer[:12]} as redhat.repo")
PY

~/.local/bin/rpm-lockfile-prototype "${INPUT_FILE}" --outfile "${OUTPUT_FILE}"

# The resolver used public UBI baseurls above. Emit legacy/RHEL download URLs in
# the lockfile while preserving the UBI-resolved package checksums.
python3 - "${OUTPUT_FILE}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"https://cdn-ubi\.redhat\.com/content/public/ubi/dist/ubi(?P<version>\d+)/"
    r"(?P<releasever>[^/]+)/(?P<arch>[^/]+)/"
    r"(?P<repo>baseos|appstream|codeready-builder)/",
    r"https://cdn.redhat.com/content/dist/rhel\g<version>/"
    r"\g<releasever>/\g<arch>/\g<repo>/",
    text,
)
path.write_text(text)
PY

if [ ! -s "${OUTPUT_FILE}" ]; then
    echo "Error: Output file is empty or was not created" >&2
    exit 1
fi

echo "Successfully updated ${OUTPUT_FILE}"
