# shellcheck shell=bash
# Shared configuration for the IOP e2e CI scripts.
# Sourced by trigger-e2e.sh and get-cluster-credentials.sh — not executed directly.

# Konflux tenant namespace holding the Snapshots, PipelineRuns and credentials.
NAMESPACE="obsint-processing-tenant"

# Konflux component whose Snapshots we trigger the e2e pipeline for.
COMPONENT="insights-on-prem"

# IntegrationTestScenario that runs the e2e pipeline. MUST match the ITS name in
# konflux-release-data:
#   tenants-config/.../obsint-processing-tenant/insights-on-prem-component.yaml
# If it does not match, labeling a Snapshot is silently ignored and nothing runs.
ITS_NAME="insights-on-prem-e2e"

# oc context names created by get-cluster-credentials.sh for the two ephemeral
# clusters. Purely local to your kubeconfig; rename freely.
HUB_CONTEXT="iop-e2e-hub"
MANAGED_CONTEXT="iop-e2e-managed"
