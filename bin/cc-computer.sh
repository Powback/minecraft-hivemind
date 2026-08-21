#!/usr/bin/env sh
# cc-computer — create, list and remove ComputerCraft computers from the server console.
#
# Runs INSIDE the mc container (it needs `rcon-cli` and the world directory). From an agent:
#
#   project_exec(service="mc", command="/opt/mc-tools/cc-computer.sh list")
#   project_exec(service="mc", command="/opt/mc-tools/cc-computer.sh ensure -85 81 -44 hivemind-1")
#
# WHY THIS EXISTS
#
# Placing a working, labelled, persistent computer takes four steps in a specific order, and
# getting the order wrong looks like the mod being broken rather than the sequence being wrong.
# Working it out cost an hour and left a stray probe computer in the world. Encoded here so the
# next person runs one command instead of rediscovering it — see .agents/memory/computercraft.md
# for the full write-up including the dead ends.
#
# `ensure` is IDEMPOTENT on position. Run it twice and you get the same computer back, not a
# second one. That is the whole point: the discovery process produced computer #77 because every
# attempt made a new one.
set -eu

RCON="rcon-cli"
WORLD="${WORLD_DIR:-/data/world}"
STORE="$WORLD/computercraft/computer"

# ONE argument, always — `"$*"`, not `"$@"`.
#
# Minecraft coordinates are negative here, and `rcon-cli data merge block -85 81 -44 {...}` makes
# rcon-cli read `-85` as one of ITS OWN flags. The command never reaches the server. It fails
# quietly, so the script reported "assigning id 78" while the block stayed untouched, and the
# next run saw no ComputerId and created another one — the exact duplicate-spawning this tool
# exists to prevent, reintroduced by its own quoting.
#
# Joining into a single string is what a hand-typed `rcon-cli 'data merge block -85 ...'` does,
# which is why it worked by hand and not in here.
#
# Also strips rcon-cli's leading length byte and colour codes so the output is parseable.
rc() { $RCON "$*" 2>/dev/null | tr -d '\000-\010\013\014\016-\037' | sed 's/\[0m//g'; }

usage() {
  cat <<'EOF'
usage:
  cc-computer.sh list
  cc-computer.sh ensure <x> <y> <z> <label> [startup-file]
  cc-computer.sh modem <x> <y> <z> <toward-x> <toward-y> <toward-z>
  cc-computer.sh drive <x> <y> <z> [computer-id-to-reboot]
  cc-computer.sh turtle <x> <y> <z> <label> [--wireless] [--tool <item>] [--fuel <n>] [startup-file]
  cc-computer.sh remove <id> [--purge]

  list    every computer the server knows about, plus every id with saved files on disk
  ensure  make sure a labelled, running computer exists at <x> <y> <z>. Idempotent on position:
          if one is already there it is relabelled if needed, turned on, and reported — never
          duplicated. Optional startup-file is copied in as startup.lua.
  modem   place a wireless modem at <x y z> FACING the block at <toward-x y z>. Facing is the
          whole trick: a modem that does not face its computer is not attached to it, and the
          computer simply reports no peripherals.
  drive   place a disk drive with a floppy in it, so an adjacent computer gets a /disk mount.
          Pass the computer's id to reboot it — a computer only picks up a drive at BOOT, and
          until it does, writes to /disk go to a local directory that silently shadows the mount.
  turtle  place and label a turtle. --wireless adds a wireless modem upgrade, --tool adds a tool
          upgrade (default minecraft:diamond_pickaxe, i.e. a mining turtle), --fuel sets fuel
          (default 2000; a turtle with no fuel cannot move).
  remove  shut it down and clear the block. --purge also deletes its saved files.
EOF
}

# Ids already taken. The registry only lists computers currently LOADED, so a computer in an
# unloaded chunk would be invisible and its id handed out twice — the saved directories are the
# durable record, so both are consulted.
used_ids() {
  rc computercraft dump | sed -n 's/^#\([0-9][0-9]*\).*/\1/p'
  [ -d "$STORE" ] && ls -1 "$STORE" 2>/dev/null | grep -E '^[0-9]+$' || true
}

