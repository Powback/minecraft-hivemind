#!/bin/zsh
# FUEL FAUCET -- A CHEAT, BY INSTRUCTION. Keeps the networked storage chest topped up with coal and
# revives any drone at 0 fuel with 32 coal, every couple of minutes, via rcon. The user's words on
# 2026-09-04: "cheat in fuel idgaf help them get started". This exists so the tower and factories
# can be worked on while the coal-mining loop is made to pay for itself; kill it when income > burn.
#   bin/fuel-faucet.sh [target_coal=512] [interval_s=120]
set -u
TARGET=${1:-512}; EVERY=${2:-120}
MC=/Users/macback/Projects/minecraft-create121
CHEST="-475 64 78"
rc() { (cd "$MC" && docker compose exec -T mc rcon-cli "$1" </dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'); }
while true; do
  # Coal across the whole bay row: the first chest filled with stone overnight and the faucet sat
  # saying "added 0" for hours while the fleet ran down. Count coal in every chest of the row and
  # put new stacks into whichever has free slots.
  coal=0; added=0
  for x in -480 -479 -478 -477 -476 -475 -474; do
    items=$(rc "data get block $x 64 78 Items"); echo "$items" | grep -q 'block data' || continue
    c=$(echo "$items" | grep -o 'count: [0-9]*, Slot: [0-9]*b, id: "minecraft:coal"' | awk '{s+=$2} END{print s+0}')
    coal=$((coal + c)); sleep 0.3
  done
  if [ "$coal" -lt "$TARGET" ]; then
    need=$(( (TARGET - coal + 63) / 64 ))
    for x in -476 -475 -477 -478 -479 -480 -474; do
      [ $need -le 0 ] && break
      items=$(rc "data get block $x 64 78 Items"); echo "$items" | grep -q 'block data' || continue
      used=$(echo "$items" | grep -o 'Slot: [0-9]*b' | grep -o '[0-9]*' | tr '\n' ' ')
      for s in $(seq 0 26); do
        [ $need -le 0 ] && break
        echo " $used " | grep -q " $s " && continue
        sleep 1; rc "item replace block $x 64 78 container.$s with minecraft:coal 64" >/dev/null; added=$((added+64)); need=$((need-1))
      done
    done
  fi
  revived=""
  dump=$(rc "computercraft dump")
  # Who is dry, from HQ's brief (fuel 0) rather than from the tail of a log that may be saying
  # something else at that moment. Falls back to the log tail when HQ is unreachable.
  dry=$(curl -s --max-time 8 http://hive.pow/brief | python3 -c 'import sys,json
try:
    b=json.load(sys.stdin); print(" ".join(str(x["id"]) for x in b["fleet"]["drones"] if (x.get("fuel") or 0) == 0))
except Exception: print("")' 2>/dev/null)
  for d in "$MC"/data/world/computercraft/computer/*/; do
    id=$(basename "$d"); [ -f "$d/DroneLogic.lua" ] || continue
    line=$(echo "$dump" | grep "^#$id "); [ -z "$line" ] && continue
    if [ -n "$dry" ]; then
      echo " $dry " | grep -q " $id " || continue
    else
      last=$(tail -3 "$d/drone.log" 2>/dev/null | grep -c 'Out of fuel\|fuel at 0 (')
      [ "$last" -gt 0 ] || continue
    fi
    pos=$(echo "$line" | awk -F'|' '{gsub(/,/,"",$3); print $3}' | xargs)
    its=$(rc "data get block $pos Items"); echo "$its" | grep -q 'block data' || continue
    u=$(echo "$its" | grep -o 'Slot: [0-9]*b' | grep -o '[0-9]*' | tr '\n' ' '); slot=""
    for s in $(seq 0 15); do echo " $u " | grep -q " $s " || { slot=$s; break; }; done
    [ -z "$slot" ] && continue
    sleep 1; rc "item replace block $pos container.$slot with minecraft:coal 32" >/dev/null; revived="$revived #$id"
  done
  echo "$(date '+%H:%M:%S') shelf coal was $coal, added $added; revived:${revived:- none}"
  sleep "$EVERY"
done
