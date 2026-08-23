#!/bin/zsh
# Give the settlement somewhere to put things.
#
# Until this exists the material economy cannot start at all: a miner fills its inventory, has
# nowhere to deposit, and everything above ground level in the tower depends on materials
# accumulating somewhere. The fleet was surveying happily and accumulating nothing.
#
# STORAGE IS FOUND BY NETWORK, NOT BY POSITION.
#
# StorageMan enumerates inventories through the WIRED modem network -- peripheral.getNames() over the
# cable, not a search of nearby blocks. So a chest on its own is invisible no matter where it sits.
# Each chest needs a wired modem touching it, every modem needs to reach the others, and the chain
# has to reach StorageMan's computer. wired_modem_full is modem and cable in one block, which makes
# the whole thing placeable by command.
#
# The layout is two rows for exactly that reason:
#
#     z=78   C C C C C C C      chests
#     z=77   M M M M M M M      modems: each touches the chest north of it AND its neighbours
#     z=76         [S]          StorageMan, touching the modem at its own x
#
# A single alternating row does not work -- the modems end up separated by chests and never form one
# network. And modem=true matters: a wired modem placed inactive exposes nothing, which looks exactly
# like a chest that is not there.
set -e
cd /Users/macback/Projects/minecraft-create121

rc() { docker compose exec -T mc rcon-cli "$1" 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }

Y=64
CHEST_Z=78
MODEM_Z=77
X_FROM=-480
X_TO=-474

echo "== clearing the bay"
rc "fill $X_FROM $Y $MODEM_Z $X_TO $Y $CHEST_Z minecraft:air" | head -1 | sed 's/^/   /'

echo "== chests"
for x in $(seq $X_FROM $X_TO); do
  rc "setblock $x $Y $CHEST_Z minecraft:chest" >/dev/null
done

echo "== wired modems, active"
for x in $(seq $X_FROM $X_TO); do
  rc "setblock $x $Y $MODEM_Z computercraft:wired_modem_full[modem=true]" >/dev/null
done

echo "== placed $(( X_TO - X_FROM + 1 )) chests and the same number of modems"
