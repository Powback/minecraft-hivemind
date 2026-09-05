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
ALL=(MainFrame DroneMan TaskMan MapServer StorageMan DockingMan Bridge Drones)
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
# STRIP THE ANSI FIRST. `computercraft dump` colours the On column and emits a reset escape at the
# START of every row, so the piped line is "\e[0m#47   | Y | ...". `grep -E "^#47 "` anchors at the
# escape, never matches, and state() returns empty -- so a running drone reads as OFF and is never
# cycled. That is the "seventeen of twenty on stale code" bug at the top of this file: the fixes were
# deployed to disk and never loaded, and every measurement described yesterday's binary. Strip the
# escapes (perl, always present on macOS; BSD sed will not do \x1b) and match the id as a field.
stripansi() { perl -pe 's/\e\[[0-9;]*m//g'; }
state() { rc "computercraft dump" | stripansi | grep -E "^#$1[[:space:]]" | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }

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
  [ "$name" = "Drones" ] && continue        # handled by deploy_drones below, not a module computer
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

# THE DRONES ARE THE FLEET. DEPLOYING TO THE MODULES IS NOT DEPLOYING.
#
# This script shipped seven module computers and NOT ONE DRONE, and had done since it was written.
# DroneLogic.lua is the file that changes most in this repo -- every job verb, all of movement,
# fuel, deposit and rescue live in it -- and the only way it reached a drone was if something
# happened to reboot that drone afterwards. Nothing in the deploy path does.
#
# Measured immediately after a "successful" redeploy, on a seven-drone fleet:
#
#   drones WITHOUT the fix: cc#20 21 22 47 48 49 50 51 52 53 54 55 56 59 60 61 62
#   drones WITH it:         cc#57 58 63
#
# Seventeen of twenty on stale code. Hours went into "the fix does not work" for fixes that were
# never running, and each one had to be rediscovered from a log written by yesterday's binary. It
# is the most expensive class of failure there is, because every measurement taken to diagnose it
# is describing different code from the code in front of you.
#
# A drone is any computer holding DroneLogic.lua -- ask the world, same as lookup() does for
# modules, so this keeps working across scratchpad wipes and restored saves.
deploy_drones() {
  local d id n=0 cycled=0 stale=0
  # ONE dump for the whole fleet, not one rcon round trip per drive. Twenty `computercraft dump`
  # calls back to back contend on rcon and some come back empty -- another way a running drone reads
  # as OFF and misses its cycle. Snapshot once (ANSI stripped) and read the On column from memory.
  local DRONE_DUMP; DRONE_DUMP=$(rc "computercraft dump" | stripansi)
  on_now() { printf '%s\n' "$DRONE_DUMP" | grep -E "^#$1[[:space:]]" | awk -F'|' '{gsub(/ /,"",$2);print $2}'; }
  for d in "$WORLD"/computercraft/computer/*/; do
    [ -f "$d/DroneLogic.lua" ] || continue
    id=$(basename "$d")
    cp "$REPO/lua/DroneLogic.lua" "$d/DroneLogic.lua"
    cp "$REPO/lua/pgps.lua"       "$d/pgps"    2>/dev/null || true
    cp "$REPO/lua/PowNet"         "$d/PowNet"  2>/dev/null || true
    # DroneBoot.lua, NOT lua/startup. A drone's bootloader is a DIFFERENT PROGRAM from a module's,
    # and copying the module one over it bricked the entire fleet the first time this function ran:
    # the module bootloader derives what to launch from the computer label, so every drone came up
    # trying to loadfile("D40.lua"), failed, rebooted, and did it again -- seven drones powered ON,
    # executing nothing, logs frozen mid-sentence.
    #
    #   boot-stage.txt: stage=entered-startup label=D40
    #   last-run.txt:   module=D40 ok=false err=loadfile: File not found
    #
    # bootstrap/drone.sh has always been the authority on this ("the drone's bootloader IS
    # DroneBoot") and this function was written without reading it.
    cp "$REPO/lua/DroneBoot.lua"  "$d/startup" 2>/dev/null || true
    chmod -R a+rwX "$d"
    n=$((n+1))
    # Only cycle what is actually running. A drone that is off picks the new code up when it boots,
    # and turn-on here would strand it wherever it happens to be sitting.
    if [ "$(on_now $id)" = "Y" ]; then cycle $id; cycled=$((cycled+1)); fi
  done
  # VERIFY AT THE EFFECT, NOT AT THE COPY. A drone that was mid-write, read-only or simply missed
  # must be named -- a redeploy that silently skips one is how this whole class of bug survives.
  for d in "$WORLD"/computercraft/computer/*/; do
    [ -f "$d/DroneLogic.lua" ] || continue
    if ! cmp -s "$REPO/lua/DroneLogic.lua" "$d/DroneLogic.lua"; then
      echo "  drone #$(basename "$d"): STILL STALE after deploy"; stale=$((stale+1)); FAILED=1
    fi
  done
  echo "  Drones: $n written, $cycled cycled, $stale stale"
}

if [[ " ${TARGETS[@]} " == *" Drones "* ]]; then deploy_drones; fi

if [ -n "$MF" ]; then :; else echo "  MainFrame: NO ID -- disk/ not synced, modules will update from stale code"; FAILED=1; fi
[ "$FAILED" = "1" ] && { echo "REDEPLOY INCOMPLETE -- see NOT DEPLOYED above"; exit 1; }
echo "redeploy ok"
