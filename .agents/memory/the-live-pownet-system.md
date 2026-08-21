# The live PowNet system — read this before touching anything in-world

Written 2026-08-21, after HiveMind and the PowNet work ran for days without either knowing about
the other. Everything here was verified against the running world, not inferred from SPEC.md.

## The one thing that went wrong

HiveMind hand-wrote its own `lua/PowNet` — 92 lines providing "the 8 symbols Bridge and Sync need".
The real PowNet is 385 lines. The stub declared:

```lua
PowNet.SERVER_PROTOCOL = "pownet-server"
PowNet.DRONE_PROTOCOL  = "pownet-drone"
```

The live system uses:

```lua
SERVER_PROTOCOL = "PowNet:Server"
DRONE_PROTOCOL  = "PowNet:Drone"
```

`rednet` protocols are exact-match strings. MainFrame hosts on `PowNet:Server`, so
`rednet.lookup("pownet-server", "MAINFRAME")` returns **nil, silently, forever**. Every Bridge call
would have failed with "no response" and nothing would have said why.

**Bridge.lua itself was correct.** `PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, key, data)` and
`sendAndWaitForResponse(module, msg, PROTOCOL)` both match the real API exactly — passing a module
*name* as the recipient is right, and `TaskMan.lua:92` does the same. The code was fine; it was
loading a wrong PowNet.

Both stub copies (`lua/PowNet`, `.agents/PowNet`) are deleted. Do not recreate them.

## The rule that prevents it happening again

**In-world Lua lives in exactly one place: `minecraft-create121/pownet/`.**
**HiveMind owns out-of-world only: `hq/`.**

`pownet/` is the tracked source; `bin/pownet-sync.sh` rsyncs it to
`minecraft-create121/data/world/computercraft/disk/0` — the floppy. These are two separate
directories, not one path with two names. MainFrame runs with `shell.setDir("disk")` and serves
those files to every module, so **editing the floppy IS deploying**.

`Bridge.lua` and `Sync.lua` now live on that floppy. They are no longer in `HiveMind/lua/`. Bridge
therefore gets the real PowNet automatically and a divergent copy is structurally impossible.

There is exactly **one disk in the world** (`disk/0`). If you find yourself creating a second one,
stop.

## What is actually running

Substrate: Minecraft 1.21.1 NeoForge, CC:T, Advanced Peripherals, Create + Sable, AE2.

Architecture — **the label IS the module.** A computer labelled `DroneMan` boots, fetches
`DroneMan.lua` from MainFrame and becomes DroneMan. Nothing else selects a role. To make `#78` the
Bridge, label it `Bridge`.

Live modules: `MainFrame` (VFS + serves module source), `DroneMan`, `DockingMan`, `MapServer`,
`TaskMan`, `StorageMan`.

Proven working end-to-end, not theoretical:

- Drone registration, idempotent, self-healing (a retry used to create duplicate drones).
- Docking and dock refuelling.
- The full **mine → haul → deposit → index** loop: 21 sand mined, delivered, and detected by
  StorageMan over the wired network.
- Survey → geoscan → upload → merge (the map grew 27,470 → 34,801 bytes).
- Role-aware dispatch (`survey-north` went to the scout, miners untouched).
- GPS constellation, chunk-loader auto-detection, resume-across-update.

Roles are derived from hardware, not configured: a `geoscanner_turtle` is a `scout`, a peripheral
of type `chunky` is a `loader`, otherwise `miner`.

## Not done — do not assume these work

- **Smelting is written but has never once run.** No furnace has ever been placed.
  `StorageMan.ServiceFurnaces()` is wired into a 10s tick and is real code, but untested. It also
  has a known bug: `isSmeltable` uses loose substring matching, so `"sand"` matches `soul_sand`
  and `"cobblestone"` matches `cobblestone_stairs`. Neither smelts, and because input is only
  reloaded when slot 1 is empty, one non-smeltable item **jams that furnace permanently**.
- **Crafting and factories are design-only.** Discussed, nothing built.
- **`Haul` as a separate role is untested** — hauling currently happens inside the dig job.
- **Computers #120 and #123 refused to power on** and the cause was never found. They were rebuilt
  around, so whatever it was is still there.

## The callable surface HQ tools must mirror

This is the real registry, read from the live modules:

