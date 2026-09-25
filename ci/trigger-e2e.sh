#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $0 [options] [commit-sha]

Finds the Konflux Snapshot built from the given commit and triggers the
IOP e2e test pipeline via the IntegrationTestScenario (${ITS_NAME}).

If no commit is provided, uses HEAD of the current git repo.

Options:
  -f, --force            Retrigger (removes label first, then re-adds)
  -d, --debug            Hold clusters on failure. Labels the PipelineRun
                         with debug.iop/hold-on-failure=true so the finally
                         task dumps credentials and sleeps on failure.
  -t, --test-filter STR  Label the PipelineRun with debug.iop/test-filter=STR
                         so the test task reads it at runtime.
  -h, --help             Show this help

Requires: oc (logged into the Konflux cluster), jq
EOF
  exit 1
}

# --- Konflux queries (each prints one value on stdout) ---------------------

snapshot_for_commit() {
  oc get snapshot -n "${NAMESPACE}" \
    -l "appstudio.openshift.io/component=${COMPONENT}" -o json \
    | jq -r --arg rev "$1" \
        '.items[] | select(.spec.components[]?.source.git.revision | startswith($rev)) | .metadata.name' \
    | head -1
}

image_for_snapshot() {
  oc get snapshot "$1" -n "${NAMESPACE}" -o json \
    | jq -r --arg comp "${COMPONENT}" \
        '.spec.components[] | select(.name == $comp) | .containerImage'
}

# Wait until the integration service creates the PipelineRun for this Snapshot,
# then print its name. Provisioning takes 10+ min, so labeling the run here is
# always in place before any task reads its labels.
wait_for_pipelinerun() {
  local snapshot="$1" elapsed=0 plr=""
  while [[ -z "${plr}" ]]; do
    if (( elapsed >= 120 )); then
      echo "ERROR: PipelineRun not created after 2 minutes" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    plr=$(oc get pipelinerun -n "${NAMESPACE}" \
      -l "appstudio.openshift.io/snapshot=${snapshot},test.appstudio.openshift.io/scenario=${ITS_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  done
  echo "${plr}"
}

# --- Parse arguments -------------------------------------------------------

FORCE=false
DEBUG=false
TEST_FILTER=""

while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -f|--force) FORCE=true; shift ;;
    -d|--debug) DEBUG=true; shift ;;
    -t|--test-filter) TEST_FILTER="${2:?--test-filter requires a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

COMMIT="${1:-$(git rev-parse HEAD)}"
SHORT_SHA="${COMMIT:0:7}"

# --- Find the Snapshot for the commit --------------------------------------

echo "Looking for Snapshot matching commit ${SHORT_SHA} in ${NAMESPACE}..."
SNAPSHOT_NAME=$(snapshot_for_commit "${COMMIT}")

if [[ -z "${SNAPSHOT_NAME}" ]]; then
  echo "ERROR: No Snapshot found for commit ${SHORT_SHA}."
  echo "The build may not have completed yet. Check with:"
  echo "  oc get snapshot -n ${NAMESPACE} -l appstudio.openshift.io/component=${COMPONENT}"
  exit 1
fi

echo "Found Snapshot: ${SNAPSHOT_NAME}"
echo "Image:          $(image_for_snapshot "${SNAPSHOT_NAME}")"
echo ""

# --- Trigger by labeling the Snapshot --------------------------------------

echo "Labeling Snapshot to trigger ${ITS_NAME}..."

if [[ "${FORCE}" == "true" ]]; then
  oc label "snapshot/${SNAPSHOT_NAME}" "test.appstudio.openshift.io/run-" \
    -n "${NAMESPACE}" 2>/dev/null || true
fi

oc label "snapshot/${SNAPSHOT_NAME}" "test.appstudio.openshift.io/run=${ITS_NAME}" \
  -n "${NAMESPACE}"

# --- Attach debug labels to the PipelineRun (only if requested) ------------

if [[ "${DEBUG}" != "true" && -z "${TEST_FILTER}" ]]; then
  echo "Done. Monitor the PipelineRun with:"
  echo "  oc get pipelinerun -n ${NAMESPACE} -l appstudio.openshift.io/snapshot=${SNAPSHOT_NAME} --watch"
  exit 0
fi

echo ""
echo "Waiting for PipelineRun to be created..."
PIPELINE_RUN=$(wait_for_pipelinerun "${SNAPSHOT_NAME}")
echo "PipelineRun: ${PIPELINE_RUN}"

if [[ "${DEBUG}" == "true" ]]; then
  oc label "pipelinerun/${PIPELINE_RUN}" "debug.iop/hold-on-failure=true" -n "${NAMESPACE}"
  echo "  Labeled: debug.iop/hold-on-failure=true"
fi

if [[ -n "${TEST_FILTER}" ]]; then
  oc label "pipelinerun/${PIPELINE_RUN}" "debug.iop/test-filter=${TEST_FILTER}" -n "${NAMESPACE}"
  echo "  Labeled: debug.iop/test-filter=${TEST_FILTER}"
fi

echo ""
echo "Monitor with:"
echo "  oc get pipelinerun ${PIPELINE_RUN} -n ${NAMESPACE} --watch"

if [[ "${DEBUG}" == "true" ]]; then
  echo ""
  echo "On failure, check logs for credentials:"
  echo "  oc logs -n ${NAMESPACE} ${PIPELINE_RUN}-hold-clusters-on-failure-pod print-credentials-and-wait"
  echo ""
  echo "When done debugging, cancel with:"
  echo "  oc patch pipelinerun ${PIPELINE_RUN} -n ${NAMESPACE} --type merge -p '{\"spec\":{\"status\":\"CancelledRunFinally\"}}'"
fi
