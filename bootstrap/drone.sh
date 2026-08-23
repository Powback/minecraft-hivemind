#!/bin/zsh
# Place a drone and bring it into the fleet.
#
#   bootstrap/drone.sh <role> <x> <y> <z>      role: miner | scout | loader | crafter
#
# TURTLE NBT IS FUSSY IN TWO WAYS THAT COST TIME.
#
# The upgrade namespaces are not what they look like. The modem is
# computercraft:wireless_modem_normal, but the tools live under MINECRAFT:
#
#     data/minecraft/computercraft/turtle_upgrade/diamond_pickaxe.json
#
# so RightUpgrade must be minecraft:diamond_pickaxe. Given computercraft: it is dropped SILENTLY --
# the merge reports success, the field simply does not appear afterwards, and the turtle comes up
# with no tool and no explanation.
#
# And the upgrade is a compound, not a string: {id:"..."}. A bare string is dropped the same silent
# way. Both of those look identical to a typo you have not made yet.
#
# The role is decided by the tool, because that is what actually constrains the drone: a scout
# carries a geo scanner where a pickaxe would go, which is why a walled-in scout cannot dig itself
# out and needs a miner sent to it.
set -e
cd /Users/macback/Projects/minecraft-create121

ROLE=$1; X=$2; Y=$3; Z=$4
[ -z "$ROLE" ] && { echo "usage: drone.sh <role> <x> <y> <z>"; exit 1; }

REPO=/Users/macback/Projects/HiveMind
WORLD=data/world
rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
state() { rc "computercraft dump" | grep -E "^#$1 " | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

case $ROLE in
  miner|loader)  TOOL='{id:"minecraft:diamond_pickaxe"}' ;;
  crafter)       TOOL='{id:"computercraft:crafting_table"}' ;;
  scout)         TOOL='{id:"advancedperipherals:geoscanner_turtle"}' ;;
  *) echo "unknown role $ROLE"; exit 1 ;;
esac

echo "== $ROLE at $X $Y $Z"
rc "forceload add $((X-16)) $((Z-16)) $((X+16)) $((Z+16))" >/dev/null
rc "setblock $X $Y $Z minecraft:air" >/dev/null; sleep 1
# Fuelled on placement. A drone with no fuel cannot reach the dock where the fuel is, and the first
# thing the fleet would have to do is rescue the drone it just created.
rc "setblock $X $Y $Z computercraft:turtle_normal{Fuel:100000,LeftUpgrade:{id:\"computercraft:wireless_modem_normal\"},RightUpgrade:$TOOL,On:1b}" >/dev/null
sleep 5

ID=$(rc "computercraft dump" | grep -F "| $X, $Y, $Z" | grep -oE '^#[0-9]+' | tr -d '#')
[ -z "$ID" ] && { echo "   no id -- did the turtle place?"; exit 1; }
echo "   turtle #$ID"

D="$WORLD/computercraft/computer/$ID"
mkdir -p "$D"
cp "$REPO/lua/DroneBoot.lua"  "$D/startup"      # the drone's bootloader IS DroneBoot
cp "$REPO/lua/DroneLogic.lua" "$D/DroneLogic.lua"
cp "$REPO/lua/PowNet"         "$D/PowNet"
cp "$REPO/lua/pgps.lua"       "$D/pgps"         # loaded as os.loadAPI("pgps"), so no extension
chmod -R a+rwX "$D"

for t in 1 2 3 4; do rc "computercraft shutdown $ID" >/dev/null 2>&1; sleep 4; [ "$(state $ID)" = "N" ] && break; done
for t in 1 2 3;    do rc "computercraft turn-on  $ID" >/dev/null 2>&1; sleep 4; [ "$(state $ID)" = "Y" ] && break; done
echo "   $ROLE #$ID on=$(state $ID)"