| module     | callables |
|------------|-----------|
| DroneMan   | `Heartbeat` `RegisterDrone` `RestartDrones` `DockDrones` `Distress` `ListStuck` `RescueDrones` `Escort` `GetDrones` `SurveyDrones` `GoTo` |
| MapServer  | `SaveWorld` `LoadWorld` `GetPath` `UpdatePath` `SetDronePos` `MapMode` `GetBounds` `AddGpsHost` `SetBounds` `MapFollow` `MapInfo` |
| TaskMan    | `Abort` `AddTask` `StartTask` `PauseTask` `AbortTask` `GetTasks` `ListFleet` |
| DockingMan | `AllocateDocking` `ListDockingTowers` `DelDockingTower` `AddDockingTower` `EditDockingTower` `GetDroneInfo` |
| StorageMan | `Find` `Stock` `DepositPoint` `AddDeposit` `Smelt` |

In Lua these are `On<Name>` functions; over the wire the `key` is the name without `On`.

HQ's existing abstract tools (`hive.brief`, `fleet.status`, `world.query`, `order.issue`,
`order.abort`, `recover.dispatch`) hardcode none of these, which is why ~1,500 lines of `hq/`
survived this intact and only the Lua stub had to go.

## Traps that cost real hours — the full list is in minecraft-create121/.agents/memory/computercraft.md

- **A PowNet change needs TWO reboots.** The bootloader does `os.loadAPI("PowNet")` *before*
  `PowNet.UpdateModule("PowNet")`, so the first reboot only downloads the new API and the second
  loads it. A module that pulls its own new `.lua` while still running the old PowNet dies on
  `attempt to call field 'MarkDirty' (a nil value)` with `MarkDirty` plainly present in the file.
- **Labels and turtle upgrades are RUNTIME state.** `data merge` on a running computer appears to
  work and is silently undone — CC:T writes the live object back over block NBT on shutdown. Stop
  the computer, edit, start it.
- **`rcon-cli` eats negative coordinates as flags.** Quote the whole command as one argument.
- **Two bootloaders.** `disk/startup` is the MODULE bootloader and refuses to act without a label.
  `DroneBoot.lua` is the DRONE bootloader and never reads the label — drones must use it, because
  `DroneLogic.Init()` only registers when the label is nil. Label a drone up front and it never
  registers *while still sending heartbeats*.
- **`os.loadAPI` executes the chunk**, so top-level code in a "library" runs on load.
- **`parallel.waitForAny` ends when ANY branch returns** — a tick loop must never return.
- **"left" is the viewer's left**, not the computer's. For a north-facing computer, left is `+X`.

## Registration chain — every link is required

    drone → DroneMan.RegisterDrone → DockingMan.AllocateDocking → MapServer.SetDronePos

`RegisterDrone` returns `false, "Failed to get docking"` if DockingMan does not answer, so **no
drone can register until DockingMan is up**. That alone kept the registry empty once.

## Two deployment paths, one source

`minecraft-create121/pownet/` is the source. It reaches the world two ways, and both are valid:

1. **`bin/pownet-sync.sh`** — rsyncs `pownet/` to `data/world/computercraft/disk/0`. Fast, but only
   works with host filesystem access to the world directory.
2. **HQ publishes it over HTTP** — `hq/docker-compose.yml` mounts that same directory read-only at
   `/lua`, and serves `/lua/manifest` (hash-diffed) and `/lua/file/:path`. `Sync.lua`, running
   in-world, pulls changed files onto MainFrame's disk, which then serves them to drones via
   `PowNet UPDATE`. This works with no host access at all, which is the point.

HQ's mount deliberately points OUTSIDE this repo, at `../../minecraft-create121/pownet`. HiveMind
used to publish its own `lua/` copy, which is exactly how the stub happened. Override with
`HIVE_LUA_DIR` if the checkout moves.

Verified 2026-08-21: `GET /lua/manifest` returns 30 files and `/lua/file/PowNet` serves the real
385-line API with `SERVER_PROTOCOL = "PowNet:Server"`.

## What HiveMind still needs to do

1. Label `#78` `Bridge` so the module bootloader turns it into the Bridge. It will fetch
   `Bridge.lua` and the real PowNet from MainFrame. Not done yet — it activates the integration and
   should happen with HQ running so the WS side has something to talk to.
2. Point HQ's tool layer at the real callables above.
3. Run the SPEC §9 Sable carrier probes (Phase 0), which are still ungated.
