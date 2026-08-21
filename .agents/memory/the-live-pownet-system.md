# The live system — read this before touching anything in-world

Written 2026-08-21 and verified against the running world, not inferred from SPEC.md. HiveMind and
the PowNet fleet were built in parallel for days without either knowing about the other; this is the
reconciliation.

## Repo layout — this changed on 2026-08-21

**This repo owns the whole application, in-world and out.**

| path | what |
|---|---|
| `lua/` | **all in-world Lua** — PowNet, MainFrame, the modules, Bridge, Sync. The single source of truth. |
| `bin/` | fleet tooling — `pownet-sync.sh`, `pownet-drone.sh`, `cc-computer.sh`, ... |
| `hq/` | the out-of-world service (`hive-hq`, `hive.pow`) |
| `.agents/memory/computercraft.md` | the accumulated game-interaction knowledge. **Read it.** |

`~/Projects/minecraft-create121` is the **Minecraft server** — modpack, world, mods — and nothing
else. The drone fleet is an application that runs inside it, so it lives here. The server can be
rebuilt or replaced without touching the fleet.

It did not used to be this way: the Lua lived in the server repo and HiveMind kept its own second
copy. That second copy is how this project came to ship a hand-written 92-line `PowNet` stub
declaring `SERVER_PROTOCOL = "pownet-server"` while the live MainFrame hosts on `"PowNet:Server"`.
`rednet` protocols are exact-match strings, so its Bridge could never have found MainFrame —
`rednet.lookup` returns nil, silently, forever, and every call would have come back "no response"
with nothing to say why. **Never create a second copy of this tree.**

`Bridge.lua` was never the problem. Its `newMessage(MESSAGE_TYPE.CALL, key, data)` and
`sendAndWaitForResponse(module, msg, PROTOCOL)` match the real API exactly, and passing a module
*name* as recipient is right — `TaskMan.lua:92` does the same.

## The fleet, as of 2026-08-21

Verified with `computercraft dump`. All 16 computers powered on, all five modules reporting
`ok=true err=nil`.

| id | label | role |
|---|---|---|
| `#78` | `MainFrame` | VFS, serves module source to everything |
| `#90` | `relay` | COMMAND computer — the only kind that receives `computercraft queue` |
| `#91` | `DroneMan` | registry, heartbeats, distress, rescue |
| `#92` | `probe` | scratch/testing |
| `#110` | `DockingMan` | docking slots, refuelling |
| `#111` | `MapServer` | world model, paths, bounds, GPS hosts (+ MapRender, PowGPSServer) |
| `#112` | `TaskMan` | task queue and dispatch |
| `#113` | `StorageMan` | network inventory index, deposit, smelting |
| `#100`–`#103` | `gps-100`…`gps-103` | GPS constellation |
| `#120`–`#123` | `D4`, `D1`, `D2`, `D3` | drones |

### `#78` is MainFrame. Do NOT label it `Bridge`.

`computercraft.md` still described `#78` as "hivemind-1, the Bridge computer" — that is **stale and
dangerous**. `#78` was repurposed as MainFrame. Labelling it `Bridge` would destroy the module that
serves source to the entire fleet and take everything down.

**There is currently no Bridge computer.** One has to be placed. Use `bin/cc-computer.sh`, give it a
wireless modem, and label it `Bridge` — the label IS the module, so it will fetch `Bridge.lua` and
the real PowNet from MainFrame on boot.

## Deploying — two paths, one source, both verified working

`lua/` is the source. It reaches the world two ways:

1. **`bin/pownet-sync.sh`** — rsyncs `lua/` onto the floppy at
   `<world>/computercraft/disk/0`. MainFrame runs with `shell.setDir("disk")` and serves those
   files, so **writing the floppy IS deploying**. Needs filesystem access to the world; set
   `WORLD=/path/to/world` if the server checkout is not beside this repo.
2. **HQ over HTTP** — `hq/` mounts `lua/` read-only at `/lua` and serves `/lua/manifest`
   (hash-diffed) and `/lua/file/:path`. `Sync.lua` runs in-world and pulls changed files onto
   MainFrame's disk. **Needs no host access at all**, which is the entire point of it.

Verified end-to-end on 2026-08-21 by shipping a real fix: edit in `lua/` → `pownet-sync.sh` →
present on the floppy → served identically by HQ → reboot `#113` → the module had pulled the new
code onto itself and came back `ok=true`.

**A PowNet change needs TWO reboots.** The bootloader does `os.loadAPI("PowNet")` *before*
`PowNet.UpdateModule("PowNet")`, so the first reboot only downloads the new API and the second one
loads it. A module that pulls its own new `.lua` while running the old PowNet dies on whatever
function is new — with that function plainly present in the file on disk. Module-only changes need
one reboot.

## What actually works

