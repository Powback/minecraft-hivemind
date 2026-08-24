#!/bin/zsh
# A rednet repeater on the mast.
#
# The fleet's working radius is limited by TWO ranges, and only one of them was ever measured:
#
#   GPS coverage -- four hosts audible -- which the constellation was sized for, and
#   rednet range to the MODULES, which nothing was sized for at all.
#
# Every module sits in the tower at y=64, and a wireless modem reaches about 64 blocks. So a drone
# working the far edge of its permitted region is out of radio range of the very computers giving it
# orders: it cannot heartbeat, cannot report, cannot be assigned anything, and reads as "lost" while
# running perfectly. D2 went silent 76 blocks out, and the square geometry makes it worse than it
# looks -- a square of radius r has corners at r * root 2, so even reach 48 puts a corner 58 blocks
# away.
#
# Shrinking the region until the corners fit would leave a working radius of about 36, which is
# barely outside the tower. The right answer is the one already in the tower design: a mast. CC ships
# rom/programs/rednet/repeat.lua, which rebroadcasts anything it hears -- and modem range grows with
# altitude, so a repeater on the roof both hears further and is heard further.
#
# This is the cap level of the tower, arriving early because the fleet needs it before it can build
# anything that tall.
set -e
cd /Users/macback/Projects/minecraft-create121

REPO=/Users/macback/Projects/HiveMind
WORLD=data/world
# HEIGHT IS A TRADE-OFF, NOT A MAXIMUM.
#
# Altitude increases a modem's own range, so the instinct is to put the repeater as high as possible.
# But a drone is only heard if the DRONE can reach the repeater, and a drone at ground level has the
# short low-altitude range -- so every block of extra height is a block of distance spent before any
# horizontal reach at all. At y=112 a ground drone at the region edge is 83 blocks away and silent,
# which is exactly how D3 went quiet at x=-412 twice.
#
# y=85 is the height at which BOTH a ground drone and one cruising at y=110 stay inside 64 blocks
# across a reach of 56. Measured, not picked.
X=-480; Y=85; Z=64

rc() { docker compose exec -T mc rcon-cli "$1" </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
state() { rc "computercraft dump" | grep -E "^#$1 " | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

echo "== placing the repeater at $X $Y $Z"
rc "forceload add $((X-8)) $((Z-8)) $((X+8)) $((Z+8))" >/dev/null
rc "setblock $X $Y $Z computercraft:computer_normal" >/dev/null
rc "setblock $X $((Y+1)) $Z computercraft:wireless_modem_normal[facing=down]" >/dev/null
rc "data merge block $X $Y $Z {On:1b}" >/dev/null
sleep 5

ID=$(rc "computercraft dump" | grep -F "| $X, $Y, $Z" | grep -oE '^#[0-9]+' | tr -d '#')
[ -z "$ID" ] && { echo "   could not resolve an id"; exit 1; }
echo "   computer #$ID"

D="$WORLD/computercraft/computer/$ID"
mkdir -p "$D"
cat > "$D/startup" <<'EOF'
-- Rednet repeater. Rebroadcasts everything it hears, so drones working the far edge of the
-- settlement can still reach the modules that give them orders.
print("repeater up")
shell.run("/rom/programs/rednet/repeat.lua")
-- Only reached if the program returned. The first attempt used shell.run("rednet/repeat"),
-- which does not resolve -- the shell path does not include that directory -- so it returned
-- instantly and the repeater looked placed and did nothing.
local h = fs.open("/repeater-exited.txt", "w")
if h then h.write("rednet/repeat returned -- no modem attached?\n") h.close() end
EOF
chmod -R a+rwX "$D"

for t in 1 2 3; do rc "computercraft shutdown $ID" >/dev/null 2>&1; sleep 4; [ "$(state $ID)" = "N" ] && break; done
for t in 1 2 3; do rc "computercraft turn-on  $ID" >/dev/null 2>&1; sleep 4; [ "$(state $ID)" = "Y" ] && break; done
echo "   repeater #$ID on=$(state $ID)"
