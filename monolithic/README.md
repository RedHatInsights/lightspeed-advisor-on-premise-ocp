# Insights On Premise (monolithic version)

A Python application that receives Insights archives, processes them with insights-core, and stores results in PostgreSQL. Designed for on-premise deployment in ACM clusters.

## API Endpoints

### Upload Archive
```
POST /api/ingress/v1/upload
```
Upload an Insights archive for processing.

**Example:**
```bash
curl -X POST http://localhost:8000/api/ingress/v1/upload -F "file=@/path/to/archive.tar.gz"
```

### Get Cluster Report
```
GET /api/v2/cluster/{cluster_id}/reports
```
Retrieve processed report for a cluster.

### Batch Upgrade Risk Predictions
```
POST /api/insights-results-aggregator/v2/upgrade-risks-prediction
```
Returns upgrade risk predictions for a list of clusters by querying Thanos for active alerts and failing operator conditions. Matches the `ccx-upgrades-data-eng` API format so the ACM console can route URP calls to this service instead of `console.redhat.com`.

### Health Check
```
GET /health
```

### API Documentation
- Swagger UI: http://localhost:8000/docs
- ReDoc: http://localhost:8000/redoc

## Building and Pushing Multiarch Image

Build and push a multiarch (amd64, arm64) image to Quay (this step is necessary because cluster nodes may run on different architecture than the development environment):

```bash
# Login to Quay
docker login quay.io

# Build and push multiarch image
docker buildx build --platform linux/amd64,linux/arm64 \
  -t quay.io/ccxdev/insights-on-premise-poc:latest \
  --push .
```

## Running Locally with Docker Compose

1. **Start services:**
   ```bash
   docker-compose up -d
   ```

2. **Run database migrations:**
   ```bash
   docker-compose exec app alembic upgrade head
   ```

3. **Verify:**
   ```bash
   curl http://localhost:8000/health
   ```

4. **View logs:**
   ```bash
   docker-compose logs -f app
   ```

5. **Stop services:**
   ```bash
   docker-compose down
   ```

## Deploying to ACM Cluster

The recommended deployment method is the ACM addon — see **[monolithic/addon/README.md](addon/README.md)** for full instructions.

The addon deploys the app via the ACM addon framework and handles all configuration (insights-operator redirect, recommendations routing, upgrade risk predictions) automatically via ConfigurationPolicies with no manual steps.

## How to trigger an Insights recommendation

To trigger creation of an Insights recommendation, and the creation of the corresponing `PolicyReport` custom resource by an Insights Client,
at least one of the rule conditions has to be met. The easiest way to achieve that is by running the following command:

```bash
oc apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: insights-test-webhook
webhooks:
  - name: insights-test.example.com
    admissionReviewVersions: ["v1"]
    clientConfig:
      url: "https://localhost:1234/validate"
    failurePolicy: Ignore
    sideEffects: None
    timeoutSeconds: 30
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "*"
EOF
```

