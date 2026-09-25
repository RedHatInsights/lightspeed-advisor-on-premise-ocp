#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 [pipelinerun-name]

Reads the kubeconfigs produced by the provision-ephemeral-cluster tasks
and creates two oc contexts: ${HUB_CONTEXT} and ${MANAGED_CONTEXT}.

If no PipelineRun name is given, finds the latest one with the
debug.iop/hold-on-failure=true label.

Note: the ephemeral clusters are HyperShift hosted clusters. They have
no kubeadmin password and no web-console login - authentication is via
the client certificate embedded in the kubeconfig (user: system:admin).

Requires: oc (logged into the Konflux cluster), base64
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# role -> oc context name
declare -A ROLE_CONTEXT=(
  [hub]="${HUB_CONTEXT}"
  [managed]="${MANAGED_CONTEXT}"
)

KUBECONFIG_TMP=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '${KUBECONFIG_TMP}'" EXIT

# --- Konflux queries -------------------------------------------------------

latest_held_pipelinerun() {
  oc get pipelinerun -n "${NAMESPACE}" \
    -l "test.appstudio.openshift.io/scenario=${ITS_NAME},debug.iop/hold-on-failure=true" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true
}

# The provision-<role> taskrun exposes a "secretRef" result naming a secret that
# holds the cluster's kubeconfig. Print that secret name.
provision_secret_for_role() {
  oc get taskrun -n "${NAMESPACE}" -l "tekton.dev/pipelineRun=${PIPELINE_RUN}" -o json \
    | jq -r --arg role "$1" \
        '.items[]
         | select(.metadata.name | test("provision-" + $role))
         | .status.results[]? | select(.name == "secretRef") | .value' \
    | head -1
}

# Decode the kubeconfig stored in a secret into $KUBECONFIG_TMP.
fetch_kubeconfig() {
  oc get secret -n "${NAMESPACE}" "$1" -o jsonpath='{.data.kubeconfig}' \
    | base64 -d > "${KUBECONFIG_TMP}"
  [[ -s "${KUBECONFIG_TMP}" ]]
}

# Build an oc context named $1 from the kubeconfig in $KUBECONFIG_TMP. We copy
# the cluster + client-cert credentials under unique names because both provision
# kubeconfigs use the same internal names (cluster/admin) and would collide on
# merge. HyperShift clusters have no password, so this is cert auth only.
create_context() {
  local ctx="$1" server cadata cert key
  server=$(KUBECONFIG="${KUBECONFIG_TMP}" oc config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  cadata=$(KUBECONFIG="${KUBECONFIG_TMP}" oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  cert=$(KUBECONFIG="${KUBECONFIG_TMP}" oc config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
  key=$(KUBECONFIG="${KUBECONFIG_TMP}" oc config view --raw -o jsonpath='{.users[0].user.client-key-data}')

  oc config delete-context "${ctx}" 2>/dev/null || true
  oc config delete-cluster "${ctx}" 2>/dev/null || true
  oc config delete-user "${ctx}-admin" 2>/dev/null || true

  oc config set-cluster "${ctx}" --server="${server}" >/dev/null
  if [[ -n "${cadata}" ]]; then
    oc config set "clusters.${ctx}.certificate-authority-data" "${cadata}" >/dev/null
  else
    oc config set "clusters.${ctx}.insecure-skip-tls-verify" true >/dev/null
  fi
  oc config set-credentials "${ctx}-admin" >/dev/null
  oc config set "users.${ctx}-admin.client-certificate-data" "${cert}" >/dev/null
  oc config set "users.${ctx}-admin.client-key-data" "${key}" >/dev/null
  oc config set-context "${ctx}" --cluster="${ctx}" --user="${ctx}-admin" >/dev/null

  echo "${server}"
}

print_cluster_summary() {
  local role="$1" ctx="$2"
  echo "=== ${role^^} CLUSTER ==="
  echo "  Context: ${ctx}"
  echo "  API:     $(oc --context="${ctx}" whoami --show-server 2>/dev/null || echo '?')"
  echo "  Console: $(oc --context="${ctx}" whoami --show-console 2>/dev/null || echo '?')"
  echo "  User:    $(oc --context="${ctx}" whoami 2>/dev/null || echo '?') (client-cert auth; no password / no web-console login)"
  echo ""
}

# --- Resolve the PipelineRun -----------------------------------------------

PIPELINE_RUN="${1:-}"
if [[ -z "${PIPELINE_RUN}" ]]; then
  echo "Looking for latest debug PipelineRun..."
  PIPELINE_RUN=$(latest_held_pipelinerun)
  if [[ -z "${PIPELINE_RUN}" ]]; then
    echo "ERROR: No PipelineRun found with debug.iop/hold-on-failure=true"
    echo "Either pass the PipelineRun name as argument or trigger with:"
    echo "  ci/trigger-e2e.sh --debug"
    exit 1
  fi
fi
echo "PipelineRun: ${PIPELINE_RUN}"

# --- Build one oc context per cluster --------------------------------------

ORIGINAL_CTX=$(oc config current-context 2>/dev/null || true)

for role in hub managed; do
  ctx="${ROLE_CONTEXT[$role]}"
  secret=$(provision_secret_for_role "${role}")

  if [[ -z "${secret}" ]]; then
    echo "ERROR: could not find provision-${role} secretRef for ${PIPELINE_RUN}."
    echo "The provision-${role} task may not have completed. Check with:"
    echo "  oc get taskrun -n ${NAMESPACE} -l tekton.dev/pipelineRun=${PIPELINE_RUN}"
    exit 1
  fi

  if ! fetch_kubeconfig "${secret}"; then
    echo "ERROR: secret ${secret} has no kubeconfig data."
    exit 1
  fi

  server=$(create_context "${ctx}")
  echo "  Created context ${ctx} -> ${server}"
done

# Restore whatever context was active before.
[[ -n "${ORIGINAL_CTX}" ]] && oc config use-context "${ORIGINAL_CTX}" >/dev/null

echo ""
for role in hub managed; do
  print_cluster_summary "${role}" "${ROLE_CONTEXT[$role]}"
done

echo "Use with:"
echo "  oc --context=${HUB_CONTEXT} get nodes"
echo "  oc --context=${MANAGED_CONTEXT} get nodes"
echo ""
echo "Cancel the PipelineRun when done:"
echo "  oc patch pipelinerun ${PIPELINE_RUN} -n ${NAMESPACE} --type merge -p '{\"spec\":{\"status\":\"CancelledRunFinally\"}}'"
