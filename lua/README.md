# In-world Lua does not live here

This directory is intentionally empty of code.

`Bridge.lua` and `Sync.lua` used to live here alongside a hand-written 92-line `PowNet` stub. That
stub declared `SERVER_PROTOCOL = "pownet-server"` while the live MainFrame hosts on
`"PowNet:Server"` — an exact-match rednet string — so this project's Bridge could never have
reached the fleet, and would have failed silently with "no response" forever.

**All in-world Lua lives in `minecraft-create121/pownet/`**, which `bin/pownet-sync.sh` deploys to
`data/world/computercraft/disk/0` — the single floppy MainFrame serves to every module. `Bridge.lua`
and `Sync.lua` are there now, so the Bridge loads the real PowNet by construction and a second copy
cannot drift out of sync.

HiveMind owns `hq/` — the out-of-world service. That is the boundary.

See `.agents/memory/the-live-pownet-system.md`.
