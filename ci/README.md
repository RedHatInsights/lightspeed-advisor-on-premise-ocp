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

Both scripts require `oc` (logged into the Konflux cluster) and `jq`, and share
configuration from `ci/common.sh` (namespace, component, ITS name, context names).
Run either script with `--help` for its full flag reference; this section explains
what the scripts are for, not every flag.

### Trigger and debug

```bash
ci/trigger-e2e.sh            # trigger the e2e ITS for the current HEAD commit
ci/trigger-e2e.sh --debug    # ...and hold the clusters if any task fails
```

`--debug` labels the PipelineRun `debug.iop/hold-on-failure=true`. On failure, the
`hold-clusters-on-failure` finally task prints each cluster's API server to the
logs, then sleeps to keep the ephemeral clusters alive for inspection. Use
`ci/get-cluster-credentials.sh` to get access. You can add the same label to an
already-running PipelineRun any time before it fails:

```bash
oc label pipelinerun <name> -n obsint-processing-tenant debug.iop/hold-on-failure=true
```

When you're done, cancel the run to tear down the clusters:

```bash
oc patch pipelinerun <name> -n obsint-processing-tenant \
  --type merge -p '{"spec":{"status":"CancelledRunFinally"}}'
```

`--test-filter <str>` labels the run but does not select tests yet — it is a
placeholder for the future e2e suite, not a bug.

### Get cluster credentials from a held run

This only works against a run that is **currently held open** by the debug flow
above — i.e. one triggered with `ci/trigger-e2e.sh --debug` (or labeled
`debug.iop/hold-on-failure=true`) where a task then failed. Without the hold, the
ephemeral clusters are torn down as soon as the run finishes and there are no
credentials to read.

```bash
ci/get-cluster-credentials.sh    # defaults to the latest held debug run
```

Creates `iop-e2e-hub` / `iop-e2e-managed` oc contexts from the held run's
kubeconfigs:

```bash
oc --context=iop-e2e-hub get nodes
oc --context=iop-e2e-managed get nodes
```

> **Overwrites existing entries:** any kubeconfig contexts named
> `iop-e2e-hub` / `iop-e2e-managed` (and their backing cluster/user entries)
> are deleted and recreated. Your active context is preserved and restored.

> The ephemeral clusters are HyperShift hosted clusters: **no kubeadmin password
> and no web-console login**. Authentication is via the client certificate
> embedded in the kubeconfig (user `system:admin`), which is why these contexts
> use cert auth rather than `oc login -u/-p`.

## ITS configuration

The IntegrationTestScenario (name, timeouts, `resolverRef`) is defined in the
`konflux-release-data` repo, not here:
`tenants-config/cluster/stone-prd-rh01/tenants/obsint-processing-tenant/insights-on-prem-component.yaml`.

## Files

| Path | Purpose |
|------|---------|
| `ci/test-pipelines/iop-e2e-pipeline.yaml` | The Tekton pipeline |
| `ci/trigger-e2e.sh` | Trigger the ITS by labeling a Snapshot (+ optional debug/test-filter) |
| `ci/get-cluster-credentials.sh` | Build `iop-e2e-hub` / `iop-e2e-managed` oc contexts from a held run |
| `ci/common.sh` | Shared config sourced by the scripts (namespace, component, ITS name, contexts) |
