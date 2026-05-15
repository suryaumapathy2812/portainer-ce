#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -n "${SWARM_JOIN_TOKEN:-}" ] || {
  printf '%s\n' "Error: SWARM_JOIN_TOKEN is required" >&2
  exit 1
}

[ -n "${SWARM_MANAGER_ADDR:-}" ] || {
  printf '%s\n' "Error: SWARM_MANAGER_ADDR is required" >&2
  exit 1
}

exec "$SCRIPT_DIR/install.sh" "$@"
