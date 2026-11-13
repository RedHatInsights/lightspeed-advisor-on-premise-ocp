#!/usr/bin/env bash
set -euo pipefail

# Full runtime leak investigation helper.
# - Starts the app either as a local process (venv) or as a podman container.
# - Monitors memory:
#     * Primary metric (preferred, used for pass/fail summary): process RSS
#       from /proc/<pid>/status (VmRSS). For container mode this is read via
#       `podman exec <container> cat /proc/1/status`, which is the exact same
#       kernel-level number as reading /proc/<host_pid>/status, so results stay
#       comparable between venv and container runs.
#     * Secondary metric (container mode only, informational): cgroup-based
#       memory usage from `podman stats` (includes page cache and can read
#       higher than RSS). Logged separately for comparison.
# - Sends repeated upload requests to /api/ingress/v1/upload.
#
# Usage:
#   scripts/run-leak-investigation.sh
#   scripts/run-leak-investigation.sh --auto-start-postgres
#   scripts/run-leak-investigation.sh --run-mode=container
#   scripts/run-leak-investigation.sh --run-mode=container --no-build
#   ITERATIONS=2000 scripts/run-leak-investigation.sh
#   VENV_PATH=/path/to/venv APP_PORT=8000 scripts/run-leak-investigation.sh
#   ARCHIVE_PATH=/path/to/file.tar.gz scripts/run-leak-investigation.sh
#   ARCHIVE_DIR=/path/to/archives/ scripts/run-leak-investigation.sh
#   RUN_MODE=container MOCK_ARCHIVE_PROCESSING=false scripts/run-leak-investigation.sh
#
# Optional env vars (common):
#   RUN_MODE=venv                  # "venv" (default) or "container"
#   APP_HOST=127.0.0.1
#   APP_PORT=8000
#   ITERATIONS=1000
#   SAMPLE_INTERVAL=5
#   UPLOAD_BYTES=65536
#   UPLOAD_TIMEOUT=300              # seconds before an upload request is counted as failed
#   ARCHIVE_PATH=/tmp/file.tar.gz   # single archive, reused for every upload
#   ARCHIVE_DIR=/path/to/archives/  # directory of archives; cycled round-robin,
#                                   # one per upload, instead of reusing one file.
#                                   # Mutually exclusive with ARCHIVE_PATH.
#   REPORT_DIR=docs/leak-investigation/<category>/<name>  # never /tmp; see
#                                   # docs/leak-investigation/README.md
#   MOCK_ARCHIVE_PROCESSING=true   # script-only monkeypatch; set to false to exercise real insights-core analysis
#   MOCK_ARCHIVE_CLUSTER_ID=mock-cluster
#   ARCHIVE_QUEUE_SIZE=            # optional pass-through; empty = use config.yml default (10).
#                                   # Set to 0 for an unbounded queue (avoids 503s on bursts).
#   DRAIN_TIMEOUT=600              # seconds to wait for the archive queue to fully drain
#   AUTO_START_POSTGRES=false
#
# Optional env vars (venv mode only):
#   VENV_PATH=/path/to/venv      # virtualenv directory containing bin/python;
#                                # defaults to VIRTUAL_ENV if already activated.
#                                # If neither is set, python from PATH is used
#                                # directly (useful for CI images with a local
#                                # Python installation and no virtualenv).
#
# Optional env vars (container mode only):
#   CONTAINER_IMAGE=localhost/insights-advisor:leak-test
#   CONTAINER_NAME=insights-leak-investigation
#   CONTAINER_BUILD=true           # set to false (or pass --no-build) to reuse an existing image
#   POSTGRES_CONTAINER_NAME=insights-postgres  # used to auto-discover and join
#                                   # its podman network for direct container-
#                                   # to-container DB connectivity (preferred;
#                                   # avoids the slirp4netns NAT path, which is
#                                   # unreliable for long multi-hour runs).
#   CONTAINER_NETWORK=              # explicit network name; skips auto-discovery
#   POSTGRES_HOST_FOR_CONTAINER=host.containers.internal  # fallback only, used
#                                   # if the postgres container/network can't be
#                                   # found
#   POSTGRES_PORT=5432
#   POSTGRES_DB=insights
#   POSTGRES_USER=insights
#   POSTGRES_PASSWORD=insights
#   CONTAINER_QUIET_SQL_LOG=true    # Mount a patched config.yml that lowers the
#                                   # "sqlalchemy.engine" logger from DEBUG to WARNING.
#                                   # config.yml's default DEBUG level makes SQLAlchemy
#                                   # echo every query/row at very high volume; under a
#                                   # container, writes to the container's stdout log
#                                   # pipe can back up faster than podman's log driver
#                                   # drains them, which blocks (not crashes) the
#                                   # single-threaded archive-processor worker thread
#                                   # mid-write and stalls processing under bursts.
#                                   # This does NOT modify the repo's config.yml; a
#                                   # patched copy is generated under REPORT_DIR and
#                                   # bind-mounted over /app/config.yml. Set to false to
#                                   # use the image's built-in config.yml unmodified.
#
# CLI flags:
#   --auto-start-postgres     Start postgres via podman-compose/docker-compose if not already running
#   --run-mode=venv|container Select how the app under test is started (same as RUN_MODE)
#   --container               Shorthand for --run-mode=container
#   --venv                    Shorthand for --run-mode=venv (default)
#   --no-build                Skip `podman build` in container mode and reuse CONTAINER_IMAGE
#   --no-quiet-sql-log        Use the image's built-in config.yml unmodified (keep
#                             sqlalchemy.engine at DEBUG); see CONTAINER_QUIET_SQL_LOG above
#   -h, --help                Show this help

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto-start-postgres|--auto-start-progress)
        AUTO_START_POSTGRES=true
        shift
        ;;
      --run-mode=*)
        RUN_MODE="${1#*=}"
        shift
        ;;
      --container)
        RUN_MODE=container
        shift
        ;;
      --venv)
        RUN_MODE=venv
        shift
        ;;
      --no-build)
        CONTAINER_BUILD=false
        shift
        ;;
      --no-quiet-sql-log)
        CONTAINER_QUIET_SQL_LOG=false
        shift
        ;;
      -h|--help)
        sed -n '1,95p' "$0"
        exit 0
        ;;
      *)
        echo "ERROR: unknown option: $1" >&2
        exit 1
        ;;
    esac
  done
}

