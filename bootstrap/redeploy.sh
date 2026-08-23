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

rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
state() { rc "computercraft dump" | grep -E "^#$1 " | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

cycle() {
  local id=$1 t
  for t in 1 2 3 4; do rc "computercraft shutdown $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "N" ] && break; done
  for t in 1 2 3;    do rc "computercraft turn-on  $id" >/dev/null 2>&1; sleep 4; [ "$(state $id)" = "Y" ] && break; done
}

# MainFrame first, always: it serves everyone else, so pushing modules before it means they update
# themselves from the old copy.
MF=$(cat "$IDS/id-MainFrame.txt" 2>/dev/null || echo "")
if [ -n "$MF" ]; then
  cp -R "$REPO"/lua/* "$WORLD/computercraft/computer/$MF/disk/" 2>/dev/null || true
  chmod -R a+rwX "$WORLD/computercraft/computer/$MF/disk"
  echo "  MainFrame disk/ synced ($(ls "$WORLD/computercraft/computer/$MF/disk" | wc -l | tr -d ' ') entries)"
fi

for name in $TARGETS; do
  id=$(cat "$IDS/id-$name.txt" 2>/dev/null || echo "")
  [ -z "$id" ] && { echo "  $name: no recorded id, skipping"; continue; }
  d="$WORLD/computercraft/computer/$id"
  cp "$REPO/lua/PowNet" "$d/PowNet" 2>/dev/null || true
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
