#!/usr/bin/env sh
# fleet-watch — emit a line whenever the settlement's fault list CHANGES.
#
# WHY CHANGE AND NOT STATE. A monitor that re-reports a standing condition every cycle trains you to
# ignore it, and then the one new line that mattered arrives in the middle of forty identical ones.
# The settlement spent an evening emitting "FUEL TRAP" every ninety seconds while nothing acted on
# it. So this prints only transitions: a fault appearing, a fault clearing, all clear.
#
# The detection itself lives in HQ (`fleetFaults` in hq/src/tools/core.ts, unit-tested in
# hq/test/fleet-faults.test.ts) -- not in this script. A shell one-liner cannot be tested and cannot
# be reasoned about later; this file only diffs what HQ already knows.
#
# SILENCE IS NOT SUCCESS. If HQ or the bridge is down, that is itself an event and is reported --
# a watcher that goes quiet when its subject dies is worse than no watcher.
#
#   sh bin/fleet-watch.sh          # poll every 60s, print transitions
#   POLL=30 sh bin/fleet-watch.sh  # faster
set -u
POLL="${POLL:-60}"
HQ="${HQ:-hive-hq}"

read_faults() {
  docker exec "$HQ" node -e "
    fetch('http://localhost:4400/brief')
      .then(r => r.json())
      .then(b => {
        const p = (b.problems || []).filter(x => String(x) !== 'none');
        if (!b.fleet || b.fleet.total === 0) { console.log('HQ SEES NO FLEET (bridge down, or DroneMan not answering)'); return; }
        for (const x of p) console.log(
          // Exact fuel figures change every poll and would churn the diff without telling you
          // anything -- 'low on fuel (25)' and 'low on fuel (18)' are the same fault.
          String(x).replace(/\s+/g, ' ').replace(/\((\d+)\)/g, '(n)')
          // The spiral's count rises as it worsens, which would churn a clear+fault pair on
          // every drone lost. Escalation is real but does not change what you do about it --
          // and FUEL TRAP is a separate fault for the case that does.
          .replace(/\b\d+ of (\d+) drones are dry/, 'n of \$1 drones are dry').slice(0, 200));
      })
      .catch(e => console.log('HQ UNREACHABLE: ' + e.message));
  " 2>/dev/null | sort -u
}

TMP="${TMPDIR:-/tmp}/fleet-watch.$$"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
: > "$TMP/prev"

while true; do
  read_faults > "$TMP/cur"
  # An empty read means the container is gone -- distinguish that from a genuinely clean fleet.
  if [ ! -s "$TMP/cur" ] && ! docker inspect -f '{{.State.Running}}' "$HQ" 2>/dev/null | grep -q true; then
    echo "HQ CONTAINER NOT RUNNING" > "$TMP/cur"
  fi

  if ! cmp -s "$TMP/prev" "$TMP/cur"; then
    comm -13 "$TMP/prev" "$TMP/cur" | sed 's/^/[FAULT] /'
    comm -23 "$TMP/prev" "$TMP/cur" | sed 's/^/[CLEARED] /'
    if [ ! -s "$TMP/cur" ] && [ -s "$TMP/prev" ]; then echo "[ALL CLEAR] no faults reported"; fi
    cp "$TMP/cur" "$TMP/prev"
  fi
  sleep "$POLL"
done
