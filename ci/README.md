# IOP E2E Pipeline

End-to-end test pipeline for Insights on Premise (IOP) on ephemeral OpenShift
clusters.

## What it does

The pipeline provisions two throwaway OCP clusters on AWS (an ACM **hub** and a
**managed**/spoke cluster), installs ACM on the hub, deploys IOP from the
Konflux Snapshot image, imports the managed cluster into the ACM hub, and runs
smoke tests.

Clusters are **HyperShift hosted clusters** provisioned by the OpenShift CI
`provision-ephemeral-cluster` task (`hypershift-hostedcluster-workflow`). They
are destroyed automatically when the PipelineRun is cleaned up (via the
PipelineRun `ownerReference` on the provisioning request) — no explicit
deprovision step is needed.

```
provision-hub (m5.2xlarge)      provision-managed (m5.xlarge)
        |                                |
        v                                |
    acm-install                          |
        |                                |
        +------------> iop-deploy        |
        |                    |           |
        +---> import-managed-cluster <---+
                     |            |
                     v            v
                 iop-e2e-tests

finally: hold-clusters-on-failure   (runs only if a task failed AND the run is
                                     labeled debug.iop/hold-on-failure=true)
```

## How triggering works

The pipeline runs through the Konflux **IntegrationTestScenario** (ITS) named
`insights-on-prem-e2e`, defined in the `konflux-release-data` repo. The flow:

1. A build completes and Konflux creates a **Snapshot**.
2. `ci/trigger-e2e.sh` labels the Snapshot with
   `test.appstudio.openshift.io/run=insights-on-prem-e2e`.
3. The Konflux integration service picks up the label, creates a **PipelineRun**
   from the ITS definition, and passes the Snapshot JSON as a pipeline parameter.
4. The PipelineRun appears in the Konflux UI and its result is reported to GitHub.

The pipeline definition itself is resolved from **branch HEAD** of the branch the
ITS `resolverRef` points at, so triggering any existing Snapshot always runs the
latest pipeline code on that branch.

> **Naming note:** the ITS name is `insights-on-prem-e2e` — it does **not**
> encode the provisioning mechanism. An earlier version used Konflux EaaS and was
> named `...-eaas-e2e`; provisioning has since moved to OpenShift CI ephemeral
> clusters, so the mechanism-specific name was dropped. The mechanism is
> documented here and in the pipeline `description`, where it is cheap to update
> if it changes again.

## Why PipelineRun labels instead of pipeline parameters

Tekton pipeline parameters are **immutable after PipelineRun creation**, and the
PipelineRun is created by the Konflux integration service (not by us), so there
is no way to pass custom parameters through the Snapshot-label triggering flow.

We could create the PipelineRun directly (bypassing the ITS), but that loses two
things: the run no longer appears in the Konflux UI under the ITS, and results
are no longer reported to GitHub as status checks.

Instead, the pipeline reads **debug labels from its own PipelineRun metadata** at
runtime. The `konflux-integration-runner` service account can read PipelineRun
objects in the tenant namespace, so tasks query their own labels with
`oc get pipelinerun`. The trigger script labels the Snapshot first, waits for the
PipelineRun to be created, then labels the PipelineRun — provisioning takes 10+
minutes, so the labels are always in place before any task reads them.

## Usage

All scripts require `oc` (logged into the Konflux cluster) and `jq`, and share
configuration from `ci/common.sh` (namespace, component, ITS name, context names).

### Basic trigger

```bash
ci/trigger-e2e.sh              # trigger for current HEAD
ci/trigger-e2e.sh abc1234      # trigger for a specific commit
ci/trigger-e2e.sh --force      # retrigger (removes the run label first, re-adds)
```

### Debug: hold clusters on failure

```bash
ci/trigger-e2e.sh --debug
```

`--debug` labels the PipelineRun with `debug.iop/hold-on-failure=true`. If any
task fails, the `hold-clusters-on-failure` finally task:

1. Prints each cluster's credentials (API URL, `oc login` command, base64
   kubeconfig) to the task logs, and
2. Sleeps indefinitely to keep the PipelineRun — and therefore the ephemeral
   clusters — alive for inspection.

You can also add the label to a running PipelineRun any time before it fails:

```bash
oc label pipelinerun <name> -n obsint-processing-tenant \
  debug.iop/hold-on-failure=true
```

When done debugging, cancel the run (this tears down the clusters):

```bash
oc patch pipelinerun <name> -n obsint-processing-tenant \
  --type merge -p '{"spec":{"status":"CancelledRunFinally"}}'
```

### Get cluster credentials from a held run

```bash
ci/get-cluster-credentials.sh                       # auto-find latest debug run
ci/get-cluster-credentials.sh insights-on-prem-e2e-fxrpk   # or name a run
```

This reads the kubeconfigs the provision tasks produced and creates two oc
contexts (your original context is preserved):

```bash
oc --context=iop-e2e-hub get nodes
oc --context=iop-e2e-managed get nodes
```

> The ephemeral clusters are HyperShift hosted clusters: **no kubeadmin password
> and no web-console login**. Authentication is via the client certificate
> embedded in the kubeconfig (user `system:admin`), which is why these contexts
> use cert auth rather than `oc login -u/-p`.

### Test filter (placeholder)

```bash
ci/trigger-e2e.sh --test-filter smoke
```

Labels the PipelineRun with `debug.iop/test-filter=smoke`; the test task reads it
at runtime. The actual filtering logic is not implemented yet (TODO).

### Combined

```bash
ci/trigger-e2e.sh --debug --test-filter smoke abc1234
```

## ITS configuration (in konflux-release-data)

The ITS is defined in `konflux-release-data`, source of truth:

```
tenants-config/cluster/stone-prd-rh01/tenants/obsint-processing-tenant/insights-on-prem-component.yaml
```

after editing there, regenerate the `auto-generated/` copy with
`tenants-config/build-single.sh obsint-processing-tenant` and commit both.

Two things must stay correct:

- **Name match:** the ITS `metadata.name` must equal the value the trigger script
  sets (`insights-on-prem-e2e`, from `ci/common.sh`). If they differ, labeling a
  Snapshot is silently ignored and nothing runs.
- **Timeout annotations:** the debug hold needs extended timeouts so the finally
  task can sleep; otherwise the default 1h PipelineRun timeout kills the held run:

  ```yaml
  metadata:
    annotations:
      test.appstudio.openshift.io/pipeline_timeout: "4h"
      test.appstudio.openshift.io/tasks_timeout: "2h"
      test.appstudio.openshift.io/finally_timeout: "2h"
  ```

## Files

| Path | Purpose |
|------|---------|
| `ci/test-pipelines/iop-e2e-pipeline.yaml` | The Tekton pipeline |
| `ci/trigger-e2e.sh` | Trigger the ITS by labeling a Snapshot (+ optional debug/test-filter) |
| `ci/get-cluster-credentials.sh` | Build `iop-e2e-hub` / `iop-e2e-managed` oc contexts from a held run |
| `ci/common.sh` | Shared config sourced by the scripts (namespace, component, ITS name, contexts) |
