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
# for the plain "postgresql://" URL. RPM modules are stored in
# /usr/lib*/python3.12/site-packages; make them visible inside /opt/venv by
# enabling system site packages.
# hadolint ignore=DL3041
RUN microdnf install --nodocs -y python3.12-psycopg2 && \
    microdnf clean all && \
    rm -rf /var/cache/dnf /var/cache/yum /var/tmp/* && \
    sed -i 's/^include-system-site-packages = false$/include-system-site-packages = true/' \
        /opt/venv/pyvenv.cfg

# Copy only the Python lockfile first so dependency installation can be cached
# independently from application source changes.
COPY requirements.txt .

# --- Install uv dependency helper ------------------------------------------
# Extract the pinned uv version and install just that wheel first so later
# dependency installation can consistently use uv.
RUN UV_VERSION="$(sed -n 's/^uv==\([^[:space:]\\]*\).*/\1/p' requirements.txt)" && \
    if [ -f /cachi2/cachi2.env ]; then \
        . /cachi2/cachi2.env; \
    fi && \
    pip install --no-cache-dir --no-deps "uv==${UV_VERSION}"

# --- Install Python dependencies -------------------------------------------
# Konflux/Hermeto uses /cachi2 prefetched wheels and installs fully offline.
# Local builds do not have /cachi2, so uv overrides the Lightwell index with
# public PyPI and ignores Lightwell hashes. Build-only packaging tools are
# removed afterwards to keep the runtime image lean.
RUN if [ -f /cachi2/cachi2.env ]; then \
        . /cachi2/cachi2.env && \
        export UV_OFFLINE=1 && \
        export UV_FIND_LINKS="${PIP_FIND_LINKS}" && \
        UV_INDEX_ARGS="--no-index"; \
    else \
        export UV_DEFAULT_INDEX=https://pypi.org/simple && \
        export UV_NO_VERIFY_HASHES=1 && \
        UV_INDEX_ARGS=""; \
    fi && \
    uv pip install --python "${VIRTUAL_ENV}/bin/python" ${UV_INDEX_ARGS:+"${UV_INDEX_ARGS}"} --no-cache -r requirements.txt && \
    # Verify installed packages have compatible dependencies
    uv pip check --python "${VIRTUAL_ENV}/bin/python" && \
    # Cleanup Python deps install
    pip uninstall -y uv pip setuptools wheel packaging && \
    find "${VIRTUAL_ENV}" -type d -name __pycache__ -prune -exec rm -rf '{}' + && \
    rm -rf /root/.cache /tmp/*

# --- Application runtime files ---------------------------------------------
# Copy only the runtime inputs. Test files and local development artifacts are
# intentionally excluded from the final image.
COPY app ./app
COPY migrations ./migrations
COPY config.yml .

# --- Runtime filesystem setup ----------------------------------------------
# The service stages uploaded archives under /tmp/insights-uploads. Keep that
# directory writable for the non-root runtime user and OpenShift's arbitrary UID
# model. The rules content is owned by the inherited base image, so expose it at
# the expected application path without copying it into a second layer.
RUN mkdir -p /tmp/insights-uploads && \
    chmod 777 /tmp/insights-uploads && \
    ln -sf /ccx-rules-ocp/content /app/content

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
