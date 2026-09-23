# hadolint ignore=DL3007  # We prefer to use latest as this image is not used in production
FROM registry.redhat.io/openshift4/ose-cli-rhel9:latest AS oc-source

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

# oc client, copied from the OpenShift CLI image.
COPY --from=oc-source /usr/bin/oc /usr/bin/oc

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

USER 1001
