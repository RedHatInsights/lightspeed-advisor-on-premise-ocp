#!/bin/bash

# Update rpms.lock.yaml using rpm-lockfile-prototype.
#
# Unlike the old build-tool lockfile, every package in rpms.in.yaml lives in the
# public UBI 9 repos, so NO Red Hat entitlement (subscription-manager /
# activation key) is needed. The only auth required is a registry.redhat.io pull
# secret so skopeo can inspect the base image referenced by rpms.in.yaml's
# context.image.
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
REPO_FILE="${REPO_ROOT}/ubi.repo"
DOCKERCONFIG_FILE="${SCRIPT_DIR}/.dockerconfig.json"
BASE_IMAGE="registry.redhat.io/lightspeed-services-ocp/ocp-rules-rhel9:2026.08.25"
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

if [ ! -f "${DOCKERCONFIG_FILE}" ]; then
    echo "Error: Registry auth file not found: ${DOCKERCONFIG_FILE}" >&2
    echo "Required so skopeo can pull the base image from registry.redhat.io." >&2
    exit 1
fi

echo "Updating RPM lockfile..."
echo "Input:  ${INPUT_FILE}"
echo "Output: ${OUTPUT_FILE}"
echo ""

# The transiently-extracted ubi.repo is referenced by rpms.in.yaml but not
# committed (it just mirrors the base image's public UBI repo definitions).
cleanup() {
    rm -f "${REPO_FILE}"
}
trap cleanup EXIT

dnf install -y python3-pip skopeo git
python3 -m pip install --user git+https://github.com/konflux-ci/rpm-lockfile-prototype.git

export REGISTRY_AUTH_FILE="${DOCKERCONFIG_FILE}"

# rpm-lockfile-prototype reads the repo definitions from ./ubi.repo. Pull them
# straight out of the base image so they always match what's available at build
# time (the image ships them in /etc/yum.repos.d/ubi.repo).
skopeo copy "docker://${BASE_IMAGE}" dir:/tmp/base-image
python3 - "$REPO_FILE" <<'PY'
import glob, json, os, subprocess, sys, tarfile
out = sys.argv[1]
manifest = json.load(open("/tmp/base-image/manifest.json"))
for layer in manifest["layers"]:
    digest = layer["digest"].split(":", 1)[1]
    path = os.path.join("/tmp/base-image", digest)
    try:
        with tarfile.open(path) as tf:
            m = tf.extractfile("etc/yum.repos.d/ubi.repo")
            if m:
                open(out, "wb").write(m.read())
                print(f"Extracted ubi.repo from layer {digest[:12]}")
    except (KeyError, tarfile.TarError):
        continue
if not os.path.exists(out):
    sys.exit("Error: could not find /etc/yum.repos.d/ubi.repo in base image layers")
PY

~/.local/bin/rpm-lockfile-prototype rpms.in.yaml --outfile rpms.lock.yaml

if [ ! -s "${OUTPUT_FILE}" ]; then
    echo "Error: Output file is empty or was not created" >&2
    exit 1
fi

echo "Successfully updated ${OUTPUT_FILE}"
