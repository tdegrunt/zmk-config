#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${ZMK_WORKSPACE:-/opt/zmk-workspace}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_DIR/build"

# Also refreshes the workspace's config/ copy and re-exports the Zephyr
# CMake package (cheap/local, and required again after a container rebuild).
"$REPO_DIR/.devcontainer/setup.sh"

mkdir -p "$OUT_DIR"

build_one() {
  local board="$1" shield="$2" artifact="$3" snippet="$4"
  shift 4
  local extra_cmake_args=("$@")

  local name="${artifact:-${shield:+$shield-}$board}"
  local build_dir
  build_dir="$(mktemp -d)"

  echo "==> Building $name (board=$board${shield:+, shield=$shield})"

  local cmake_args=(-DZMK_CONFIG="$WORKSPACE/config" -DZMK_EXTRA_MODULES="$REPO_DIR")
  [ -n "$shield" ] && cmake_args+=(-DSHIELD="$shield")
  cmake_args+=("${extra_cmake_args[@]}")

  local west_args=()
  [ -n "$snippet" ] && west_args+=(-S "$snippet")

  ( cd "$WORKSPACE" && west build -s zmk/app -d "$build_dir" -b "$board" "${west_args[@]}" -- "${cmake_args[@]}" )

  if [ -f "$build_dir/zephyr/zmk.uf2" ]; then
    cp "$build_dir/zephyr/zmk.uf2" "$OUT_DIR/$name.uf2"
    echo "==> Firmware ready: build/$name.uf2"
  else
    echo "==> No .uf2 produced for $name -- check the build log above" >&2
  fi

  rm -rf "$build_dir"
}

if [ "$#" -ge 1 ]; then
  build_one "$1" "${2:-}" "" ""
else
  while IFS=$'\t' read -r board shield artifact snippet cmake_args; do
    # shellcheck disable=SC2086
    build_one "$board" "$shield" "$artifact" "$snippet" $cmake_args
  done < <(python3 "$REPO_DIR/.devcontainer/parse_build_matrix.py" "$REPO_DIR/build.yaml")
fi
