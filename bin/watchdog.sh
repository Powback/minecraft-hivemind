#!/bin/zsh
# STANDING WATCH ON THE FLEET, SO A STALL IS NOTICED IN A MINUTE INSTEAD OF FORTY.
#
# Every stall in this settlement has been found the same way: a human noticing that nothing had
# happened for a while, then reading drone logs by hand. That is how a crafter camped on a chest for
# 42 minutes while the miner carrying its logs failed to land -- both drones "running", neither
# making progress, and nothing in any status field saying so.
#
# "Idle" is not the only failure and is not even the common one. The common one is a drone that is
# nominally BUSY and has not moved, which every status view reports as healthy. So this watches
# POSITION and PROGRESS, not the status word.
#
# Writes one line per anomaly to the report file and stays quiet otherwise, so the file is a list of
# things worth looking at rather than a stream to be waded through.
set -u

STATE_URL=${STATE_URL:-http://hive.pow/map/state}
REPORT=${REPORT:-/tmp/hive-watchdog.log}
EVERY=${EVERY:-60}
STALL_TICKS=${STALL_TICKS:-4}      # ticks unmoved before it counts as stalled
TMP=${TMPDIR:-/tmp}/hive-watchdog.$$

typeset -A last_pos last_n
say() { print -r -- "$(date '+%H:%M:%S') $*" >> "$REPORT" }
trap 'rm -f "$TMP"; exit 0' INT TERM

say "watchdog up (every ${EVERY}s, stall after $((EVERY*STALL_TICKS))s unmoved)"

while true; do
  raw=$(curl -s --max-time 10 "$STATE_URL" 2>/dev/null)
  if [[ -z "$raw" ]]; then
    say "ALERT hq unreachable at $STATE_URL"
    sleep "$EVERY"; continue
  fi

  # Flatten to one line per drone. Written to a FILE, not piped into the loop: in zsh the last
  # element of a pipeline runs in a subshell, so a `| while read` would update the position arrays
  # in a child that exits every tick -- they would reset each time and nothing would ever look
  # stalled. A watchdog that silently never fires is worse than no watchdog, because it is also a
  # reason to stop checking by hand.
  print -r -- "$raw" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception as e: print("PARSE_ERROR|%s|-|-|0|0" % e); raise SystemExit
if not d.get("bridge",{}).get("connected"): print("BRIDGE_DOWN|-|-|-|0|0")
for x in (d.get("fleet",{}).get("data",{}) or {}).get("drones",[]):
    p=x.get("pos") or {}
    car=sum((x.get("carrying") or {}).values())
    print("%s|%s|%s|%s,%s,%s|%d|%d" % (x.get("name"),x.get("status"),
        (x.get("detail") or "-"),p.get("x"),p.get("y"),p.get("z"),car,
        int(x.get("silentMs") or 0)/1000))
' > "$TMP" 2>/dev/null

  while IFS='|' read -r name st detail pos carry silent; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "BRIDGE_DOWN" ]]; then say "ALERT bridge is down"; continue; fi
    if [[ "$name" == "PARSE_ERROR" ]]; then say "ALERT cannot parse state: $st"; continue; fi

    if [[ "${last_pos[$name]:-}" == "$pos" ]]; then
      last_n[$name]=$(( ${last_n[$name]:-0} + 1 ))
    else
      last_n[$name]=0
    fi
    last_pos[$name]="$pos"
    n=${last_n[$name]}

    # The failure that hides: status says working, the drone has not moved in minutes.
    if (( n == STALL_TICKS )); then
      say "STALL $name unmoved at $pos for $((n*EVERY))s -- status=$st detail=$detail carrying=$carry"
    elif (( n > STALL_TICKS && n % (STALL_TICKS*5) == 0 )); then
      say "STALL $name still stuck at $pos for $((n*EVERY))s -- $detail"
    fi
    # Idle is still worth knowing: idle means the settlement is not expanding.
    if [[ "$st" == "idle" ]] && (( n >= 2 )); then
      say "IDLE $name idle and stationary for $((n*EVERY))s -- $detail"
    fi
    # Cargo inside a drone is invisible to every planning decision.
    if (( carry > 0 && n >= STALL_TICKS )); then
      say "CARGO $name holding $carry item(s) while stalled at $pos"
    fi
    (( silent > 120 )) && say "SILENT $name has not reported for ${silent}s"
  done < "$TMP"

  sleep "$EVERY"
done