start_postgres_if_requested() {
  if [[ "${AUTO_START_POSTGRES}" != "true" ]]; then
    return
  fi

  if command -v podman-compose >/dev/null 2>&1; then
    echo "Auto-starting postgres with: podman-compose up -d postgres"
    podman-compose up -d postgres
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    echo "Auto-starting postgres with: podman compose up -d postgres"
    podman compose up -d postgres
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Auto-starting postgres with: docker compose up -d postgres"
    docker compose up -d postgres
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "Auto-starting postgres with: docker-compose up -d postgres"
    docker-compose up -d postgres
  else
    echo "ERROR: AUTO_START_POSTGRES requested but none of 'podman-compose', 'podman compose', 'docker compose', or 'docker-compose' is available" >&2
    exit 1
  fi
}

write_mock_processing_monkeypatch() {
  mkdir -p "${MONKEYPATCH_DIR}"
  cat >"${MONKEYPATCH_DIR}/sitecustomize.py" <<'PY'
"""Leak investigation monkeypatches loaded via PYTHONPATH/sitecustomize.

This keeps mock archive processing out of the production service code while still
allowing the leak script to exercise upload, worker, and database-save paths.
"""

import json
import logging
import os
import sys

# During interpreter startup, sitecustomize can run before Python has put the
# current working directory on sys.path for `python -m app.main`. Add it
# explicitly so this hook can import the application package.
sys.path.insert(0, os.getcwd())

logger = logging.getLogger(__name__)


def _install_mock_processor() -> None:
    from app.services.processor_service import ProcessorService

    results_json = json.dumps(
        {
            "reports": [
                {
                    "component": "ccx_rules_ocp.external.rules.mock_rule.report",
                    "key": "MOCK_RULE_HIT",
                    "type": "rule",
                    "details": {"reason": "leak investigation monkeypatch"},
                }
            ]
        }
    )

    def process_with_insights_core(self, archive_path: str) -> tuple[str, str]:
        logger.warning(
            "Leak investigation monkeypatch: skipping insights-core analysis for %s",
            archive_path,
        )
        return (
            os.environ.get("LEAK_MOCK_ARCHIVE_CLUSTER_ID", "mock-cluster"),
            results_json,
        )

    ProcessorService.process_with_insights_core = process_with_insights_core
    logger.warning("Installed leak investigation ProcessorService monkeypatch")


if os.environ.get("LEAK_MOCK_ARCHIVE_PROCESSING", "").lower() in {"true", "1", "yes"}:
    _install_mock_processor()
PY
}