The command should trigger [webhook_timeout_is_larger_than_default](https://gitlab.cee.redhat.com/ccx/ccx-rules-ocp/-/blob/master/ccx_rules_ocp/external/rules/webhook_timeout_is_larger_than_default.py) rule. Depending on the frequency of archive uploads from Insights Operator (in `deploy.sh` script set to 1 minute for PoC purposes, but default value is 2 hours), the recommendation and the `PolicyReport` should be created. You can check that with this command directly in the ACM cluster:

```bash
oc get policyreport --all-namespaces
```

## Viewing Results in the ACM Fleet Overview UI

The results of the on-premise pipeline are visible in the ACM fleet overview at:

```text
https://<your-cluster-api-server>/multicloud/home/overview
```

**Before** (`deploy.sh` only, without `test_ui.sh`):

![ACM Fleet Overview - Insights section with no data](docs/fleet-overview-empty.png)

**After** (`test_ui.sh` applied):

![ACM Fleet Overview - Insights section showing all four panels populated from the on-premise pipeline](docs/fleet-overview-ui.png)

The Insights section of that page has four panels. Here is what backs each one and what is needed for it to show data:

### Cluster recommendations

**Source:** `PolicyReport` custom resources created by `insights-client` in each managed cluster's namespace.

**Extra setup:** N/A, triggered recommendations are shown in UI

### Update risk predictions

**Source:** The ACM console backend forwards URP calls to `console.redhat.com`. The URL is now configurable via the `UPGRADE_RISKS_PREDICTION_URL` env var ([CCXDEV-16237](https://redhat.atlassian.net/browse/CCXDEV-16237), [merged](https://github.com/stolostron/console/pull/5892)). `test_ui.sh` sets this env var to point to the on-prem service. See the [Custom console image for URP](#custom-console-image-for-urp) section below.

### Alerts

**Source:** Thanos directly, via MCO. The ACM console reads `ALERTS` metrics from Thanos and displays raw alert counts. No on-prem involvement — this section works automatically once MCO is deployed.

**How PrometheusRule → Thanos works:** `PrometheusRule` is a Kubernetes CRD provided by the Prometheus Operator (part of OpenShift monitoring). When applied, Prometheus evaluates the alerting rules and fires alerts matching the conditions. MCO's `metrics-collector` pod remote-writes all metrics — including the `ALERTS` series — from the cluster's Prometheus to the central Thanos instance. Once in Thanos, they are queryable via `rbac-query-proxy` by the on-prem service and visible in the ACM console's Alerts panel.

### Failing operators

**Source:** Thanos directly, via MCO. The ACM console reads `cluster_operator_conditions` metrics from Thanos. No on-prem involvement.

### Testing the on-prem pipeline panels

Run `test_ui.sh` after `deploy.sh` to set up test data that triggers all four sections and verifies the data is flowing through the on-prem service (not `console.redhat.com`):

```bash
./test_ui.sh
```

#### Custom console image for URP

`test_ui.sh` deploys a custom console image (`quay.io/ccxdev/insights-on-prem-lsolarov-console:latest`) built from `stolostron/console` main, which already includes `UPGRADE_RISKS_PREDICTION_URL` env var support ([CCXDEV-16237](https://redhat.atlassian.net/browse/CCXDEV-16237)). It is needed only until a new ACM release ships with this change.

> **Note:** The image is private. `deploy.sh` automatically copies the existing `ccxdev-insights-on-prem-poc-pull-secret` (created in step 3) to `open-cluster-management` — no extra setup needed since it uses the same `ccxdev+insights_on_prem_poc` robot account.
> **Note:** [CCXDEV-16237](https://redhat.atlassian.net/browse/CCXDEV-16237) is merged — the custom image is for testing only until a new ACM release ships with this change.

```typescript
// Before (hardcoded):
const insightsPath = 'https://console.redhat.com/api/insights-results-aggregator/v2/upgrade-risks-prediction'

// After (env var with fallback):
const insightsPath = process.env.UPGRADE_RISKS_PREDICTION_URL ?? 'https://console.redhat.com/api/insights-results-aggregator/v2/upgrade-risks-prediction'
```

Once a new ACM release ships with this change, the custom image is no longer needed — `test_ui.sh` reduces to just setting `UPGRADE_RISKS_PREDICTION_URL` to the HTTPS route of the on-prem service.

To rebuild the custom image (no code changes needed — the change is already in `stolostron/console` main):
```bash
git clone git@github.com:stolostron/console.git
cd backend && npm install && npm run build
docker buildx build --platform linux/amd64,linux/arm64 \
  -t quay.io/ccxdev/insights-on-prem-lsolarov-console:latest \
  --push .
```

## Database Access

The application deploys its own PostgreSQL database.

**Connect to database:**
```bash
# Locally
docker-compose exec postgres psql -U insights -d insights

# In cluster
oc exec -it deployment/insights-postgres -n insights-on-prem-poc -- psql -U insights -d insights
```
