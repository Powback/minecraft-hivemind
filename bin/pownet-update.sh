#!/usr/bin/env bash
# Push the tracked source to the floppy and take the whole fleet to it.
#
# Not rcon reboots. Those raced: `computercraft turn-on` right after `shutdown` can land while the
# machine is still going down, the module quietly keeps running its old copy, and it still reports
# healthy -- which is exactly how TaskMan sat on a ten-minute-old TaskMan.lua while claiming to run.
#
# This asks the fleet to stand down instead. Each module runs its shutdown hook (a drone flushes
# unsent observations and records the job it was on), the bootloader writes its DATA back, and the
# reboot pulls the new source. Then they resume.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
bash "$REPO/bin/pownet-sync.sh" || exit 1
echo "── asking the fleet to reload"
rcon-cli 'computercraft shutdown 78' >/dev/null 2>&1 || true
sleep 4
rcon-cli 'computercraft turn-on 78'  >/dev/null 2>&1 || true
cat <<'NOTE'
── MainFrame restarting; its boot broadcast is what stands the fleet down.
   Verify rather than assume -- compare mtimes, an old copy still reports healthy:
     stat -f '%Sm %N' -t '%H:%M:%S' data/world/computercraft/computer/*/‹Module›.lua
NOTE
