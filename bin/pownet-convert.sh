#!/usr/bin/env bash
# Turn an existing labelled turtle into an unregistered PowNet drone.
#
# Two things make this more than "edit the label":
#
#  1. Label and upgrades are RUNTIME state. CC:T writes the live turtle back over the block NBT on
#     shutdown, so an edit made while it runs is silently undone. It must be OFF.
#  2. DroneLogic registers only when the label is nil, and registration ends with
#     pgps.setLocationFromGPS(), which steps the turtle forward and back to work out its heading.
#     A turtle boxed into a base wall cannot do that. So it is relocated into open air rather than
#     converted where it stands — which also avoids digging up the base to make room.
#
# The ComputerId is preserved, so it keeps its identity and its files directory; only the label
# goes, and DroneMan issues the real name (D4, D5, ...) when it registers.
#
# Usage: pownet-convert.sh <id> <oldx> <oldy> <oldz> <newx> <newy> <newz>
set -u
RCON=${RCON:-rcon-cli}
WORLD=${WORLD:-/data/world}
STORE="$WORLD/computercraft/computer"
DISK="$WORLD/computercraft/disk/0"
rc() { $RCON "$*"; }   # ONE argument: rcon-cli eats leading "-" as its own flags

id=${1:?id}; ox=${2:?}; oy=${3:?}; oz=${4:?}; nx=${5:?}; ny=${6:?}; nz=${7:?}

echo "── #$id: $ox $oy $oz  ->  $nx $ny $nz"
rc computercraft shutdown "$id" >/dev/null
sleep 3

# Old block first: two blocks claiming one ComputerId is not a state worth being in.
rc setblock "$ox" "$oy" "$oz" minecraft:air >/dev/null
rc setblock "$nx" "$ny" "$nz" computercraft:turtle_normal replace >/dev/null

# No Label key -- that omission is the whole point.
rc data merge block "$nx" "$ny" "$nz" \
  "{ComputerId:$id,Fuel:20000,LeftUpgrade:\"minecraft:diamond_pickaxe\",RightUpgrade:\"computercraft:wireless_modem_normal\"}" >/dev/null

got=$(rc data get block "$nx" "$ny" "$nz" | sed -n 's/.*ComputerId: \([0-9][0-9]*\).*/\1/p')
[ "$got" = "$id" ] || { echo "!! NBT did not take (block reports '${got:-none}')" >&2; exit 1; }
if rc data get block "$nx" "$ny" "$nz" | grep -q 'Label:'; then
  echo "!! it still has a label — it will skip registration" >&2; exit 1
fi

# Replace whatever bootloader it used to run with the drone one.
rm -f "$STORE/$id"/startup "$STORE/$id"/startup.lua "$STORE/$id"/main.lua
mkdir -p "$STORE/$id"
cp "$DISK/DroneBoot.lua" "$STORE/$id/startup"
cp "$DISK/PowNet"        "$STORE/$id/PowNet"
chmod 777 "$STORE/$id"; chmod 666 "$STORE/$id"/*

rc computercraft turn-on "$id" >/dev/null
echo "── #$id is up, unlabelled, awaiting registration"