next_id() {
  max=$(used_ids | sort -n | tail -1)
  echo $(( ${max:-0} + 1 ))
}

# The ComputerId at a position, or empty if there is no computer there.
id_at() {
  rc data get block "$1" "$2" "$3" 2>/dev/null | sed -n 's/.*ComputerId: \([0-9][0-9]*\).*/\1/p'
}

block_at() {
  rc data get block "$1" "$2" "$3" 2>/dev/null | sed -n 's/.*id: "\([^"]*\)".*/\1/p'
}

cmd_list() {
  echo "── computers the server has loaded"
  rc computercraft dump
  echo "── ids with saved files in $STORE"
  if [ -d "$STORE" ]; then
    for d in "$STORE"/*; do
      [ -d "$d" ] || continue
      printf '  #%s  %s file(s)\n' "$(basename "$d")" "$(ls -1 "$d" | wc -l | tr -d ' ')"
    done
  else
    echo "  (none yet — a computer's directory appears only once it WRITES something)"
  fi
}

cmd_ensure() {
  x=$1; y=$2; z=$3; label=$4; startup=${5:-}

  existing=$(id_at "$x" "$y" "$z")
  if [ -n "$existing" ]; then
    echo "── computer #$existing already at $x $y $z — reusing it, not making another"
    id=$existing
    # Relabel only if it differs, so re-running is genuinely a no-op.
    cur=$(rc data get block "$x" "$y" "$z" | sed -n 's/.*Label: "\([^"]*\)".*/\1/p')
    if [ "$cur" != "$label" ]; then
      echo "── relabelling '${cur:-<none>}' -> '$label'"
      rc data merge block "$x" "$y" "$z" "{Label:\"$label\"}" >/dev/null
    fi
  else
    blk=$(block_at "$x" "$y" "$z")
    case "$blk" in
      computercraft:computer*)
        # A computer block with no ComputerId: placed, but never made into a computer. This is
        # exactly the state that looks like "the mod is broken" — the NBT write below is what
        # actually creates it.
        echo "── unconfigured computer block at $x $y $z — giving it an id" ;;
      ""|minecraft:air)
        echo "── placing a computer at $x $y $z"
        rc setblock "$x" "$y" "$z" computercraft:computer_normal >/dev/null ;;
      *)
        echo "!! $x $y $z holds '$blk' — refusing to overwrite something that is not air." >&2
        echo "   Pick another position, or clear it deliberately." >&2
        return 1 ;;
    esac
    id=$(next_id)
    # THE STEP THAT MATTERS. A freshly placed block has no ComputerId, so `computercraft turn-on`
    # cannot address it and `dump` does not list it. This write is what brings the computer into
    # existence — and the label goes in the same write because an unlabelled computer's
    # filesystem is discarded, so it would never persist.
    echo "── assigning id $id and label '$label'"
    rc data merge block "$x" "$y" "$z" "{ComputerId:$id,Label:\"$label\"}" >/dev/null
    # VERIFY, do not assume. This write failing quietly is what made the tool claim success while
    # doing nothing — and a create tool that lies about creating is worse than no tool.
    got=$(id_at "$x" "$y" "$z")
    if [ "$got" != "$id" ]; then
      echo "!! the NBT write did not take: expected ComputerId $id, block reports '${got:-<none>}'." >&2
      echo "   The computer was NOT created. Nothing was left half-done — the block is still there" >&2
      echo "   with no id, so re-running this command is safe." >&2
      return 1
    fi
  fi

  if [ -n "$startup" ]; then
    [ -f "$startup" ] || { echo "!! no such startup file: $startup" >&2; return 1; }
    mkdir -p "$STORE/$id"
    cp "$startup" "$STORE/$id/startup.lua"
    echo "── installed $(basename "$startup") as startup.lua"
  fi

  rc computercraft turn-on "$id" >/dev/null || true
  # A reboot is what makes it pick up a startup.lua that was just written.
  [ -n "$startup" ] && { rc computercraft shutdown "$id" >/dev/null || true; rc computercraft turn-on "$id" >/dev/null || true; }

  echo "── result"
  rc computercraft dump "$id" || rc computercraft dump
  echo "   files: $STORE/$id  $( [ -d "$STORE/$id" ] && echo "(exists)" || echo "(appears once it writes something)" )"
}