cleanup() {
  set +e
  if [[ -n "${MONITOR_PID}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
  fi

  if [[ -n "${LOG_TAIL_PID}" ]] && kill -0 "${LOG_TAIL_PID}" 2>/dev/null; then
    kill "${LOG_TAIL_PID}" 2>/dev/null || true
    wait "${LOG_TAIL_PID}" 2>/dev/null || true
  fi

  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
  fi

  if [[ "${STARTED_CONTAINER}" == "true" ]]; then
    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${TEMP_ARCHIVE}" && -f "${TEMP_ARCHIVE}" ]]; then
    rm -f "${TEMP_ARCHIVE}"
  fi
}

handle_interrupt() {
  trap - EXIT INT TERM
  cleanup
  exit 130
}

handle_termination() {
  trap - EXIT INT TERM
  cleanup
  exit 143
}

sample_memory_now() {
  local now rss_kb mem_bytes mem_kb
  now="$(date +%s.%3N)"

  if [[ "${RUN_MODE}" == "container" ]]; then
    rss_kb="$(podman exec "${CONTAINER_NAME}" sh -c "awk '/VmRSS/ {print \$2}' /proc/1/status" 2>/dev/null || true)"
    if [[ -n "${rss_kb}" ]]; then
      echo "${now} ${rss_kb}" >>"${MEM_LOG}"
    fi

    mem_bytes="$(podman stats --no-stream --format '{{.ContainerStats.MemUsage}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    if [[ -n "${mem_bytes}" ]]; then
      mem_kb="$(awk -v b="${mem_bytes}" 'BEGIN { printf "%.0f", b/1024 }')"
      echo "${now} ${mem_kb}" >>"${MEM_LOG_PODMAN_STATS}"
    fi
  elif [[ -n "${APP_PID}" && -r "/proc/${APP_PID}/status" ]]; then
    awk -v now="${now}" '/VmRSS/ { printf "%s %s\n", now, $2 }' "/proc/${APP_PID}/status" >>"${MEM_LOG}"
  fi

  return 0
}

summarize_mem_log() {
  local log_file="$1"
  if [[ -s "${log_file}" ]]; then
    local start_kb end_kb peak_kb
    start_kb="$(awk 'NR==1 {print $2}' "${log_file}")"
    end_kb="$(awk 'END {print $2}' "${log_file}")"
    peak_kb="$(awk 'max<$2 {max=$2} END {print max+0}' "${log_file}")"
    awk -v a="${start_kb}" -v b="${end_kb}" -v p="${peak_kb}" \
      'BEGIN { printf "%.2f %.2f %.2f %.2f", a/1024, b/1024, p/1024, (b-a)/1024 }'
  else
    echo "n/a n/a n/a n/a"
  fi
}

require_cmd realpath

ROOT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
cd "${ROOT_DIR}"

RUN_MODE="${RUN_MODE:-venv}"
VENV_PATH="${VENV_PATH:-${VIRTUAL_ENV:-}}"
APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8000}"
ITERATIONS="${ITERATIONS:-1000}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
UPLOAD_BYTES="${UPLOAD_BYTES:-65536}"
UPLOAD_TIMEOUT="${UPLOAD_TIMEOUT:-300}"
MOCK_ARCHIVE_PROCESSING="${MOCK_ARCHIVE_PROCESSING:-true}"
MOCK_ARCHIVE_CLUSTER_ID="${MOCK_ARCHIVE_CLUSTER_ID:-mock-cluster}"
ARCHIVE_QUEUE_SIZE="${ARCHIVE_QUEUE_SIZE:-}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600}"
AUTO_START_POSTGRES="${AUTO_START_POSTGRES:-false}"
REPORT_DIR="${REPORT_DIR:-/tmp/iop-leak-$(date +%Y%m%d-%H%M%S)}"

CONTAINER_IMAGE="${CONTAINER_IMAGE:-localhost/insights-advisor:leak-test}"
CONTAINER_NAME="${CONTAINER_NAME:-insights-leak-investigation}"
CONTAINER_BUILD="${CONTAINER_BUILD:-true}"
# Preferred: direct container-to-container networking (join the same podman
# network as the postgres container and talk to it by container name). This
# avoids routing through rootless podman's slirp4netns NAT/host-gateway path,
# which proved unreliable for long-duration (multi-hour), high-connection-churn
# runs (see docs/leak-investigation/README.md, "Container networking" section).
# POSTGRES_CONTAINER_NAME is auto-inspected to find its network; set
# CONTAINER_NETWORK explicitly to skip discovery. If discovery fails (e.g. the
# postgres container isn't found), falls back to the host-gateway/NAT approach
# with POSTGRES_HOST_FOR_CONTAINER, which only exists for that fallback case.
POSTGRES_CONTAINER_NAME="${POSTGRES_CONTAINER_NAME:-insights-postgres}"
CONTAINER_NETWORK="${CONTAINER_NETWORK:-}"
POSTGRES_HOST_FOR_CONTAINER="${POSTGRES_HOST_FOR_CONTAINER:-host.containers.internal}"
CONTAINER_QUIET_SQL_LOG="${CONTAINER_QUIET_SQL_LOG:-true}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-insights}"
POSTGRES_USER="${POSTGRES_USER:-insights}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-insights}"

parse_args "$@"

APP_URL="http://${APP_HOST}:${APP_PORT}"
UPLOAD_URL="${APP_URL}/api/ingress/v1/upload"
HEALTH_URL="${APP_URL}/health"

if [[ "${RUN_MODE}" != "venv" && "${RUN_MODE}" != "container" ]]; then
  echo "ERROR: RUN_MODE must be 'venv' or 'container' (got: ${RUN_MODE})" >&2
  exit 1
fi

mkdir -p "${REPORT_DIR}"
# Canonicalize to an absolute path: podman's -v bind-mount requires an
# absolute host path, otherwise a relative path is misinterpreted as a named
# volume (and rejected, since paths contain '/').
REPORT_DIR="$(realpath "${REPORT_DIR}")"
APP_LOG="${REPORT_DIR}/app.log"
MEM_LOG="${REPORT_DIR}/memory.log"
MEM_LOG_PODMAN_STATS="${REPORT_DIR}/memory_podman_stats.log"
REQ_LOG="${REPORT_DIR}/requests.log"
SUMMARY_LOG="${REPORT_DIR}/summary.txt"
MONKEYPATCH_DIR="${REPORT_DIR}/monkeypatch-pythonpath"

require_cmd curl
require_cmd awk

if [[ "${RUN_MODE}" == "container" ]]; then
  require_cmd podman
fi


APP_PID=""
MONITOR_PID=""
LOG_TAIL_PID=""
TEMP_ARCHIVE=""
STARTED_CONTAINER=false


trap cleanup EXIT
trap handle_interrupt INT
trap handle_termination TERM

ARCHIVE_LIST=()

if [[ -n "${ARCHIVE_PATH:-}" && -n "${ARCHIVE_DIR:-}" ]]; then
  echo "ERROR: set either ARCHIVE_PATH or ARCHIVE_DIR, not both" >&2
  exit 1
fi

if [[ -n "${ARCHIVE_DIR:-}" ]]; then
  if [[ ! -d "${ARCHIVE_DIR}" ]]; then
    echo "ERROR: ARCHIVE_DIR does not exist: ${ARCHIVE_DIR}" >&2
    exit 1
  fi
  while IFS= read -r -d '' f; do
    ARCHIVE_LIST+=("${f}")
  done < <(find "${ARCHIVE_DIR}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' \) -print0 | sort -z)
  if [[ ${#ARCHIVE_LIST[@]} -eq 0 ]]; then
    echo "ERROR: no .tar/.tar.gz/.tgz archives found in ARCHIVE_DIR: ${ARCHIVE_DIR}" >&2
    exit 1
  fi
  UPLOAD_FILE="${ARCHIVE_LIST[0]}"
  ARCHIVE_SOURCE_DESC="${#ARCHIVE_LIST[@]} archives cycled round-robin from ${ARCHIVE_DIR}"
elif [[ -n "${ARCHIVE_PATH:-}" ]]; then
  if [[ ! -f "${ARCHIVE_PATH}" ]]; then
    echo "ERROR: ARCHIVE_PATH does not exist: ${ARCHIVE_PATH}" >&2
    exit 1
  fi
  UPLOAD_FILE="${ARCHIVE_PATH}"
  ARCHIVE_SOURCE_DESC="single archive: ${ARCHIVE_PATH}"
else
  if [[ "${MOCK_ARCHIVE_PROCESSING}" != "true" ]]; then
    echo "ERROR: real archive processing requires ARCHIVE_PATH or ARCHIVE_DIR" >&2
    exit 1
  fi
  TEMP_ARCHIVE="$(mktemp /tmp/iop-upload-XXXXXX.tar.gz)"
  dd if=/dev/zero of="${TEMP_ARCHIVE}" bs="${UPLOAD_BYTES}" count=1 status=none
  UPLOAD_FILE="${TEMP_ARCHIVE}"
  ARCHIVE_SOURCE_DESC="synthetic ${UPLOAD_BYTES}-byte dummy archive (not a real .tar.gz payload)"
fi

echo "Starting leak investigation"
echo "  run mode:    ${RUN_MODE}"
echo "  report dir:  ${REPORT_DIR}"
echo "  app url:     ${APP_URL}"
if [[ "${RUN_MODE}" == "venv" ]]; then
  echo "  venv path:   ${VENV_PATH:-<not set; using python from PATH>}"
fi
echo "  iterations:  ${ITERATIONS}"
echo "  archive(s):  ${ARCHIVE_SOURCE_DESC}"
echo "  mock mode:   ${MOCK_ARCHIVE_PROCESSING}"
echo "  auto-start postgres: ${AUTO_START_POSTGRES}"

if [[ "${MOCK_ARCHIVE_PROCESSING}" == "true" ]]; then
  write_mock_processing_monkeypatch
  echo "  monkeypatch: ${MONKEYPATCH_DIR}/sitecustomize.py"
fi

start_postgres_if_requested

if [[ "${RUN_MODE}" == "container" ]]; then
  # Remove any leftover container from a previous (possibly crashed) run.
  podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  if [[ "${CONTAINER_BUILD}" == "true" ]]; then
    echo "Building container image: ${CONTAINER_IMAGE}"
    podman build -t "${CONTAINER_IMAGE}" "${ROOT_DIR}"
  else
    if ! podman image exists "${CONTAINER_IMAGE}" 2>/dev/null; then
      echo "ERROR: --no-build requested but image ${CONTAINER_IMAGE} does not exist locally" >&2
      exit 1
    fi
    echo "Reusing existing container image: ${CONTAINER_IMAGE}"
  fi

  # Discover the network the postgres container is on, to join it directly
  # (container-to-container) instead of routing through slirp4netns NAT.
  if [[ -z "${CONTAINER_NETWORK}" ]] && podman container exists "${POSTGRES_CONTAINER_NAME}" 2>/dev/null; then
    CONTAINER_NETWORK="$(podman inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${POSTGRES_CONTAINER_NAME}" 2>/dev/null | awk '{print $1}')"
  fi

  RUN_ARGS=(
    -d --name "${CONTAINER_NAME}"
    -e "POSTGRES_PORT=${POSTGRES_PORT}"
    -e "POSTGRES_DB=${POSTGRES_DB}"
    -e "POSTGRES_USER=${POSTGRES_USER}"
    -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
    -p "${APP_PORT}:8000"
  )

  if [[ "${MOCK_ARCHIVE_PROCESSING}" == "true" ]]; then
    RUN_ARGS+=(
      -e "LEAK_MOCK_ARCHIVE_PROCESSING=true"
      -e "LEAK_MOCK_ARCHIVE_CLUSTER_ID=${MOCK_ARCHIVE_CLUSTER_ID}"
      -e "PYTHONPATH=/tmp/iop-leak-pythonpath"
      -v "${MONKEYPATCH_DIR}:/tmp/iop-leak-pythonpath:ro,Z"
    )
  fi

  if [[ -n "${CONTAINER_NETWORK}" ]]; then
    echo "Joining postgres container's network directly: ${CONTAINER_NETWORK} (container-to-container, no NAT)"
    RUN_ARGS+=(--network "${CONTAINER_NETWORK}" -e "POSTGRES_HOST=${POSTGRES_CONTAINER_NAME}")
  else
    echo "WARNING: could not find/join postgres container '${POSTGRES_CONTAINER_NAME}' network; falling back to host-gateway NAT (${POSTGRES_HOST_FOR_CONTAINER}). This path is known to be unreliable for long (multi-hour) runs." >&2
    RUN_ARGS+=(--add-host=host.containers.internal:host-gateway -e "POSTGRES_HOST=${POSTGRES_HOST_FOR_CONTAINER}")
  fi
  if [[ -n "${ARCHIVE_QUEUE_SIZE}" ]]; then
    RUN_ARGS+=(-e "ARCHIVE_QUEUE_SIZE=${ARCHIVE_QUEUE_SIZE}")
  fi

  if [[ "${CONTAINER_QUIET_SQL_LOG}" == "true" ]]; then
    # config.yml ships with the "sqlalchemy.engine" logger at DEBUG, which makes
    # SQLAlchemy echo every query and row at very high volume. Under a container
    # this can write to stdout faster than podman's log driver drains it; the
    # resulting backpressure blocks (not crashes) the single-threaded archive
    # processor worker thread mid-write and stalls processing under bursts.
    # Mount a patched copy (DEBUG -> WARNING for that one logger only) instead of
    # editing the repo's config.yml.
    QUIET_CONFIG="${REPORT_DIR}/config.container-quiet.yml"
    sed '/sqlalchemy\.engine:/{n;s/level: DEBUG/level: WARNING/}' "${ROOT_DIR}/config.yml" >"${QUIET_CONFIG}"
    RUN_ARGS+=(-v "${QUIET_CONFIG}:/app/config.yml:ro,Z")
    echo "Mounted quieter config (sqlalchemy.engine: WARNING) to avoid container log backpressure: ${QUIET_CONFIG}"
  fi

  echo "Starting container: ${CONTAINER_NAME}"
  podman run "${RUN_ARGS[@]}" "${CONTAINER_IMAGE}"
  STARTED_CONTAINER=true

  # Stream container logs into APP_LOG so the drain-wait grep logic below works
  # the same way as in venv mode.
  podman logs -f "${CONTAINER_NAME}" >"${APP_LOG}" 2>&1 &
  LOG_TAIL_PID=$!
else
  ENV_ARGS=()
  if [[ -n "${VENV_PATH}" ]]; then
    if [[ ! -x "${VENV_PATH}/bin/python" ]]; then
      echo "ERROR: VENV_PATH does not contain an executable bin/python: ${VENV_PATH}" >&2
      exit 1
    fi
    VENV_PATH="$(realpath "${VENV_PATH}")"
    VENV_PYTHON="${VENV_PATH}/bin/python"
    ENV_ARGS+=(
      "VIRTUAL_ENV=${VENV_PATH}"
      "PATH=${VENV_PATH}/bin:${PATH}"
    )
  else
    require_cmd python
    VENV_PYTHON=python
  fi

  if [[ "${MOCK_ARCHIVE_PROCESSING}" == "true" ]]; then
    ENV_ARGS+=(
      "LEAK_MOCK_ARCHIVE_PROCESSING=true"
      "LEAK_MOCK_ARCHIVE_CLUSTER_ID=${MOCK_ARCHIVE_CLUSTER_ID}"
      "PYTHONPATH=${MONKEYPATCH_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
    )
  fi
  if [[ -n "${ARCHIVE_QUEUE_SIZE}" ]]; then
    ENV_ARGS+=("ARCHIVE_QUEUE_SIZE=${ARCHIVE_QUEUE_SIZE}")
  fi

  env "${ENV_ARGS[@]}" "${VENV_PYTHON}" -m app.main >"${APP_LOG}" 2>&1 &
  APP_PID=$!
  echo "App PID: ${APP_PID}"
fi

# Wait for health endpoint (max ~60s)
for _ in $(seq 1 60); do
  if curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then
  echo "ERROR: app did not become healthy at ${HEALTH_URL}" >&2
  echo "See ${APP_LOG}" >&2
  exit 1
fi

echo "App is healthy"

# Record the baseline before the monitor and upload loop start.
sample_memory_now

# Memory monitor loop.
# Primary metric (preferred): process RSS from /proc/<pid>/status (VmRSS).
#   - venv mode:      /proc/${APP_PID}/status on the host.
#   - container mode: `podman exec <container> cat /proc/1/status`, which
#     reads the exact same kernel-level VmRSS as the container's PID 1.
# Secondary metric (container mode only): cgroup-based usage from
#   `podman stats` (informational; can read higher than RSS due to page cache).
if [[ "${RUN_MODE}" == "container" ]]; then
  (
    while podman container exists "${CONTAINER_NAME}" 2>/dev/null; do
      sample_memory_now
      sleep "${SAMPLE_INTERVAL}"
    done
  ) &
  MONITOR_PID=$!
else
  (
    while kill -0 "${APP_PID}" 2>/dev/null; do
      sample_memory_now
      sleep "${SAMPLE_INTERVAL}"
    done
  ) &
  MONITOR_PID=$!
fi

echo "timestamp status_code total_time archive" >"${REQ_LOG}"

success=0
failed=0
archive_count=${#ARCHIVE_LIST[@]}

for i in $(seq 1 "${ITERATIONS}"); do
  if [[ ${archive_count} -gt 0 ]]; then
    CURRENT_FILE="${ARCHIVE_LIST[$(( (i - 1) % archive_count ))]}"
  else
    CURRENT_FILE="${UPLOAD_FILE}"
  fi

  ts="$(date +%s)"
  line="$(curl --max-time "${UPLOAD_TIMEOUT}" -sS -o /dev/null -w "%{http_code} %{time_total}" -F "file=@${CURRENT_FILE}" "${UPLOAD_URL}" || echo "000 0")"
  code="${line%% *}"
  ttotal="${line##* }"
  echo "${ts} ${code} ${ttotal} $(basename "${CURRENT_FILE}")" >>"${REQ_LOG}"

  if [[ "${code}" == "202" ]]; then
    success=$((success + 1))
  else
    failed=$((failed + 1))
  fi

done

# Wait for the archive processor queue to fully drain instead of a fixed sleep.
# Polls the app log (local file in venv mode, tailed container log in container
# mode) until every accepted (202) request has either a successful completion
# record or a worker failure record. Worker failures are tracked separately and
# cause the run to fail even though the upload itself was accepted.
echo "Waiting for archive processor queue to drain (accepted=${success})..."
waited=0
completed=0
worker_failed=0
processed=0
drain_incomplete=0
while :; do
  completed=$(grep -c "Successfully processed cluster" "${APP_LOG}" || true)
  worker_failed=$(grep -c "Archive processing failed" "${APP_LOG}" || true)
  processed=$((completed + worker_failed))
  if [[ "${processed}" -ge "${success}" ]]; then
    echo "  drained ${processed}/${success} (successful=${completed}, worker_failed=${worker_failed}, waited ${waited}s)"
    break
  fi
  if (( waited % 10 == 0 )); then
    echo "  drained ${processed}/${success} (successful=${completed}, worker_failed=${worker_failed}, waited ${waited}s)"
  fi
  if [[ "${waited}" -ge "${DRAIN_TIMEOUT}" ]]; then
    drain_incomplete=$((success - processed))
    echo "ERROR: drain timeout after ${DRAIN_TIMEOUT}s; ${drain_incomplete} accepted request(s) did not complete" >&2
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
successful_requests=${completed}
failed_requests=$((failed + worker_failed + drain_incomplete))
# Record a final synchronous post-drain sample before summarizing so rss_end_mib
# reflects memory after accepted uploads have completed processing.
sample_memory_now


read -r start_mib end_mib peak_mib delta_mib <<<"$(summarize_mem_log "${MEM_LOG}")"

{
  echo "run_mode=${RUN_MODE}"
  echo "mock_archive_processing=${MOCK_ARCHIVE_PROCESSING}"
  echo "archive_source=${ARCHIVE_SOURCE_DESC}"
  echo "report_dir=${REPORT_DIR}"
  echo "app_log=${APP_LOG}"
  echo "memory_log=${MEM_LOG}"
  echo "requests_log=${REQ_LOG}"
  echo "accepted_requests=${success}"
  echo "completed_requests=${completed}"
  echo "worker_failed_requests=${worker_failed}"
  echo "incomplete_requests=${drain_incomplete}"
  echo "accepted_unprocessed_requests=${drain_incomplete}"
  echo "success_requests=${successful_requests}"
  echo "failed_requests=${failed_requests}"
  echo "# Primary metric: process RSS (VmRSS) via /proc/<pid>/status"
  echo "rss_start_mib=${start_mib}"
  echo "rss_end_mib=${end_mib}"
  echo "rss_peak_mib=${peak_mib}"
  echo "rss_delta_mib=${delta_mib}"

  if [[ "${RUN_MODE}" == "container" ]]; then
    read -r ps_start_mib ps_end_mib ps_peak_mib ps_delta_mib <<<"$(summarize_mem_log "${MEM_LOG_PODMAN_STATS}")"
    echo "memory_podman_stats_log=${MEM_LOG_PODMAN_STATS}"
    echo "# Secondary metric (informational): cgroup usage via 'podman stats' (may read higher than RSS due to page cache)"
    echo "podman_stats_mem_start_mib=${ps_start_mib}"
    echo "podman_stats_mem_end_mib=${ps_end_mib}"
    echo "podman_stats_mem_peak_mib=${ps_peak_mib}"
    echo "podman_stats_mem_delta_mib=${ps_delta_mib}"
  fi
} | tee "${SUMMARY_LOG}"

echo "Done. Artifacts in: ${REPORT_DIR}"

if [[ "${drain_incomplete}" -gt 0 ]]; then
  exit 1
fi

if [[ "${failed_requests}" -gt 0 ]]; then
  exit 1
fi
