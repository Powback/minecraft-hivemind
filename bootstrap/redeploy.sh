#!/bin/zsh
# Push the repo into a running world and restart what needs restarting.
#
#   bootstrap/redeploy.sh              -- everything
#   bootstrap/redeploy.sh TaskMan ...  -- just these
#
# MainFrame's disk/ is the fleet's source of truth: PowNet.UpdateModule pulls from it on every boot,
# so a file that is stale there is stale everywhere, one reboot later. But each module also keeps a
# local copy of its own code, and that is what it runs BEFORE it has talked to anyone -- so both have
# to be written or a module comes up on yesterday's code and updates itself into today's only if it
# gets far enough to ask.
#
# Restarts are verified against the dump rather than assumed. `computercraft turn-on` is a silent
# no-op when it lands while the machine is still shutting down, and the failure mode is a module
# that reads as ON while sitting at a shell prompt running nothing.
set -e
cd /Users/macback/Projects/minecraft-create121

REPO=/Users/macback/Projects/HiveMind
WORLD=data/world
IDS=/private/tmp/claude-501/-Users-macback/52e2a9bb-ae40-4df1-bce7-106c98b31824/scratchpad
ALL=(MainFrame DroneMan TaskMan MapServer StorageMan DockingMan Bridge)
TARGETS=(${@:-$ALL})
FAILED=0

rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }

# ASK THE WORLD WHICH COMPUTER IS WHICH.
#
# The ids used to come only from $IDS/id-<name>.txt, written when a module was first placed -- into
# a per-session scratchpad that does not survive the session. When those files went, every target
# printed "no recorded id, skipping" and the script exited 0. A full fleet redeploy that deployed
# NOTHING and reported success: the PowNet heartbeat fix sat in the repo, apparently shipped, while
# the whole fleet kept running the broken copy. That is the worst shape a deploy failure can take.
#
# The world already knows. Each module computer holds its own code -- computer/<id>/DroneMan.lua is
# DroneMan, by construction, and that survives sessions, scratchpad wipes and restored backups.
# Resolve from there, then WRITE THE ANSWER INTO THE REPO so a wiped save directory still has one,
# and refuse to be quiet about a target that resolves to neither.
# Restarts are verified against the dump rather than assumed: `computercraft turn-on` is a silent
# no-op when it lands while the machine is still shutting down, and the failure mode is a module
# that reads as ON while sitting at a shell prompt running nothing.
state() { rc "computercraft dump" | grep -E "^#$1 " | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

cycle() {
  local id=$1 t
  for t in 1 2 3 4; do rc "computercraft shutdown $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "N" ] && break; done
  for t in 1 2 3;    do rc "computercraft turn-on  $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "Y" ] && break; done
}

IDMAP="$REPO/bootstrap/module-ids.txt"

lookup() {
  local n=$1 id d
  for d in "$WORLD"/computercraft/computer/*/; do
    if [ -f "$d$n.lua" ]; then id=$(basename "$d"); break; fi
  done
  [ -z "$id" ] && id=$(awk -v n="$n" '$1==n {print $2}' "$IDMAP" 2>/dev/null)
  [ -z "$id" ] && id=$(cat "$IDS/id-$n.txt" 2>/dev/null || echo "")
  echo "$id"
}

# Remember what we resolved. The scratchpad is per-session; this file is committed.
remember() {
  local n=$1 id=$2
  [ -z "$id" ] && return 0
  touch "$IDMAP"
  grep -v "^$n " "$IDMAP" > "$IDMAP.tmp" 2>/dev/null || true
  echo "$n $id" >> "$IDMAP.tmp"
  sort -o "$IDMAP" "$IDMAP.tmp"; rm -f "$IDMAP.tmp"
}

# MainFrame first, always: it serves everyone else, so pushing modules before it means they update
# themselves from the old copy.
MF=$(lookup MainFrame)
remember MainFrame "$MF"
if [ -n "$MF" ]; then
  cp -R "$REPO"/lua/* "$WORLD/computercraft/computer/$MF/disk/" 2>/dev/null || true
  chmod -R a+rwX "$WORLD/computercraft/computer/$MF/disk"
  echo "  MainFrame disk/ synced ($(ls "$WORLD/computercraft/computer/$MF/disk" | wc -l | tr -d ' ') entries)"
fi

for name in $TARGETS; do
  id=$(lookup $name)
  remember $name "$id"
  # LOUD, NOT SKIPPED. A missing id means this module did not get the code, and a redeploy that
  # quietly omits a module is worse than one that fails -- the fix looks shipped.
  [ -z "$id" ] && { echo "  $name: NO ID -- not in the world dump and no recorded id. NOT DEPLOYED."; FAILED=1; continue; }
  d="$WORLD/computercraft/computer/$id"
  cp "$REPO/lua/PowNet" "$d/PowNet" 2>/dev/null || true
  # The BOOTLOADER too. This copied PowNet and the module but never startup, so every fix to the
  # boot path shipped to MainFrame's disk and reached no module that was already placed -- they run
  # whatever startup they were built with. DockingMan spent a day in a silent connect-retry loop
  # that a bootloader fix would have made legible, and the fix could not reach it.
  cp "$REPO/lua/startup" "$d/startup" 2>/dev/null || true
  [ -f "$REPO/lua/$name.lua" ] && cp "$REPO/lua/$name.lua" "$d/$name.lua"
  [ -d "$REPO/lua/ServerTasks" ] && { rm -rf "$d/ServerTasks"; cp -R "$REPO/lua/ServerTasks" "$d/ServerTasks"; }
  if [ "$name" = "MapServer" ]; then
    cp "$REPO/lua/PowGPSServer.lua" "$d/PowGPSServer" 2>/dev/null || true
    cp "$REPO/lua/MapRender.lua"    "$d/MapRender"    2>/dev/null || true
  fi
  chmod -R a+rwX "$d"
  cycle $id
  echo "  $name #$id on=$(state $id)"
done

if [ -n "$MF" ]; then :; else echo "  MainFrame: NO ID -- disk/ not synced, modules will update from stale code"; FAILED=1; fi
[ "$FAILED" = "1" ] && { echo "REDEPLOY INCOMPLETE -- see NOT DEPLOYED above"; exit 1; }
echo "redeploy ok"