# Which way must a block at (x,y,z) face to point at (tx,ty,tz)?
#
# Minecraft's facing names, not coordinates: +x is east, -x west, +z south, -z north. Getting this
# wrong is silent — the modem places fine and the computer just reports no peripherals, which
# reads as the modem being broken rather than aimed wrong.
facing_toward() {
  dx=$(( $4 - $1 )); dy=$(( $5 - $2 )); dz=$(( $6 - $3 ))
  if   [ "$dx" -gt 0 ]; then echo east
  elif [ "$dx" -lt 0 ]; then echo west
  elif [ "$dz" -gt 0 ]; then echo south
  elif [ "$dz" -lt 0 ]; then echo north
  elif [ "$dy" -gt 0 ]; then echo up
  elif [ "$dy" -lt 0 ]; then echo down
  else echo "!! a block cannot face itself" >&2; return 1
  fi
}

cmd_modem() {
  x=$1; y=$2; z=$3
  f=$(facing_toward "$1" "$2" "$3" "$4" "$5" "$6") || return 1
  echo "── placing a wireless modem at $x $y $z facing $f (toward $4 $5 $6)"
  # `replace` so re-running fixes a wrongly-faced modem instead of leaving it.
  rc setblock "$x" "$y" "$z" "computercraft:wireless_modem_normal[facing=$f]" replace >/dev/null
  echo "   reboot the computer it serves for it to appear: cc-computer.sh ensure ... , or"
  echo "   rcon-cli 'computercraft shutdown <id>' then turn-on <id>"
}

cmd_drive() {
  x=$1; y=$2; z=$3; cid=${4:-}
  blk=$(block_at "$x" "$y" "$z")
  case "$blk" in
    computercraft:disk_drive) echo "── a drive is already at $x $y $z" ;;
    ""|minecraft:air) echo "── placing a disk drive at $x $y $z"
                      rc setblock "$x" "$y" "$z" computercraft:disk_drive >/dev/null ;;
    *) echo "!! $x $y $z holds '$blk' — refusing to overwrite it." >&2; return 1 ;;
  esac

  # A drive with no floppy mounts nothing. `item replace` puts one in slot 0; re-running is
  # harmless but would swap in a BLANK disk, losing whatever the old one held — so only insert
  # when the drive is empty.
  if rc data get block "$x" "$y" "$z" | grep -q "computercraft:disk"; then
    echo "── it already holds a disk — leaving it alone rather than swapping in a blank one"
  else
    echo "── inserting a floppy"
    rc item replace block "$x" "$y" "$z" container.0 with computercraft:disk >/dev/null
  fi

  # THE STEP THAT IS EASY TO MISS. A computer attaches peripherals at BOOT. Until it reboots the
  # drive is invisible, and — worse — `fs.open("/disk/x","w")` succeeds anyway by creating a plain
  # local directory called `disk`, which then SHADOWS the real mount when it does appear. It looks
  # like it worked, and the files are in the wrong place.
  if [ -n "$cid" ]; then
    echo "── rebooting computer #$cid so it attaches the drive"
    rc computercraft shutdown "$cid" >/dev/null || true
    sleep 3
    rc computercraft turn-on "$cid" >/dev/null || true
    echo "   verify with: rcon-cli \"computercraft dump $cid\" (expect a `drive` peripheral)"
  else
    echo "!! no computer id given — nothing will see this drive until its computer is rebooted."
  fi
  echo "   disk contents live on the host at $WORLD/computercraft/disk/<diskID>/"
}

