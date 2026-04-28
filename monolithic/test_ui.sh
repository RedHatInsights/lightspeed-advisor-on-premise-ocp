#!/bin/bash
# test_ui.sh - Sets up test data to verify all four Insights sections in the ACM fleet overview UI.
#
# Prerequisites: addon must be deployed (monolithic/addon/).
# The addon handles console image, UPGRADE_RISKS_PREDICTION_URL, and CCX_SERVER via policies.
#
# Results are visible at: https://<your-cluster>/multicloud/home/overview

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_TESTS="$SCRIPT_DIR/tests/ui"
CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}')
NS="insights-on-prem"
EXPECTED_CONSOLE_IMAGE="quay.io/stolostron/console:latest-2.17"

echo "=== Insights On-Premise UI Test Setup ==="
echo "Cluster ID: $CLUSTER_ID"
echo ""

# ---------------------------------------------------------------------------
echo "1. Triggering cluster recommendations..."
# ---------------------------------------------------------------------------
oc apply -f "$UI_TESTS/webhook-trigger.yaml"
oc patch configs.samples.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

# ---------------------------------------------------------------------------
echo ""
echo "2. Creating test data for update risk predictions and failing operators..."
# ---------------------------------------------------------------------------
oc apply -f "$UI_TESTS/critical-alerts.yaml"

# ---------------------------------------------------------------------------
echo ""
echo "3. Configuring on-prem service to query current Thanos data..."
# ---------------------------------------------------------------------------
# Override lookback to 0 so freshly fired alerts are visible immediately.
# Default (60 min) is intentional for production — this is test-only.
oc set env deployment/insights-on-prem -n $NS THANOS_QUERY_LOOKBACK_MINUTES=0
oc rollout status deployment/insights-on-prem -n $NS --timeout=60s

# ---------------------------------------------------------------------------
echo ""
echo "4. Getting route for URP verification..."
# ---------------------------------------------------------------------------
# Route is created by the addon — just look it up.
ON_PREM_ROUTE=$(oc get route insights-on-prem -n $NS -o jsonpath='{.spec.host}')
ON_PREM_URP_URL="https://${ON_PREM_ROUTE}/api/insights-results-aggregator/v2/upgrade-risks-prediction"
echo "   Route: $ON_PREM_URP_URL"

# ---------------------------------------------------------------------------
echo ""
echo "5. Waiting for insights-operator to upload and recommendations to appear..."
# ---------------------------------------------------------------------------
REC_COUNT=0
for i in $(seq 1 10); do
  REC_COUNT=$(curl -sk "https://${ON_PREM_ROUTE}/api/v2/cluster/${CLUSTER_ID}/reports" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('report',{}).get('meta',{}).get('count',0))" 2>/dev/null || echo 0)
  echo "   $(date '+%H:%M:%S') recommendations from on-prem: ${REC_COUNT}"
  [ "${REC_COUNT:-0}" -gt 0 ] && break
  sleep 30
done

# ---------------------------------------------------------------------------
echo ""
echo "6. Waiting for alerts to reach Thanos (~2-5 min)..."
# ---------------------------------------------------------------------------
TOKEN=$(oc exec deployment/insights-on-prem -n $NS -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ALERT_COUNT=0
for i in $(seq 1 10); do
  ALERT_COUNT=$(oc exec deployment/insights-on-prem -n $NS -- sh -c \
    "curl -sk -H 'Authorization: Bearer $TOKEN' \
     'https://rbac-query-proxy.open-cluster-management-observability.svc.cluster.local:8443/api/v1/query' \
     --data-urlencode 'query=ALERTS{alertname=~\"InsightsTest.*\"}' 2>/dev/null" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo 0)
  echo "   $(date '+%H:%M:%S') alerts in Thanos: ${ALERT_COUNT}"
  [ "${ALERT_COUNT:-0}" -gt 0 ] && break
  sleep 30
done

# ---------------------------------------------------------------------------
echo ""
echo "7. Verifying end-to-end..."
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
check() {
  if [ "$2" = "ok" ]; then echo "  [PASS] $1"; PASS=$((PASS+1))
  else echo "  [FAIL] $1 — $2"; FAIL=$((FAIL+1)); fi
}

# Console image check
ACTUAL_IMAGE=$(oc get pods -n open-cluster-management -l name=console-chart-console-v2 \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || \
  oc get pods -n open-cluster-management | grep console-chart | awk '{print $1}' | head -1 | \
  xargs oc get pod -n open-cluster-management -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
check "console running expected image ($EXPECTED_CONSOLE_IMAGE)" \
  "$([ "$ACTUAL_IMAGE" = "$EXPECTED_CONSOLE_IMAGE" ] && echo ok || echo "got: $ACTUAL_IMAGE")"

check "recommendations served from on-prem (count > 0)" \
  "$([ "${REC_COUNT:-0}" -gt 0 ] && echo ok || echo "got 0 — archive not uploaded yet")"

# URP from on-prem
URP_RESULT=$(curl -sk -X POST "$ON_PREM_URP_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"clusters\": [\"$CLUSTER_ID\"]}" 2>/dev/null)
HAS_ALERTS=$(echo "$URP_RESULT" | grep -c "InsightsTestCriticalAlert" || true)
UPGRADE_RECOMMENDED=$(echo "$URP_RESULT" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); p=d.get('predictions',[]); print(p[0].get('upgrade_recommended','?') if p else '?')" 2>/dev/null)
check "URP endpoint returns cluster-local fake alerts from on-prem" \
  "$([ "${HAS_ALERTS:-0}" -gt 0 ] && echo ok || echo "alerts not found (Thanos had ${ALERT_COUNT:-0})")"
check "URP endpoint returns upgrade_recommended=False" \
  "$([ "$UPGRADE_RECOMMENDED" = "False" ] && echo ok || echo "got: $UPGRADE_RECOMMENDED")"

# Console calling on-prem for URP (not console.redhat.com)
URP_CALLS=$(oc logs -n $NS deployment/insights-on-prem --since=10m 2>/dev/null | \
  grep "upgrade-risks-prediction" | grep -v "gathering" | wc -l | tr -d ' ')
check "console is calling on-prem URP endpoint (not console.redhat.com)" \
  "$([ "${URP_CALLS:-0}" -gt 0 ] && echo ok || echo "no URP calls seen in on-prem logs")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
echo "=== Done ==="
echo "Check the UI at: https://$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' | sed 's|https://api\.|console-openshift-console.apps.|' | sed 's|:6443||')/multicloud/home/overview"
echo ""
echo "To clean up:"
echo "  oc delete validatingwebhookconfiguration insights-test-webhook"
echo "  oc patch configs.samples.operator.openshift.io cluster --type merge -p '{\"spec\":{\"managementState\":\"Managed\"}}'"
echo "  oc delete prometheusrule insights-test-alerts -n openshift-monitoring"
echo "  oc set env deployment/insights-on-prem -n $NS THANOS_QUERY_LOOKBACK_MINUTES-"
