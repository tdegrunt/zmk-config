#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${ZMK_WORKSPACE:-/opt/zmk-workspace}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$WORKSPACE/zmk" ]; then
  exec "$REPO_DIR/.devcontainer/setup.sh"
fi

cd "$WORKSPACE"
west update
west zephyr-export