- Drone registration — idempotent and self-healing (retries used to create duplicate drones).
- Docking and dock refuelling.
- The full **mine → haul → deposit → index** loop: 21 sand mined, delivered, indexed by StorageMan
  over the wired network.
- Survey → geoscan → upload → merge (the map grew 27,470 → 34,801 bytes).
- Role-aware dispatch — `survey-north` went to the scout, miners untouched.
- GPS constellation, chunk-loader auto-detection, resume-across-update.

Roles are derived from hardware, not configured: `geoscanner_turtle` → `scout`, a peripheral of
type `chunky` → `loader`, otherwise `miner`.

## What does not work yet

- **Smelting has still never actually run** — no furnace has ever been placed. The code is real and
  ticks every 10s, and a jam bug in it was fixed on 2026-08-21 (`isSmeltable` used substring
  matching, so `"sand"` matched `soul_sand` and `"cobblestone"` matched `cobblestone_stairs`;
  neither smelts, and since input only reloads when slot 1 is empty, one such item killed that
  furnace permanently). Matching is now exact plus an anchored `_ore$`, and a non-smeltable input is
  pushed back to storage. **All of that is still untested against a real furnace.**
- **Crafting and factories are design-only.**
- **`Haul` as a separate role is untested** — hauling happens inside the dig job.
- **No Bridge exists**, so HQ has never talked to the world. `hive.pow/health` reports
  `"bridge": {"connected": false}` and has since it was first started.

## The callable surface HQ tools must mirror

| module | callables |
|---|---|
| DroneMan | `Heartbeat` `RegisterDrone` `RestartDrones` `DockDrones` `Distress` `ListStuck` `RescueDrones` `Escort` `GetDrones` `SurveyDrones` `GoTo` |
| MapServer | `SaveWorld` `LoadWorld` `GetPath` `UpdatePath` `SetDronePos` `MapMode` `GetBounds` `AddGpsHost` `SetBounds` `MapFollow` `MapInfo` |
| TaskMan | `Abort` `AddTask` `StartTask` `PauseTask` `AbortTask` `GetTasks` `ListFleet` |
| DockingMan | `AllocateDocking` `ListDockingTowers` `DelDockingTower` `AddDockingTower` `EditDockingTower` `GetDroneInfo` |
| StorageMan | `Find` `Stock` `DepositPoint` `AddDeposit` `Smelt` |

In Lua these are `On<Name>`; over the wire the `key` is the name without `On`. HQ's own tools
(`hive.brief`, `fleet.status`, `world.query`, `order.issue`, `order.abort`, `recover.dispatch`)
hardcode none of these, which is why all ~1,350 lines of `hq/` survived the reconciliation intact.

## Traps that cost real hours

The full list is in `.agents/memory/computercraft.md`. The ones that bite hardest:

- **Labels and turtle upgrades are RUNTIME state.** `data merge` on a running computer appears to
  work and is silently undone — CC:T writes the live object back over block NBT on shutdown. Stop
  the computer, edit, start it.
- **`rcon-cli` eats negative coordinates as its own flags.** Quote the whole command as one string.
  Also: `rcon-cli` lives in the `mc-create121` container, not `mc-create121-pack` (that one is nginx
  serving the modpack).
- **Two bootloaders.** `disk/startup` is the MODULE bootloader and refuses to act without a label.
  `DroneBoot.lua` is the DRONE bootloader and never reads the label — drones must use it, because
  `DroneLogic.Init()` only registers when the label is nil. Label a drone up front and it never
  registers *while still sending heartbeats*, so it looks alive and is invisible to dispatch.
- **`os.loadAPI` executes the chunk**, so top-level code in a "library" runs on load.
- **`parallel.waitForAny` ends when ANY branch returns** — a tick loop must never return.
- **"left" is the viewer's left**, not the computer's. For a north-facing computer, left is `+X`.
- **Modules write `last-run.txt` and `exit-reason.txt`** to their own computer directory. That is
  the fastest way to tell a module that is *hosting* from one sitting dead at a prompt — both look
  "on" to `computercraft dump`.

## Registration chain — every link is required

    drone → DroneMan.RegisterDrone → DockingMan.AllocateDocking → MapServer.SetDronePos

`RegisterDrone` returns `false, "Failed to get docking"` if DockingMan does not answer, so **no
drone can register until DockingMan is up**. That alone kept the registry empty once.

## Next steps

1. **Place a Bridge computer** (not `#78`) and label it `Bridge`. Then `hive.pow/health` should flip
   to `"bridge": {"connected": true}` and the tool surface goes live for the first time.
2. Point HQ's 6 tools at the real callables above.
3. Run the SPEC §9 Sable carrier probes — Phase 0, which everything else is gated behind.
4. Place a furnace on the wired network and finally test smelting.
