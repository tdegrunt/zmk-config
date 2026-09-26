#!/usr/bin/env bash
# Flash a split keyboard from the firmware listed in build.yaml.
#
# Pick a keyboard (board + shield), then reset each half into its bootloader
# when prompted; the matching .uf2 is copied onto the half's USB volume.
#
# Usage: ./flash.sh [-r] [-d firmware_dir] [-L left_volume] [-R right_volume]
#   -r   list settings_reset builds instead of the regular firmware
#   -d   directory holding the .uf2 files (default: ./build)
#   -L   bootloader volume name of the left half   (env LEFT_VOLUME)
#   -R   bootloader volume name of the right half  (env RIGHT_VOLUME)
#        Without a name, any mounted volume containing INFO_UF2.TXT is used.
#
# Works with bash 3.2 (macOS). Run it on the host, where the volumes mount.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_YAML="$REPO_DIR/build.yaml"
FIRMWARE_DIR="${FIRMWARE_DIR:-$REPO_DIR/build}"
LEFT_VOLUME="${LEFT_VOLUME:-}"
RIGHT_VOLUME="${RIGHT_VOLUME:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
RESET_MODE=0

usage() { sed -n '2,14s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

while getopts "rd:L:R:h" opt; do
  case "$opt" in
    r) RESET_MODE=1 ;;
    d) FIRMWARE_DIR="$OPTARG" ;;
    L) LEFT_VOLUME="$OPTARG" ;;
    R) RIGHT_VOLUME="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

# Emit one tab-separated line per build.yaml entry: key, half, uf2 name, shield.
# The uf2 name mirrors build.sh / the GitHub workflow: artifact-name, or
# "<shield>-<board>" when no artifact-name is given.
parse_builds() {
  awk -v reset="$RESET_MODE" '
    function trim(s) { sub(/[ \t]*#.*$/, "", s); gsub(/^[ \t"'\'']+|[ \t"'\'']+$/, "", s); return s }
    function flush() {
      if (board == "") return
      if ((shield == "settings_reset") == (reset == 1)) {
        name = artifact != "" ? artifact : (shield != "" ? shield "-" board : board)
        half = board ~ /_left$/ ? "left" : board ~ /_right$/ ? "right" : \
               name  ~ /_left$/ ? "left" : name  ~ /_right$/ ? "right" : "single"
        key = name
        sub(/_(left|right)$/, "", key)
        print key "\t" half "\t" name "\t" shield
      }
      board = shield = artifact = ""
    }
    /^[ \t]*-[ \t]/ { flush(); sub(/^[ \t]*-[ \t]*/, "") }
    /^[^ \t-]/      { flush() }
    /^[ \t]*board:/         { v = $0; sub(/^[^:]*:/, "", v); board    = trim(v) }
    /^[ \t]*shield:/        { v = $0; sub(/^[^:]*:/, "", v); shield   = trim(v) }
    /^[ \t]*artifact-name:/ { v = $0; sub(/^[^:]*:/, "", v); artifact = trim(v) }
    END { flush() }
  ' "$BUILD_YAML"
}

MOUNT_ROOTS="/Volumes${USER:+ /media/$USER /run/media/$USER} /media"

# Print the mount point of the bootloader volume: the one named $1, or, when $1
# is empty, the first volume that has the UF2 bootloader's INFO_UF2.TXT.
volume_path() {
  local vol="$1" root p
  for root in $MOUNT_ROOTS; do
    [ -d "$root" ] || continue
    if [ -n "$vol" ]; then
      if [ -d "$root/$vol" ]; then echo "$root/$vol"; return 0; fi
    else
      for p in "$root"/*/INFO_UF2.TXT; do
        if [ -f "$p" ]; then dirname "$p"; return 0; fi
      done
    fi
  done
  return 1
}

volume_label() { echo "${1:-any UF2 bootloader volume}"; }

wait_for_volume() {
  local vol="$1" waited=0
  while ! volume_path "$vol" >/dev/null; do
    if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
      echo >&2
      echo "Timed out after ${WAIT_TIMEOUT}s waiting for $(volume_label "$vol") (looked in: $MOUNT_ROOTS)." >&2
      return 1
    fi
    printf '.'
    sleep 1
    waited=$((waited + 1))
  done
  echo
}

# The bootloader reboots as soon as it has the image, so wait for the mount to
# go away before continuing (both halves often share the same volume name).
wait_for_unmount() {
  local mount="$1" waited=0
  while [ -d "$mount" ] && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
}

flash_half() {
  local half="$1" file="$2" vol="$3" mount
  echo
  echo "=== ${half} half: $(basename "$file") -> $(volume_label "$vol")"
  if mount="$(volume_path "$vol")"; then
    echo "A bootloader volume is already mounted at $mount."
    read -r -p "Is that the ${half} half? [y/N] " answer
    case "$answer" in [yY]*) ;; *)
      echo "Eject it (or unplug it) first, then re-run." >&2
      return 1 ;;
    esac
  else
    read -r -p "Connect the ${half} half over USB and double-tap its reset button, then press Enter... " _
    printf "Waiting for %s" "$(volume_label "$vol")"
    wait_for_volume "$vol"
    mount="$(volume_path "$vol")"
  fi

  echo "Copying to $mount ..."
  # The device may reboot before cp finishes closing the file, which makes cp
  # report an error even though the flash succeeded.
  if ! cp "$file" "$mount/" 2>/dev/null; then
    echo "(cp reported an error; this is normal if the board rebooted right away)"
  fi
  sync 2>/dev/null || true
  wait_for_unmount "$mount"
  echo "${half} half flashed."
}

if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ]; then
  echo "Warning: this looks like a container; USB volumes usually only mount on the host." >&2
fi

builds="$(parse_builds)"
if [ -z "$builds" ]; then
  echo "No matching builds found in $BUILD_YAML." >&2
  exit 1
fi

# Unique keyboard keys, in build.yaml order, with their shield for display.
keys=()
labels=()
while IFS=$'\t' read -r key shield; do
  keys+=("$key")
  labels+=("$key${shield:+  [shield: $shield]}")
done < <(printf '%s\n' "$builds" | awk -F'\t' '!seen[$1]++ { print $1 "\t" $4 }')

echo "Firmware directory: $FIRMWARE_DIR"
echo "Volumes: left=$(volume_label "$LEFT_VOLUME")  right=$(volume_label "$RIGHT_VOLUME")"
echo
PS3="Select keyboard: "
label=""
select label in "${labels[@]}"; do
  [ -n "${label:-}" ] && break
  echo "Invalid choice."
done
[ -n "$label" ] || { echo "No keyboard selected." >&2; exit 1; }
key="${keys[$((REPLY - 1))]}"

# Flash left first, then right, then any unsplit build.
flashed=0
for half in left right single; do
  name="$(printf '%s\n' "$builds" | awk -F'\t' -v k="$key" -v h="$half" '$1 == k && $2 == h { print $3; exit }')"
  [ -n "$name" ] || continue
  file="$FIRMWARE_DIR/$name.uf2"
  if [ ! -f "$file" ]; then
    echo "Missing $file -- build it with .devcontainer/build.sh or download it from GitHub Actions." >&2
    exit 1
  fi
  case "$half" in
    left)   vol="$LEFT_VOLUME" ;;
    right)  vol="$RIGHT_VOLUME" ;;
    single) vol="$LEFT_VOLUME" ;;
  esac
  flash_half "$half" "$file" "$vol"
  flashed=$((flashed + 1))
done

echo
echo "Done: flashed $flashed half/halves of $key."
