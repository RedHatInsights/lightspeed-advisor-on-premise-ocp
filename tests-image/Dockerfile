# hadolint ignore=DL3007  # We prefer to use latest as this image is not used in production
FROM registry.access.redhat.com/ubi9/ubi:latest AS oc-builder
# Bake a stable oc client into the image so the e2e step doesn't download one at
# runtime. We only use standard oc commands, so the latest stable client is fine
# against any recent cluster version.
RUN curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        -o /tmp/oc.tar.gz \
    && tar -xzf /tmp/oc.tar.gz -C /usr/bin oc

# hadolint ignore=DL3007  # We prefer to use latest as this image is not used in production
FROM registry.access.redhat.com/ubi9-minimal:latest

ENV HOME=/tests \
    VENV=/tests-venv \
    PYTHONUNBUFFERED=1 \
    PATH="/tests-venv/bin:$PATH"

WORKDIR $HOME

# hadolint ignore=DL3013,DL3041 # it's fine not to pin pip versions
RUN microdnf install --nodocs -y \
        python3.12 \
        curl-minimal \
        tar \
        jq \
    && python3.12 -m venv $VENV \
    && pip install --no-cache-dir -U pip setuptools wheel \
    && microdnf clean all

# oc client, baked from the builder stage above.
COPY --from=oc-builder /usr/bin/oc /usr/bin/oc

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

USER 1001
