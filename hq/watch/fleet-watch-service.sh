#!/bin/bash
# bin/fleet-watch.sh, containerised. Same rules: print [FAULT]/[CLEARED] lines as the brief's
# problem list changes; alarm-class faults go in-game via RCON. A monitor that only writes to a file
# nobody reads is not a monitor -- this one's log is `docker compose logs -f fleet-watch`.
set -u
HQ_URL="${HQ_URL:-http://hq:4400}"
POLL="${POLL:-60}"
RCON_HOST="${RCON_HOST:-mc-create121}"; RCON_PORT="${RCON_PORT:-25575}"; RCON_PASSWORD="${RCON_PASSWORD:-}"
ALARM="${ALARM:-FUEL TRAP|FUEL SPIRAL|NO INCOME|RESCUE TREADMILL|IDLE WITH WORK|OUT OF FUEL|LOST|HQ UNREACHABLE|HQ SEES NO FLEET}"
read_faults() {
  local body
  body=$(curl -s --max-time 15 "$HQ_URL/brief") || { echo "HQ UNREACHABLE"; return; }
  echo "$body" | jq -r '
    if (.fleet.total // 0) == 0 then "HQ SEES NO FLEET (bridge down, or DroneMan not answering)"
    else (.problems // [])[] | select(. != "none")
      | gsub("\\s+"; " ") | gsub("\\((\\d+)\\)"; "(n)") | gsub("silent \\d+s"; "silent Ns") | gsub("for \\d+ min"; "for N min") | gsub("\\d+ of (?<t>\\d+) drones are dry"; "n of \(.t) drones are dry") | .[0:200]
    end' 2>/dev/null | sort -u
}
alarm() {
  local msg; msg=$(printf '%s' "$1" | tr -d '"\\' | cut -c1-200)
  [ -n "$RCON_PASSWORD" ] && rcon-cli --host "$RCON_HOST" --port "$RCON_PORT" --password "$RCON_PASSWORD" \
    "tellraw @a {\"text\":\"[HiveMind] $msg\",\"color\":\"red\"}" >/dev/null 2>&1 || true
}
prev=$(mktemp); cur=$(mktemp); : > "$prev"
echo "fleet-watch up: polling $HQ_URL every ${POLL}s; alarms to $RCON_HOST:$RCON_PORT"
while true; do
  read_faults > "$cur"
  if ! cmp -s "$prev" "$cur"; then
    comm -13 "$prev" "$cur" | sed "s/^/$(date '+%H:%M:%S') [FAULT] /"
    comm -23 "$prev" "$cur" | sed "s/^/$(date '+%H:%M:%S') [CLEARED] /"
    if [ ! -s "$cur" ] && [ -s "$prev" ]; then echo "$(date '+%H:%M:%S') [ALL CLEAR] no faults reported"; fi
    comm -13 "$prev" "$cur" | grep -E "$ALARM" | while IFS= read -r line; do alarm "$line"; done
    cp "$cur" "$prev"
  fi
  sleep "$POLL"
done
