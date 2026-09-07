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
# --no-emit-package drops pyyaml and charset-normalizer (a transitive dep of
# requests): both already ship in the base image's /opt/venv, so emitting their
# (compiled) wheels would only add dead weight to the hermetic prefetch. The
# runtime imports resolve against the base venv copies.
# psycopg is not listed in requirements-in.txt at all; it ships as the
# python3.12-psycopg2 RPM (see rpms.in.yaml), which the venv sees because the
# Dockerfile flips include-system-site-packages=true in /opt/venv/pyvenv.cfg.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${REPO_ROOT}"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found; install it (e.g. 'brew install uv' or 'pip install uv')." >&2
    exit 1
fi

uv pip compile requirements-in.txt \
    --generate-hashes \
    --python-version 3.12 \
    --python-platform x86_64-manylinux_2_34 \
    --no-emit-package pyyaml \
    --no-emit-package charset-normalizer \
    --output-file requirements.txt

echo "Updated requirements.txt"
