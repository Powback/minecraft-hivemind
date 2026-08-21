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
| `#120`–`#123` | `D4`, `D1`, `D2`, `D3` | drones — `loader`, `miner`, `miner`, `scout` |
| `#124` | `Bridge` | the link to HQ (placed 2026-08-21) |

### `#78` is MainFrame. Do NOT label it `Bridge`.

`computercraft.md` still described `#78` as "hivemind-1, the Bridge computer" — that is **stale and
dangerous**. `#78` was repurposed as MainFrame. Labelling it `Bridge` would destroy the module that
serves source to the entire fleet and take everything down.

The Bridge is **`#124`** at `-99 81 -44`, placed 2026-08-21 with a wireless modem above it. HQ
reports `"bridge": {"connected": true}` and tool calls reach the fleet.

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

## Issuing work — verified end to end 2026-08-21

`order.issue` now reaches the fleet. It was previously a no-op that returned a plausible
`status: "queued"` while nothing left HQ's memory — the most misleading failure this API could
have. It calls `TaskMan.Add` (see the key warning below) and reports `dispatched: true/false` plus
`dispatchError`, so a failure to reach the world can never again look like success.

Proven: `order.issue {kind:'dig', bounds:{min:{-72,68,-62}, max:{-70,70,-60}}}` → `dispatched:true`
→ TaskMan assigned it → **D1 went `idle` → `mining` and physically moved**
(`-95,80,-46` → `-99,80,-46` → `-99,79,-46` → `-96,79,-47`).

`order.issue` maps `kind:'explore'` to `work.survey` (scout) and everything else to `work.dig`
(miner). TaskMan's `RoleForWork` picks the role from the work type, so the right drone gets the job.

## The drone job verbs that actually exist

`GoTo` `Rescue` `Scan` `Survey` `Dig` `Haul` `Abort` `StartTask` `AbortTask` `Reboot`.

**There is no forestry.** No tree felling, no log gathering, no sapling planting — nothing produces
wood. Roles are `miner`, `scout`, `loader` only. Any plan that assumes lumber is available is
assuming a capability that has never existed.

## What does not work yet

- **Smelting has still never actually run** — no furnace has ever been placed. The code is real and
  ticks every 10s, and a jam bug in it was fixed on 2026-08-21 (`isSmeltable` used substring
  matching, so `"sand"` matched `soul_sand` and `"cobblestone"` matched `cobblestone_stairs`;
  neither smelts, and since input only reloads when slot 1 is empty, one such item killed that
  furnace permanently). Matching is now exact plus an anchored `_ore$`, and a non-smeltable input is
  pushed back to storage. **All of that is still untested against a real furnace.**
- **Crafting and factories are design-only.**
- **`Haul` as a separate role is untested** — hauling happens inside the dig job.
- Nothing else known broken. HQ ↔ fleet is live: `hive.brief` and `fleet.status` return all four
  drones with `silentMs: 0`.

## The callable surface — use the REGISTERED KEYS, not the handler names

**The wire key is the key in each module's `m_ServerEvents` table, which is often NOT the
`On<Name>` handler it points at.** TaskMan registers `OnAddTask` under `Add`; calling `AddTask`
reaches TaskMan, matches no handler, and gets **no reply at all** — so it surfaces as a timeout
rather than "unknown method", which is maximally confusing. Read the table, do not infer from
function names.

| module | registered keys |
|---|---|
| DroneMan | `RestartDrone` `DockDrones` `GetDrones` `Distress` `escort` `stuck` `rescue` `drones` `survey` `GoTo` |
| TaskMan | `start` `pause` `stop` `fleet` `GetTasks` `StartTask` `PauseTask` `AbortTask` `Abort` `Add` `Start` `Pause` |
| DockingMan | `add` `rm` `ls` `edit` `AllocateDocking` `GetDroneInfo` |
| MapServer | `UpdatePath` `SaveWorld` `LoadWorld` `GetPath` `SetDronePos` `GetBounds` `gpshost` `bounds` `map` `follow` `mapinfo` |
| StorageMan | `FindItem` `DepositPoint` `GetStock` `find` `stock` `deposit` `smelt` |

Casing is inconsistent and deliberate-looking but is not: some keys are CLI-style lowercase verbs
for the in-game console, others are PascalCase for programmatic use, and several are aliases for the
same handler. Extract them fresh rather than trusting this table after edits:

```bash
python3 - TaskMan <<'EOF'
import sys,re; s=open(sys.argv[1]+'.lua').read()
b=re.search(r'local m_ServerEvents\s*=\s*\{(.*?)\n\}', s, re.S).group(1)
print(re.findall(r'^\s{4}([A-Za-z_]\w*)\s*=\s*\{', b, re.M))
EOF
```

HQ's own tool names (`hive.brief`, `fleet.status`, `world.query`, `order.issue`, `order.abort`,
`recover.dispatch`) are a separate, stable surface that maps onto these.

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

## Four bugs that stood between HQ and the fleet — fixed 2026-08-21

All four failed *silently*, which is why they survived so long. Read these before debugging the
Bridge again.

1. **`Bridge.lua` did `os.loadAPI("disk/PowNet")`** — from when it ran standalone beside the disk
   drive. As a module fetched from MainFrame there is no `/disk` mount, so it died with
   "Failed to load API PowNet due to File not found" while PowNet sat plainly in its own root.
   The bootloader already loads PowNet; real modules never load it themselves.

2. **`onFrame` created a coroutine for each CALL and resumed it exactly once.** `handleCall` yields
   almost immediately (`PowNet.Lookup` → `rednet.lookup`), so every call was abandoned at its first
   yield — it never even reached its first log line. There is now a task list pumped from the
   socket loop.

3. **The pump truncated event arity.** A websocket event is `(event, url, param)` but a
   `rednet_message` is `(event, senderId, message, protocol)`. Forwarding only three values meant
   `rednet.receive`/`lookup` inside a call never matched, so every module lookup returned nil.
   Use `table.pack`/`table.unpack`, never named locals, when relaying events to coroutines.

4. **HQ's tools never talked to the world at all.** `core.ts` imported only `registry` and `state`;
   all six tools read HQ-local state fed by `drone.heartbeat` EVENTs that can never arrive —
   DroneLogic sends heartbeats *directed to DroneMan on SERVER_PROTOCOL*, while the Bridge listens
   for broadcasts on DRONE_PROTOCOL. Wrong protocol and wrong addressing. `fleet.status` and
   `hive.brief` now call `DroneMan.GetDrones` through the Bridge, which is authoritative anyway.

Note also that **`last-run.txt` is written when a module EXITS**, not while it runs. A running
module shows a stale `last-run.txt` from its previous exit — do not read it as current health.

## Next steps

1. Point the remaining HQ tools (`world.query`, `order.issue`, `order.abort`, `recover.dispatch`)
   at real callables the way `fleet.status` now is.
2. Run the SPEC §9 Sable carrier probes — Phase 0, which everything else is gated behind.
3. Place a furnace on the wired network and finally test smelting.
