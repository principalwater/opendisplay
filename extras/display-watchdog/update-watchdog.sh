#!/bin/bash
# Patch an existing external watchdog; preserve this Mac's private configuration.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
WATCHDOG="${1:-$HOME/.local/bin/opendisplay-watchdog}"
PATCH="$ROOT/portable-displays.patch"
TYPE_PATCH="$ROOT/physical-display-type.patch"

fail() { echo "$*" >&2; exit 1; }
[ "$#" -le 1 ] || fail "Usage: $0 [installed-watchdog]"
[ -f "$WATCHDOG" ] && [ ! -L "$WATCHDOG" ] || fail "Expected a regular watchdog file, not a symlink: $WATCHDOG"
[ "$(/usr/bin/stat -f %u "$WATCHDOG")" = "$(id -u)" ] || fail "Run as the watchdog's owner, without sudo."
/bin/bash -n "$WATCHDOG"

# Reverse application proves the complete patch is already present.
if /usr/bin/patch -C -R -f -F 0 "$WATCHDOG" "$TYPE_PATCH" >/dev/null 2>&1; then
  echo "Portable display handling is already installed."
  exit 0
fi
CANDIDATE=$(mktemp "${WATCHDOG}.candidate.XXXXXX")
trap '/bin/rm -f "$CANDIDATE" "$CANDIDATE.orig" "$CANDIDATE.rej"' EXIT
/bin/cp -p "$WATCHDOG" "$CANDIDATE"
for repair in "$PATCH" "$TYPE_PATCH"; do
  if /usr/bin/patch -C -R -f -F 0 "$CANDIDATE" "$repair" >/dev/null 2>&1; then continue; fi
  /usr/bin/patch -C -N -f -F 0 "$CANDIDATE" "$repair" >/dev/null 2>&1 ||
    fail "Watchdog differs from the supported version. Original unchanged; review the patch manually."
  /usr/bin/patch -N -f -F 0 "$CANDIDATE" "$repair" >/dev/null
done
/bin/bash -n "$CANDIDATE"
BACKUP="${WATCHDOG}.before-portable-displays-$(date -u +%Y%m%dT%H%M%SZ)-$$"
/bin/cp -p "$WATCHDOG" "$BACKUP"
/bin/mv "$CANDIDATE" "$WATCHDOG"
echo "Updated $WATCHDOG"
echo "Backup: $BACKUP"
echo "The next scheduled watchdog tick loads the update; no app restart is needed."
