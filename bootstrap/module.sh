#!/bin/zsh
# Stand up one module computer: place it, boot it, give it its files, label it, run it.
#
#   bootstrap/module.sh <Label> <x> <y> <z>
#
# LABELS ARE SELF-APPLIED, NOT SET FROM OUTSIDE.
#
# The bootloader decides which module to run from os.getComputerLabel(), so the label has to exist
# before it reads it. `data merge block {Label:"X"}` looks like the way and silently does nothing --
# the dump still reports an empty label afterwards. So the startup labels its own machine and reboots
# once, which is idempotent, survives PowNet.UpdateModule overwriting startup later (the label
# persists in the computer, not the file), and is the same thing a turtle can do to a computer it has
# just placed.
#
# MAINFRAME NEEDS NO DISK DRIVE.
#
# MainFrame loads its APIs from "disk/PowNet" and serves files out of "disk/", which reads like it
# requires a drive and a floppy -- awkward to place by command, since the disk is an ITEM inside a
# block. But "disk" there is just a relative path. With no drive attached, a plain directory of that
# name inside the computer's own folder resolves identically, so the whole floppy problem disappears.
set -e
cd /Users/macback/Projects/minecraft-create121

LABEL=$1; X=$2; Y=$3; Z=$4
[ -z "$LABEL" ] && { echo "usage: module.sh <Label> <x> <y> <z>"; exit 1; }

REPO=/Users/macback/Projects/HiveMind
WORLD=data/world
rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
state() { rc "computercraft dump" | grep -E "^#$1 " | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

# A verified power cycle. `turn-on` is a silent no-op if it lands while the machine is still shutting
# down, which left three of four GPS hosts ON, at a shell prompt, hosting nothing.
cycle() {
  local id=$1 t
  for t in 1 2 3 4; do rc "computercraft shutdown $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "N" ] && break; done
  for t in 1 2 3;    do rc "computercraft turn-on  $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "Y" ] && break; done
}

echo "== $LABEL at $X $Y $Z"
rc "forceload add $((X-8)) $((Z-8)) $((X+8)) $((Z+8))" >/dev/null
# FACING (north/south/east/west) is which way the screen looks: wall stations face into the room.
rc "setblock $X $Y $Z computercraft:computer_normal[facing=${FACING:-north}]" >/dev/null
rc "setblock $X $((Y+1)) $Z computercraft:wireless_modem_normal[facing=down]" >/dev/null
rc "data merge block $X $Y $Z {On:1b}" >/dev/null
sleep 5

ID=$(rc "computercraft dump" | grep -F "| $X, $Y, $Z" | grep -oE '^#[0-9]+' | tr -d '#')
[ -z "$ID" ] && { echo "   could not resolve an id -- did the block get placed?"; exit 1; }
echo "   computer #$ID"

D="$WORLD/computercraft/computer/$ID"
mkdir -p "$D"

# The bootloader, and the label preamble that has to run before it.
{
  echo "-- Label first: the bootloader below dispatches on os.getComputerLabel(), so it must exist"
  echo "-- before that line runs. Idempotent, and the reboot happens exactly once."
  echo "if os.getComputerLabel() ~= \"$LABEL\" then os.setComputerLabel(\"$LABEL\") os.reboot() end"
  cat "$REPO/lua/startup"
} > "$D/startup"

if [ "$LABEL" = "MainFrame" ]; then
  # Everything it loads AND everything it serves. UpdateModule hands these out to the rest of the
  # fleet, so a file missing here is a module that can never come up anywhere.
  mkdir -p "$D/disk"
  cp -R "$REPO"/lua/* "$D/disk/" 2>/dev/null || true
  echo "   disk/: $(ls "$D/disk" | wc -l | tr -d ' ') entries"
else
  # Its own module, plus PowNet to talk with. Everything else arrives from MainFrame on first boot.
  cp "$REPO/lua/PowNet" "$D/PowNet"
  [ -f "$REPO/lua/$LABEL.lua" ] && cp "$REPO/lua/$LABEL.lua" "$D/$LABEL.lua"
  # MapServer loads these at its very first line, so they cannot arrive one boot later.
  if [ "$LABEL" = "MapServer" ]; then
    cp "$REPO/lua/PowGPSServer.lua" "$D/PowGPSServer" 2>/dev/null || true
    cp "$REPO/lua/MapRender.lua"    "$D/MapRender"    2>/dev/null || true
  fi
  [ -d "$REPO/lua/ServerTasks" ] && cp -R "$REPO/lua/ServerTasks" "$D/ServerTasks"
fi

chmod -R a+rwX "$D"
cycle $ID
echo "   $LABEL is #$ID, on=$(state $ID)"
echo "$ID" > "/private/tmp/claude-501/-Users-macback/52e2a9bb-ae40-4df1-bce7-106c98b31824/scratchpad/id-$LABEL.txt"
