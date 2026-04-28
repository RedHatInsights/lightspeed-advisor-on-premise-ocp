# Insights On-Prem ACM Addon

Deploys the Insights on-premise monolithic app to the ACM hub cluster (`local-cluster`) as a managed addon. Once deployed, all Insights data flows — archive uploads, recommendations, and upgrade risk predictions — are routed to the on-prem service instead of `console.redhat.com`.

## Prerequisites

- OpenShift 4.x on AWS
- ACM 2.16+ with MultiClusterHub in `Running` state
- MCO deployed (see below) — required for Thanos metrics used by upgrade risk predictions
- A pull secret for `quay.io/ccxdev/insights-on-premise-poc:latest` (the app image)

## Pull secret

The app image is private. Fill in the credentials in the secret file before deploying:

```
monolithic/addon/ccxdev-insights-on-prem-poc-secret.yml      # namespace: insights-on-prem
```

The file is gitignored. Robot account name: `ccxdev+insights_on_prem_poc`.

> The console image (`quay.io/stolostron/console:latest-2.17`) is public — no pull secret needed.

## Setting up MCO

Run from a clone of `stolostron/multicluster-observability-operator`:

```bash
kubectl create ns open-cluster-management-observability

# MinIO as the S3-compatible object storage backend (dev/testing only)
kubectl -n open-cluster-management-observability apply -k examples/minio

# Deploy the MCO CR — triggers Thanos receiver, store, query, compactor, alertmanager
kubectl apply -f operators/multiclusterobservability/config/samples/observability_v1beta2_multiclusterobservability.yaml

# Verify all pods come up healthy
kubectl -n open-cluster-management-observability get pod
```

## Install

```bash
cd monolithic/addon/

# 1. Namespaces — pre-creates both hub and workload namespaces
kubectl apply -f 01-namespace.yaml

# 2. App pull secret (fill in credentials first — see above)
kubectl apply -f ccxdev-insights-on-prem-poc-secret.yml

# 3. Addon resources — apply in this order (template before CMA to avoid reconciliation race)
kubectl apply -f 02-addon-template.yaml   # AddOnTemplate (workloads)
kubectl apply -f 03-addon.yaml            # ClusterManagementAddOn
kubectl apply -f 04-placement.yaml        # Placement (target clusters)
kubectl apply -f 05-policies.yaml         # ConfigurationPolicies
```

> The addon manager automatically creates the `ManagedClusterAddOn` on `local-cluster` based on the Placement.

## What gets deployed

### Workload (via AddOnTemplate → ManifestWork on local-cluster)

| Resource | Namespace | Purpose |
|---|---|---|
| Namespace | `insights-on-prem` | Workload namespace |
| PostgreSQL Deployment + PVC | `insights-on-prem` | Persistent database |
| insights-on-prem Deployment | `insights-on-prem` | FastAPI app (port 8000) |
| Route (edge TLS) | `insights-on-prem` | External HTTPS access for console URP calls |
| ConfigMap `insights-config` | `openshift-insights` | Redirects insights-operator uploads + report downloads to on-prem |

### Policies (enforced continuously, survive pod restarts)

| Policy | What it enforces |
|---|---|
| `insights-on-prem-mch-pause` | Pauses MCH so it doesn't revert the console image or other settings |
| `insights-on-prem-console` | Pins console to `stolostron/console:latest-2.17`, sets `UPGRADE_RISKS_PREDICTION_URL` in `console-config` ConfigMap dynamically from the route hostname |
| `insights-on-prem-insights-client` | Sets `CCX_SERVER` on the `insights-client` deployment to redirect recommendations to on-prem |
| `insights-on-prem-spoke-redirect` | Pushes `insights-config` to opted-in spoke clusters so their insights-operator also uploads to on-prem (opt in: `kubectl label managedcluster <name> insights-on-prem=true`) |

## Traffic flow

Once deployed, all Insights traffic flows to the on-prem service:

| Source | Endpoint | What it does |
|---|---|---|
| insights-operator | `http://insights-on-prem.insights-on-prem.svc:8000/api/ingress/v1/upload` | Uploads cluster archive |
| insights-operator | `http://insights-on-prem.insights-on-prem.svc:8000/api/v2/cluster/<id>/reports` | Downloads processed recommendations |
| insights-client | `http://insights-on-prem.insights-on-prem.svc:8000/api/v2` (CCX_SERVER) | Fetches recommendations for ACM UI |
| ACM console backend | `https://<route>/api/insights-results-aggregator/v2/upgrade-risks-prediction` | Fetches upgrade risk predictions for fleet overview |

> **Note:** insights-operator makes one call to `console.redhat.com/api/gathering/v2/.../gathering_rules` to fetch what data to collect. This is a separate config field not covered by `insights-config` and does not send any cluster data externally.

## Verify

```bash
# Addon status (should show Available: True)
kubectl get managedclusteraddon insights-on-prem -n local-cluster

# All workload pods running
kubectl get pod -n insights-on-prem

# All policies Compliant
kubectl get policy -n insights-on-prem

# On-prem service receiving traffic
kubectl logs -n insights-on-prem deployment/insights-on-prem --since=5m | grep "INFO:"
```

## UI tests

Run the test script to inject test data and verify the full end-to-end flow:

```bash
cd monolithic/
bash test_ui.sh
```

This creates test recommendations and alerts, waits for them to reach Thanos, and verifies the URP endpoint returns the correct data. Check the ACM fleet overview at `https://<your-cluster>/multicloud/home/overview` — you should see both Recommendations and Upgrade Risk Predictions populated.

## Uninstall

```bash
kubectl delete -f 05-policies.yaml
kubectl delete -f 04-placement.yaml
kubectl delete -f 03-addon.yaml
kubectl delete -f 02-addon-template.yaml
kubectl delete -f 01-namespace.yaml
```
