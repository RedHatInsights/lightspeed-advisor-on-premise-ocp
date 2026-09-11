# The image is layered on top of the OCP rules. The image already
# contains the rule content, Python runtime, and /opt/venv used by the service.
FROM registry.redhat.io/lightspeed-services-ocp/ocp-rules-rhel9:2026.09.08

# Switch to root only for image assembly: installing RPMs/Python packages,
# modifying the base venv config, creating writable temp directories, and
# wiring in the inherited rule content. The final runtime user is reset below.
USER root

# Keep runtime state under /app, make Python logs stream immediately, and use
# the system trust bundle for outbound HTTPS calls.
ENV HOME=/app \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PYTHONUNBUFFERED=1

# Keeping the working directory stable also lets relative paths
# in config/defaults resolve predictably.
WORKDIR /app

# Install the PostgreSQL driver as an RPM (python3.12-psycopg2, + libpq) rather
# than the compiled psycopg-binary wheel. psycopg2 is SQLAlchemy's default driver
# for the plain "postgresql://" URL. RPM modules are stored in /usr/lib*/python3.12/site-packages,
# Tell the /opt/venv to use system packages. (pyvenv.cfg contains include-system-site-packages=true)
# hadolint ignore=DL3041
RUN microdnf install --nodocs -y python3.12-psycopg2 && \
    microdnf clean all && \
    rm -rf /var/cache/dnf /var/cache/yum /var/tmp/* && \
    sed -i 's/^include-system-site-packages = false$/include-system-site-packages = true/' \
        /opt/venv/pyvenv.cfg

# Copy only the Python lockfile first so dependency installation can be cached
# independently from application source changes.
COPY requirements.txt .

# Install Python dependencies into the base image's /opt/venv using uv.
#
# uv itself is also pinned in requirements.txt. Since uv is the installer, pip is
# used only to bootstrap that single pinned package. The small temporary
# requirements file keeps the same index URL and hash-checking as the main
# lockfile, instead of letting pip fall back to public PyPI.
RUN { \
        grep '^--index-url ' requirements.txt; \
        awk '/^uv==/ { emit = 1 } emit { print } emit && /^    # via/ { exit }' requirements.txt; \
    } > /tmp/uv-requirements.txt && \
    /opt/venv/bin/pip install --no-cache-dir --require-hashes --no-deps \
        -r /tmp/uv-requirements.txt && \
    /opt/venv/bin/uv pip install --python /opt/venv/bin/python --no-cache \
        -r requirements.txt && \
    /opt/venv/bin/pip uninstall -y uv && \
    find /opt/venv -type d -name __pycache__ -prune -exec rm -rf '{}' + && \
    rm -rf /root/.cache /tmp/* && \
    mkdir -p /tmp/insights-uploads && chmod 777 /tmp/insights-uploads

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
