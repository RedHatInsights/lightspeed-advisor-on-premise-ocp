# The image is layered on top of the OCP rules. The image already
# contains the rule content, Python runtime, and /opt/venv used by the service.
FROM registry.redhat.io/lightspeed-services-ocp/ocp-rules-rhel9:2026.09.22

# Switch to root only for image assembly: installing RPMs/Python packages,
# modifying the base venv config, creating writable temp directories, and
# wiring in the inherited rule content. The final runtime user is reset below.
USER root

# Keep runtime state under /app, make Python logs stream immediately, disable
# interactive pip prompts, and use the system trust bundle for outbound HTTPS calls.
ENV HOME=/app \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    PIP_NO_INPUT=1 \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PYTHONUNBUFFERED=1

# Keeping the working directory stable also lets relative paths
# in config/defaults resolve predictably.
WORKDIR /app

# --- RPM dependencies -------------------------------------------------------
# Install the PostgreSQL driver as an RPM (python3.12-psycopg2, + libpq) rather
# than the compiled psycopg-binary wheel. psycopg2 is SQLAlchemy's default driver
# for the plain "postgresql://" URL. RPM modules are stored in /usr/lib*/python3.12/site-packages;
# make them visible inside /opt/venv by enabling system site packages.
# hadolint ignore=DL3041
RUN microdnf install --nodocs -y python3.12-psycopg2 && \
    microdnf clean all && \
    rm -rf /var/cache/dnf /var/cache/yum /var/tmp/* && \
    sed -i 's/^include-system-site-packages = false$/include-system-site-packages = true/' \
        /opt/venv/pyvenv.cfg

# Copy only the Python lockfile first so dependency installation can be cached
# independently from application source changes.
COPY requirements.txt .

# --- Create non-hashed Python dependency list for local build ----------------
# requirements.txt is Lightwell-resolved and hash-locked. Generate helper files
# for the two install paths: hashed uv bootstrap for Hermeto, and exact pins
# without Lightwell metadata for local public-PyPI builds. PyPI hashes are
# different than the ones in Lightwell.
RUN python - <<'PY'
from pathlib import Path
import re
requirements = Path("requirements.txt").read_text().splitlines()
# Keep the Lightwell index and the complete uv block, including hashes, so
# Hermeto can bootstrap the pinned uv wheel from its prefetched artifacts.
uv_bootstrap = [line for line in requirements if line.startswith("--index-url ")]
emit_uv = False
for line in requirements:
    if line.startswith("uv=="):
        emit_uv = True
    if emit_uv:
        uv_bootstrap.append(line)
    if emit_uv and line.startswith("    # via"):
        break
# Keep exact package pins for local builds, but remove Lightwell-only metadata
# that would make public PyPI installs fail.
local_public_pypi = []
for line in requirements:
    stripped = line.strip()
    if (
        not stripped
        or line.startswith("--index-url ")
        or stripped.startswith("--hash=")
        or stripped.startswith("#")
    ):
        continue
    local_public_pypi.append(re.sub(r"\s*\\\s*$", "", line))
Path("/tmp/uv-requirements.txt").write_text("\n".join(uv_bootstrap) + "\n")
Path("/tmp/requirements-no-hashes.txt").write_text("\n".join(local_public_pypi) + "\n")
PY

# --- Install Python dependencies -----------------------------------------------
# Konflux/Hermeto uses /cachi2 prefetched wheels and installs fully offline.
# Local builds do not have /cachi2, so they install the same pinned versions
# from public PyPI. uv is removed afterwards because it is only a build-time installer.
RUN set -eu; \
    if [ -f /cachi2/cachi2.env ]; then \
        . /cachi2/cachi2.env; \
        pip install --no-cache-dir --require-hashes --no-deps \
            --no-index \
            --find-links "${PIP_FIND_LINKS}" \
            -r /tmp/uv-requirements.txt; \
        uv pip install \
            --python "${VIRTUAL_ENV}/bin/python" \
            --offline \
            --no-index \
            --find-links "${PIP_FIND_LINKS}" \
            --no-cache \
            -r requirements.txt; \
        uv pip check --python "${VIRTUAL_ENV}/bin/python"; \
    else \
        pip install --no-cache-dir \
            --index-url https://pypi.org/simple \
            -r /tmp/requirements-no-hashes.txt; \
        pip check; \
    fi; \
    pip uninstall -y uv; \
    find "${VIRTUAL_ENV}" -type d -name __pycache__ -prune -exec rm -rf '{}' +; \
    rm -rf /root/.cache /tmp/*; \
    mkdir -p /tmp/insights-uploads; \
    chmod 777 /tmp/insights-uploads

# --- Application runtime files ---------------------------------------------
# Copy only the runtime inputs. Test files and local development artifacts are
# intentionally excluded from the final image.
COPY app ./app
COPY migrations ./migrations
COPY config.yml .

# The rules content is owned by the inherited base image. Expose it at the path
# expected by this application without copying the content into a second layer.
RUN ln -sf /ccx-rules-ocp/content /app/content

# HTTP and HTTPS ports used by the FastAPI/uvicorn service.
EXPOSE 8000 8443

# Drop privileges for runtime. UID 1001 matches the non-root convention used by
# Red Hat container images/OpenShift deployments.
USER 1001

# Override labels inherited from the OCP rules base image so release
# check-labels validates against the ACM product (lightspeed-services-acm).
LABEL name="lightspeed-services-acm/ocp-rules-rhel9" \
      cpe="cpe:/a:redhat:lightspeed_services_acm:0.1" \
      vendor="Red Hat, Inc." \
      summary="ACM recommendations powered by Red Hat Lightspeed" \
      io.k8s.display-name="ACM recommendations powered by Red Hat Lightspeed" \
      io.k8s.description="Based on lightspeed-services-ocp/ocp-rules-rhel9, \
this image runs OCP rules and provides recommendations for clusters in an ACM \
setup. Useful in disconnected environments where customers cannot send Insights \
Operator archives to Red Hat cloud."

# The base image may define an entrypoint for rule processing. Clear it so this
# image starts the FastAPI application directly.
ENTRYPOINT []
CMD ["python", "-m", "app.main"]
