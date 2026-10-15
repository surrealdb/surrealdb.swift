#!/usr/bin/env bash
set -euo pipefail

export SURREALDB_RUN_INTEGRATION=1

SURREAL_PID=""
START_MODE=""
# A binary given in SURREALDB_BIN means "test this one": run it locally
# rather than letting auto mode pick Docker.
if [[ -n "${SURREALDB_BIN:-}" ]]; then
  INTEGRATION_MODE="${SURREALDB_INTEGRATION_MODE:-local}"
else
  INTEGRATION_MODE="${SURREALDB_INTEGRATION_MODE:-auto}"
fi
SURREALDB_BIND_HOST="${SURREALDB_BIND_HOST:-127.0.0.1}"
SURREALDB_PORT="${SURREALDB_PORT:-8000}"

export SURREALDB_HOST="${SURREALDB_HOST:-${SURREALDB_BIND_HOST}:${SURREALDB_PORT}}"
export SURREALDB_USER="${SURREALDB_USER:-root}"
export SURREALDB_PASSWORD="${SURREALDB_PASSWORD:-root}"
export SURREALDB_AUTH_LEVEL="${SURREALDB_AUTH_LEVEL:-root}"
export SURREALDB_NAMESPACE="${SURREALDB_NAMESPACE:-test}"
export SURREALDB_NAME="${SURREALDB_NAME:-test}"

cleanup() {
  if [[ "$START_MODE" == "docker" ]] && command -v docker >/dev/null 2>&1; then
    docker compose -f docker-compose.integration.yml down -v
  fi

  if [[ "$START_MODE" == "local" && -n "$SURREAL_PID" ]]; then
    kill "$SURREAL_PID" >/dev/null 2>&1 || true
  fi
}

wait_for_surreal() {
  local max_attempts=60
  local attempt=1

  until curl -fsS "http://${SURREALDB_BIND_HOST}:${SURREALDB_PORT}/health" >/dev/null 2>&1; do
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "SurrealDB failed to become ready after ${max_attempts} seconds."
      if [[ "$START_MODE" == "local" ]]; then
        echo "--- SurrealDB local log ---"
        cat .build/surrealdb.log || true
      fi
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
}

start_docker() {
  docker compose -f docker-compose.integration.yml up -d --wait
  START_MODE="docker"
}

start_local_surreal() {
  local surreal_bin
  # SURREALDB_BIN pins the server binary (CI installs one per matrix entry).
  surreal_bin="${SURREALDB_BIN:-$(command -v surreal || true)}"
  local install_dir="${PWD}/.build/surrealdb-bin"

  if [[ -z "$surreal_bin" ]]; then
    surreal_bin="${install_dir}/surreal"
  fi

  if [[ ! -x "$surreal_bin" ]]; then
    echo "Docker unavailable; installing SurrealDB binary via install script..."
    mkdir -p "$install_dir"
    curl -sSf https://install.surrealdb.com | sh -s -- "$install_dir"
    surreal_bin="${install_dir}/surreal"
  fi

  if [[ ! -x "$surreal_bin" ]]; then
    echo "Unable to find executable 'surreal' binary."
    return 1
  fi

  mkdir -p .build
  "${surreal_bin}" start --log info --user "${SURREALDB_USER}" --pass "${SURREALDB_PASSWORD}" memory --bind "${SURREALDB_BIND_HOST}:${SURREALDB_PORT}" > .build/surrealdb.log 2>&1 &
  SURREAL_PID="$!"
  START_MODE="local"
}

trap cleanup EXIT

if [[ "$INTEGRATION_MODE" == "docker" ]]; then
  start_docker
elif [[ "$INTEGRATION_MODE" == "local" ]]; then
  start_local_surreal
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if ! start_docker; then
    echo "Docker is available but compose startup failed; falling back to local SurrealDB binary."
    start_local_surreal
  fi
else
  start_local_surreal
fi

wait_for_surreal

echo "Testing against $(curl -fsS "http://${SURREALDB_BIND_HOST}:${SURREALDB_PORT}/version")"

# Create the namespace and database up front: tests run in parallel, and
# racing to create them can hit a transaction conflict on a fresh server.
curl -fsS -u "${SURREALDB_USER}:${SURREALDB_PASSWORD}" -H "Accept: application/json" \
  --data-binary "DEFINE NAMESPACE IF NOT EXISTS ${SURREALDB_NAMESPACE}; USE NS ${SURREALDB_NAMESPACE}; DEFINE DATABASE IF NOT EXISTS ${SURREALDB_NAME};" \
  "http://${SURREALDB_BIND_HOST}:${SURREALDB_PORT}/sql" >/dev/null

# Every test whose name starts with integration_ (they skip themselves
# unless SURREALDB_RUN_INTEGRATION=1).
swift test --filter integration_
