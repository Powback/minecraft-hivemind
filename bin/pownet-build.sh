#!/usr/bin/env bash
# Stand up the PowNet server machines. Idempotent: re-running rebuilds the same ids in place.
# rcon-cli reads a leading "-" as its own flag, so every Minecraft command goes as ONE argument.
r() { rcon-cli "$1"; }
echo "-- clear airspace for flight/docking"
r 'fill -98 83 -54 -80 90 -38 minecraft:air'
echo "-- DockingMan #110 at -91 81 -44 (monitor top: DockingMan.lua wraps it unconditionally)"
r 'setblock -91 81 -44 computercraft:computer_normal replace'
r 'data merge block -91 81 -44 {ComputerId:110,Label:"DockingMan"}'
r 'setblock -91 82 -44 computercraft:monitor_normal replace'
r 'setblock -91 80 -44 computercraft:wireless_modem_normal[facing=up] replace'
echo "-- MapServer #111 at -93 81 -44"
r 'setblock -93 81 -44 computercraft:computer_normal replace'
r 'data merge block -93 81 -44 {ComputerId:111,Label:"MapServer"}'
r 'setblock -93 80 -44 computercraft:wireless_modem_normal[facing=up] replace'
echo "-- TaskMan #112 at -95 81 -44 (monitor on its LEFT; Render() dereferences it)"
# "left" is the viewer's left facing the screen, NOT the computer's own left. Derived from
# MainFrame rather than guessed: #78 faces north and its disk drive -- which it reaches as
# "left" -- sits at +X. So for a north-facing computer, left is +X.
r 'setblock -95 81 -44 computercraft:computer_normal[facing=north] replace'
r 'data merge block -95 81 -44 {ComputerId:112,Label:"TaskMan"}'
r 'setblock -94 81 -44 computercraft:monitor_normal replace'
r 'setblock -95 80 -44 computercraft:wireless_modem_normal[facing=up] replace'
echo "-- power on"
r 'computercraft turn-on 110'
r 'computercraft turn-on 111'
r 'computercraft turn-on 112'
