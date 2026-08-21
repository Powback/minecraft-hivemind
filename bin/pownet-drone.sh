#!/usr/bin/env bash
# Spawn a PowNet drone: an UNLABELLED wireless turtle running DroneBoot.
#
# Unlabelled is the whole point and it is easy to get wrong. Two different bootloaders exist:
#
#   disk/startup   the MODULE bootloader. Refuses to do anything without a label -- it copies
#                  itself plus PowNet and prints "set the label to the module you want".
#   DroneBoot.lua  the DRONE bootloader. Never looks at the label at all.
#
# A drone must run the second one, because DroneLogic.Init() only registers when the label is
# nil, and DroneMan is what assigns the real name ("D1") in its reply. Label it up front and it
# skips registration forever while still sending heartbeats -- which is exactly the state that
# crash-looped DroneMan before OnHeartbeat learned to answer "unregistered".
#
# So the drone is seeded from the HOST filesystem and placed AWAY from the disk drive: a floppy's
# startup takes precedence over the host's own, so a drone parked next to the drive would get the
# module bootloader instead and just sit at a prompt.
#
# Usage: pownet-drone.sh <x> <y> <z> [id]
set -u
RCON=${RCON:-rcon-cli}
WORLD=${WORLD:-/data/world}
STORE="$WORLD/computercraft/computer"
DISK="$WORLD/computercraft/disk/0"

# ONE argument, always: rcon-cli parses a leading "-" as its own flag, so negative coordinates
# passed as separate words make the command vanish silently while reporting success.
rc() { $RCON "$*"; }

x=${1:?x}; y=${2:?y}; z=${3:?z}; id=${4:-}

if [ -z "$id" ]; then
  max=$( { rc computercraft dump | sed -n 's/^#\([0-9][0-9]*\).*/\1/p'
           ls -1 "$STORE" 2>/dev/null | grep -E '^[0-9]+$'; } | sort -n | tail -1 )
  id=$(( ${max:-0} + 1 ))
fi

echo "── placing drone #$id at $x $y $z"
rc setblock "$x" "$y" "$z" computercraft:turtle_normal replace >/dev/null

# No Label key. Fuel and the modem are not optional: a turtle with no fuel cannot move, and
# DroneBoot bails out with "Could not open rednet" without a modem on left or right.
#
# The pickaxe is not optional either, and the first drone shipped without one: it registered,
# flew to its dock and sat there unable to do the only job the task system knows how to give it,
# because ServerTasks/dig ends in turtle.dig(). A drone that cannot break a block is furniture.
TOOL=${DRONE_TOOL:-minecraft:diamond_pickaxe}
rc data merge block "$x" "$y" "$z" \
  "{ComputerId:$id,Fuel:20000,LeftUpgrade:\"$TOOL\",RightUpgrade:\"computercraft:wireless_modem_normal\"}" >/dev/null

got=$(rc data get block "$x" "$y" "$z" | sed -n 's/.*ComputerId: \([0-9][0-9]*\).*/\1/p')
if [ "$got" != "$id" ]; then
  echo "!! NBT write did not take (block reports '${got:-<none>}') — drone NOT created." >&2
  exit 1
fi

mkdir -p "$STORE/$id"
cp "$DISK/DroneBoot.lua" "$STORE/$id/startup"
cp "$DISK/PowNet"        "$STORE/$id/PowNet"
chmod 777 "$STORE/$id"; chmod 666 "$STORE/$id"/*
echo "── seeded DroneBoot as /startup, unlabelled"

rc computercraft turn-on "$id" >/dev/null
echo "── drone #$id is up"
