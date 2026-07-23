#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${ZMK_WORKSPACE:-/opt/zmk-workspace}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$WORKSPACE"

# Copy rather than symlink: west resolves symlinks when locating the
# workspace root, so a symlinked config/ would make it treat the bind-mounted
# repo itself as the west topdir and collide with its own zephyr/ directory.
rm -rf "$WORKSPACE/config"
cp -r "$REPO_DIR/config" "$WORKSPACE/config"

if [ ! -d "$WORKSPACE/zmk" ]; then
  cd "$WORKSPACE"
  west init -l config
  west update
  echo "ZMK workspace initialized at $WORKSPACE"
else
  echo "ZMK workspace already initialized at $WORKSPACE"
  echo "Run .devcontainer/update.sh to pull in changes to config/west.yml"
fi

# west zephyr-export writes to $HOME/.cmake/packages, which lives on the
# container's root filesystem rather than the persisted workspace volume, so
# it must be re-run on every container (re)creation, not just on first init.
cd "$WORKSPACE"
west zephyr-export