cmd_turtle() {
  x=$1; y=$2; z=$3; label=$4; shift 4
  wireless=""; tool="minecraft:diamond_pickaxe"; fuel=2000; startup=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wireless) wireless=1; shift ;;
      --tool) tool=$2; shift 2 ;;
      --fuel) fuel=$2; shift 2 ;;
      *) startup=$1; shift ;;
    esac
  done

  existing=$(id_at "$x" "$y" "$z")
  if [ -n "$existing" ]; then
    echo "── turtle #$existing already at $x $y $z — reusing it"
    id=$existing
  else
    blk=$(block_at "$x" "$y" "$z")
    case "$blk" in
      computercraft:turtle*) echo "── unconfigured turtle at $x $y $z — giving it an id" ;;
      ""|minecraft:air) echo "── placing a turtle at $x $y $z"
                        rc setblock "$x" "$y" "$z" computercraft:turtle_normal >/dev/null ;;
      *) echo "!! $x $y $z holds '$blk' — refusing to overwrite it." >&2; return 1 ;;
    esac
    id=$(next_id)
    # Everything in ONE merge. A turtle is a computer, so the id and label do the same job as on
    # one — and the upgrades and fuel ride along because a turtle with no fuel cannot move and a
    # turtle with no tool cannot dig, which are the two ways a "working" turtle turns out not to be.
    nbt="{ComputerId:$id,Label:\"$label\",Fuel:$fuel"
    [ -n "$tool" ]     && nbt="$nbt,LeftUpgrade:\"$tool\""
    [ -n "$wireless" ] && nbt="$nbt,RightUpgrade:\"computercraft:wireless_modem_normal\""
    nbt="$nbt}"
    echo "── id $id, label '$label', fuel $fuel${tool:+, tool $tool}${wireless:+, wireless}"
    rc data merge block "$x" "$y" "$z" "$nbt" >/dev/null
    got=$(id_at "$x" "$y" "$z")
    if [ "$got" != "$id" ]; then
      echo "!! the NBT write did not take (block reports '${got:-<none>}') — turtle NOT created." >&2
      return 1
    fi
  fi

  if [ -n "$startup" ]; then
    [ -f "$startup" ] || { echo "!! no such startup file: $startup" >&2; return 1; }
    mkdir -p "$STORE/$id"; cp "$startup" "$STORE/$id/startup.lua"
    echo "── installed $(basename "$startup") as startup.lua"
    rc computercraft shutdown "$id" >/dev/null || true
  fi
  rc computercraft turn-on "$id" >/dev/null || true
  echo "── result"; rc computercraft dump "$id" || true
}

cmd_remove() {
  id=$1; purge=${2:-}
  rc computercraft shutdown "$id" >/dev/null || true
  # Position comes from the registry, so this cannot clear the wrong block from a stale guess.
  pos=$(rc computercraft dump | sed -n "s/^#$id  *| *[YN] *| *//p" | tr -d ' ')
  if [ -n "$pos" ]; then
    x=$(echo "$pos" | cut -d, -f1); y=$(echo "$pos" | cut -d, -f2); z=$(echo "$pos" | cut -d, -f3)
    echo "── clearing the block at $x $y $z"
    rc setblock "$x" "$y" "$z" minecraft:air >/dev/null
  else
    echo "── #$id is not loaded, so its block was left alone (only its files are addressable)"
  fi
  if [ "$purge" = "--purge" ] && [ -d "$STORE/$id" ]; then
    rm -rf "$STORE/$id"
    echo "── deleted $STORE/$id"
  fi
}

case "${1:-}" in
  list)   cmd_list ;;
  ensure) shift; [ $# -ge 4 ] || { usage; exit 2; }; cmd_ensure "$@" ;;
  modem)  shift; [ $# -ge 6 ] || { usage; exit 2; }; cmd_modem "$@" ;;
  turtle) shift; [ $# -ge 4 ] || { usage; exit 2; }; cmd_turtle "$@" ;;
  drive)  shift; [ $# -ge 3 ] || { usage; exit 2; }; cmd_drive "$@" ;;
  remove) shift; [ $# -ge 1 ] || { usage; exit 2; }; cmd_remove "$@" ;;
  *)      usage; exit 2 ;;
esac
