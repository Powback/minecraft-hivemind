#!/bin/zsh
# Stand up a GPS constellation from nothing.
#
# This is the first link in the chain the whole settlement hangs off: without a position fix a drone
# cannot path, cannot report where it is, and cannot be rescued. In the last world the 22 GPS hosts
# were placed by hand and never reproducible, which is the thing this file exists to stop.
#
# THE PRIMITIVE THAT MAKES IT POSSIBLE.
#
# A computer placed with /setblock has no ID and no directory -- CC:T allocates both when the machine
# first boots, and /computercraft turn-on takes an ID, so there is no way in by that door. But the
# block entity carries an On flag, and setting it:
#
#     data merge block <x> <y> <z> {On:1b}
#
# boots the computer, which allocates the ID, which makes it addressable. Everything else follows:
# read the ID back out of the dump by position, write files straight into its directory on the host
# filesystem, reboot it so it runs them.
#
# A turtle does the same sequence through peripherals rather than commands -- place, then
# peripheral.call("front","turnOn"), then write via the disk drive's getMountPath -- so this script is
# the rehearsal for that, not a detour around it.
#
# WHY THESE FOUR POSITIONS.
#
# GPS needs four hosts, and they must not be coplanar: four hosts on one Y solve x and z and leave
# altitude undetermined, which cost a lot of confusion last time. So the heights are all different.
# They are also high, because a wireless modem's range grows with altitude, and the fleet's single
# most common failure is drones dropping out of contact underground.
set -e
cd /Users/macback/Projects/minecraft-create121

WORLD=data/world
rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }

# x y z -- spread around the tower centre (-480, 64), four distinct altitudes.
# RANGE IS SET BY THE DRONE, NOT BY THE HOST.
#
# The first attempt put these at y=130-148 on the theory that altitude buys range -- it does, but the
# range that decides whether a fix happens is the range of the machine ASKING. A probe standing in
# the tower gallery at y=65 reaches about 64 blocks, the hosts were 87 away, and it reported NO FIX
# with all four hosts up and healthy. Height helps the reply and does nothing for the question.
#
# So they sit close enough that every part of the tower can reach them: about 50-56 blocks from the
# centre, still on four distinct altitudes so a fix can resolve Y.
# FOUR DIFFERENT ALTITUDES IS NOT THE SAME AS NOT COPLANAR.
#
# The previous set was -512/88/32, -448/92/32, -512/96/96, -448/100/96 -- four distinct heights, which
# looked like it satisfied the rule. It did not. Y was a linear function of X and Z, so the four
# points lay exactly in one plane: AB + AC = AD, to the block. Trilateration from a plane cannot
# resolve which side of it you are on, so gps.locate returned nil while all four hosts answered
# correctly with distances of 49 to 58 blocks. Everything looked healthy and the fix was impossible.
#
# The check that matters is the scalar triple product of the three edge vectors from any one host,
# and it must not be zero. For these it is 49,152.
HOSTS=(
  "-512 76 32"
  "-448 92 32"
  "-512 96 96"
  "-448 100 96"
)

# Anything left from a previous constellation, so re-running this does not leave stale hosts
# answering with positions that are no longer where they are.
OLD=(
  "-520 130 24" "-440 136 24" "-520 142 104" "-440 148 104"
  "-512 88 32"
)

echo "== keeping the constellation loaded"
rc "forceload add -530 14 -430 114" >/dev/null

echo "== clearing any previous constellation"
for h in $OLD; do
  set -- ${=h}; x=$1; y=$2; z=$3
  rc "setblock $x $y $z minecraft:air" >/dev/null 2>&1 || true
  rc "setblock $x $((y+1)) $z minecraft:air" >/dev/null 2>&1 || true
done

echo "== placing"
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  rc "setblock $x $y $z computercraft:computer_normal" >/dev/null
  # Above the computer, facing DOWN so it attaches to it. A modem placed with default facing points
  # north, attaches to nothing, and the computer comes up with no way to talk -- which reads from
  # outside exactly like a dead computer.
  rc "setblock $x $((y+1)) $z computercraft:wireless_modem_normal[facing=down]" >/dev/null
  echo "   host at $x $y $z"
done

echo "== booting, to allocate ids"
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  rc "data merge block $x $y $z {On:1b}" >/dev/null
done
sleep 6

echo "== resolving ids by position"
DUMP=$(rc "computercraft dump")
typeset -A ID_OF
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  id=$(echo "$DUMP" | grep -F "| $x, $y, $z" | grep -oE '^#[0-9]+' | tr -d '#')
  [ -z "$id" ] && { echo "   FAILED to resolve id at $x $y $z"; exit 1; }
  ID_OF[$h]=$id
  echo "   $x $y $z -> computer #$id"
done

echo "== writing each host its own coordinates"
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  id=${ID_OF[$h]}
  d="$WORLD/computercraft/computer/$id"
  mkdir -p "$d"
  # Each host must announce ITS OWN position, so the file cannot be generic -- which is the whole
  # reason a bootstrap turtle needs to write to the floppy rather than carry a prepared one.
  cat > "$d/startup" <<EOF
-- GPS host. Written by bootstrap/gps.sh; a turtle writes the same file via the disk drive's
-- getMountPath when it does this for itself.
print("GPS host $x $y $z")
shell.run("gps", "host", "$x", "$y", "$z")
EOF
  chmod 666 "$d/startup"
done
chmod -R a+rX "$WORLD/computercraft" 2>/dev/null || true

echo "== rebooting onto the startup"
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  rc "computercraft shutdown ${ID_OF[$h]}" >/dev/null
done
sleep 4
for h in $HOSTS; do
  set -- ${=h}; x=$1; y=$2; z=$3
  rc "computercraft turn-on ${ID_OF[$h]}" >/dev/null
done
sleep 6

echo "== constellation:"
rc "computercraft dump" | sed 's/^/   /'
