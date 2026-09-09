#!/bin/bash
# Regenerate requirements.txt from requirements-in.txt using uv.
#
# uv resolves for the *target* platform (linux/x86_64, manylinux/glibc, py3.12)
# regardless of host, so this runs on macOS/arm64 directly — no linux/amd64
# container needed (unlike the old pip-compile workflow).
#
# requirements-build.txt is intentionally NOT generated: the Hermeto pip prefetch
# prefers binary wheels (see .tekton/*.yaml "binary" filter), so deps are fetched
# as wheels rather than built from source.
#
# Nothing is filtered out of the resolution: every dependency is pinned, including
# charset-normalizer (a transitive dep of requests), which the base image's /opt/venv
# also ships — pip installs the pinned version over the base copy.
# psycopg is not listed in requirements-in.txt at all; it ships as the
# python3.12-psycopg2 RPM (see rpms.in.yaml), which the venv sees because the
# Dockerfile flips include-system-site-packages=true in /opt/venv/pyvenv.cfg.
#
# Index flags:
#   --index-url       resolve from Red Hat's trusted-libraries index instead of PyPI.
#                     Hermeto reads the index out of requirements.txt, so no .tekton
#                     change is needed.
#   --emit-index-url  write the "--index-url ..." directive into requirements.txt.
#                     Without it the directive is dropped and both Hermeto and the
#                     Dockerfile's pip install silently fall back to PyPI.
#   --upgrade         required for correctness, not freshness. uv reads the existing
#                     output file as resolution preferences *including its --hash
#                     lines*, so without --upgrade any package whose version doesn't
#                     change keeps its old hashes. Red Hat rebuilds wheels, so those
#                     hashes would not match this index and the hermetic build would
#                     fail hash checking. The cost is that each run re-resolves to the
#                     newest version the index carries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${REPO_ROOT}"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found; install it (e.g. 'brew install uv' or 'pip install uv')." >&2
    exit 1
fi

# Red Hat's curated "trusted libraries" index. Its wheels are Red Hat rebuilds
# carrying a build tag (e.g. certifi-2026.6.17-0-py3-none-any.whl), so their hashes
# differ from PyPI's for the same version: the lockfile has to be *resolved* against
# this index, not merely annotated with it.
INDEX_URL="${INDEX_URL:-https://packages.redhat.com/trusted-libraries/python/}"

uv pip compile requirements-in.txt \
    --index-url "${INDEX_URL}" \
    --emit-index-url \
    --upgrade \
    --generate-hashes \
    --python-version 3.12 \
    --python-platform x86_64-manylinux_2_34 \
    --output-file requirements.txt

echo "Updated requirements.txt"
