#!/usr/bin/env bash
# Copy this repo's Lua tree onto the floppy, which is what the fleet actually runs.
#
# The world is a SEPARATE repo (the Minecraft server), and its `data/` is gitignored because it is
# a live world. So the floppy at data/world/computercraft/disk/0/ is not version controlled
# anywhere: every fix made by editing it directly exists in one directory that a world reset or a
# restore-from-backup silently reverts. `lua/` here is the copy that survives; this puts it back.
#
#   pownet-sync.sh          push lua/ -> floppy   (deploy)
#   pownet-sync.sh --back   pull floppy -> lua/   (capture edits made in-world)
#   pownet-sync.sh --diff   show what differs, change nothing
#
# MainFrame serves these files to every module over rednet, so writing the floppy IS deploying.
# Modules pick changes up on reboot — but see the two-reboot rule below.
#
# This is the LOCAL deploy path and needs filesystem access to the world. The other path needs
# none: HQ publishes this same tree at /lua/manifest and Sync.lua pulls it in-world over HTTP.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/lua"

# The server lives in its own checkout. Override WORLD to point at any world directory; the
# default assumes minecraft-create121 sits beside this repo.
WORLD=${WORLD:-$(cd "$REPO/.." && pwd)/minecraft-create121/data/world}
DST="$WORLD/computercraft/disk/0"

[ -d "$SRC" ] || { echo "!! no $SRC" >&2; exit 1; }
[ -d "$DST" ] || {
  echo "!! no floppy at $DST" >&2
  echo "   Set WORLD=/path/to/world if the server checkout is elsewhere." >&2
  exit 1
}

case "${1:-}" in
  --diff) diff -ru "$SRC" "$DST"; exit 0 ;;
  --back) FROM="$DST"; TO="$SRC"; WHAT="floppy -> lua/" ;;
  "")     FROM="$SRC"; TO="$DST"; WHAT="lua/ -> floppy" ;;
  *)      echo "usage: pownet-sync.sh [--back|--diff]" >&2; exit 2 ;;
esac

echo "── $WHAT"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$FROM/" "$TO/"
else
  rm -rf "${TO:?}"/* && cp -R "$FROM/." "$TO/"
fi

# The server runs as a different uid inside the container and the mount is VirtioFS, where chown
# is a no-op but chmod works. Without this the computers cannot read what was just delivered.
chmod -R a+rX "$TO"
find "$TO" -type f -exec chmod 666 {} \;

echo "── $(find "$TO" -type f | wc -l | tr -d ' ') files in place"
cat <<'NOTE'

Reboot the modules to pick this up — TWICE if PowNet itself changed. The bootloader does
os.loadAPI("PowNet") before PowNet.UpdateModule("PowNet"), so the first reboot only downloads the
new API and the second one actually loads it. A module that pulls its own new .lua while still
running the old PowNet dies on whatever function is new, with the file plainly on disk.
NOTE
