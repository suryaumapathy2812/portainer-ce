#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEPLOY_AGENT=false exec "$SCRIPT_DIR/install.sh" "$@"
