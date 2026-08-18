# HiveMind — Spec

**Status:** draft · 2026-08-13
**Substrate:** Minecraft 1.21.1 NeoForge (`mc-create121`, port 25567), CC:T 1.120.2,
Advanced Peripherals 0.7.62b, Create 6 + Aeronautics/Sable, AE2, 66-mod packwiz pack.
**Prior art:** [`Powback/CC-PowNet`](https://github.com/Powback/CC-PowNet) — `TurtleHQ/lua/V2`.

---

## 1. Goal

Turn PowNet from a **task system you drive** into an **autonomous drone army an AI commands**:
drones that mine, build, craft, scout, and recover each other with no human in the loop, and a
commander (Claude) that can see the world, form intent, issue orders, and replan on failure.

Two constraints shape everything, and they were both already right in PowNet V2:

> *"The turtles should be as dumb as possible!!!"* — `todo.txt.lua`
>
> *"If the drone fails to accomplish said instructions, it will report back why it failed, and the
> server will provide new instructions that takes the failure into account."* — README

Intelligence lives on servers. Drones execute and report. HiveMind keeps that and adds one layer
above it.

---

## 2. What already exists (keep)

PowNet V2 is further along than a prototype. Inventory of what carries forward unchanged:

| Component | Role | Verdict |
|---|---|---|
| `PowNet` | rednet transport, 2 protocols (`:Server`, `:Drone`), 6 message types, retrying RPC | **Keep** — proven |
| `MainFrame` | hub: VFS data store, code distribution (`UPDATE` serves module source), callable registry | **Keep** — becomes bridge host |
| `MapServer` + `PowGPSServer` | shared world cache + A* pathfinding, `SaveWorld`/`GetPath`/`UpdatePath` | **Keep, extend** — this *is* the world model |
| `DroneMan` | drone registry, self-naming, dock assignment on first boot, heartbeats | **Keep** |
| `TaskMan` | priority task queue, task decomposition, worker assignment | **Keep, extend** |
| `DockingMan` / `TankStation` | docking slots, refuelling | **Keep** |
| `PowNetRemote` | pocket remote w/ GPS | **Keep** — human override path |
| `libs/lama` | fault-tolerant movement/position | **Keep** — critical for resume-after-crash |
| Startup + `updater` | boot + auto-update from MainFrame | **Keep** — deploy mechanism for everything below |

**Design assets worth calling out**, because they're doing more work than they look like:

- **Drone self-registration.** An unlabelled turtle GPS-locates, calls `RegisterDrone`, receives a
  name and a dock to fly to. Place a turtle, it joins the swarm. Zero-touch provisioning.
- **The callable registry is a tool schema.** `RegisterCallable` ships `params` with
  `type` (`string`/`int`/`vec3`/`list`/`option`), `optional`, and `description` — built for the
  remote's wizard GUI. That is a function-calling schema in all but name. See §7.

---

## 3. What the new stack changes

Four mods move things that were previously impossible or hand-rolled:

| Capability | PowNet V2 | HiveMind |
|---|---|---|
| **Perception** | `turtle.inspect()` — 3 blocks | **Advanced Peripherals `geoScanner`** — volumetric radius scan |
| **Crafting** | turtle crafting + manual recipe logic | **AE2 autocrafting via ME Bridge** — dependency trees solved for us |
| **Building** | turtle block-by-block placement | **Create Schematicannon** — correct orientation + block states, free |
| **Mobility** | static base, chunk-load-bound | **Sable airship carriers** (pending §9 probes) |
| **Ground truth** | drone-derived map only | **BlueMap** 3D web render of the real world |

The architectural consequence: **stop making turtles do the things they're bad at.** Turtles are
uniquely good at *mobile autonomous work in unexplored terrain* — scouting, mining, GPS-mast
placement, recovery. Let AE2 craft and let the Schematicannon build.

---

## 4. Architecture

```
                        ┌───────────────────────────────────────┐
   OUT OF WORLD         │  Claude (commander)                   │
   (Docker, PowStation) │   intent · planning · replanning      │
                        └──────────────┬────────────────────────┘
                                       │ typed tools (from callable registry)
                        ┌──────────────▼────────────────────────┐
                        │  HQ  — hive-hq service                │
                        │   world model (voxel + staleness)     │
                        │   blueprint & order planner           │
                        │   fleet state · telemetry · audit      │
                        │   HTTP/WS API + MCP                    │
                        └──────────────┬────────────────────────┘
                                       │ websocket  (CC:T http.websocket)
════════════════════════════════════════════════════════════════════════
                                       │
   IN WORLD             ┌──────────────▼────────────────────────┐
   (ComputerCraft)      │  MainFrame  (+ Bridge)                │
                        │   VFS · code distribution · registry  │
                        └───┬───────┬────────┬───────┬──────────┘
                            │       │        │       │      PowNet:Server (rednet)
                     ┌──────▼─┐ ┌───▼────┐ ┌─▼─────┐ ┌▼────────┐
                     │DroneMan│ │TaskMan │ │MapSrv │ │DockingMan│
                     └──────┬─┘ └───┬────┘ └─┬─────┘ └┬────────┘
                            └───────┴────────┴────────┘
                                       │ PowNet:Drone (rednet)
                        ┌──────────────▼────────────────────────┐
                        │  Drones — behaviours, not instructions │
                        │   goto · mine · scan · build · recover │
                        └───────────────────────────────────────┘
```

**The one new in-world component is the Bridge** — a CC computer that holds a persistent
`http.websocket` to HQ and relays between rednet and the outside world. Everything else is PowNet V2.

### Why the brain moves out of the world

- Lua-on-a-CC-computer can't hold a voxel world model, run real pathfinding at scale, or persist
  history. It already strains: `MapServer` caches world data in VFS.
- HQ is a normal service on PowStation — it can be version-controlled, tested, restarted, and
  observed without touching the game.
- It is where an AI can actually reach. CC:T can't call Claude; HQ can.

MainFrame stays authoritative for **code distribution and in-world coordination**, so the swarm keeps
functioning (degraded, executing standing orders) when HQ is down. **HQ must not be a single point of
failure for drone safety** — a drone that loses HQ finishes its order, returns to dock, and idles.

---

## 5. Protocol

**In-world:** unchanged. `PowNet:Server` / `PowNet:Drone` over rednet, message types
`GET/SET/INIT/REGISTER/UPDATE/CALL`, `sendAndWaitForResponse` with 3 retries at 1 s.

**Bridge ↔ HQ:** JSON over websocket. Envelope mirrors PowNet so translation is mechanical:

```jsonc
{ "type": "CALL", "id": 1234, "module": "TaskMan", "key": "Add", "data": { … } }
{ "type": "EVENT", "key": "drone.heartbeat", "data": { "drone": 7, "pos": {...}, "fuel": 812 } }
{ "type": "SCAN",  "key": "geo", "data": { "origin": {...}, "blocks": [ … ] } }
```

Requirements on the CC:T side: HTTP + websockets enabled and HQ's host allowlisted in the server
config. **This is the one config from the old pack worth porting deliberately.**

Bandwidth discipline: rednet is slow and drones are many. Scans are the only bulk payload — batch,
delta-encode against the known world, and never resend a chunk whose hash is unchanged.

---

## 6. World model & perception

Four layers, distinct on purpose:

- **L0 — local.** `inspect()` front/up/down. Collision sense, not mapping.
- **L1 — scan.** `geoScanner` radius scan → block list. Each drone becomes a volumetric sensor.
  Cooldown/fuel cost scales with radius; treat scans as a budgeted resource, not free.
- **L2 — world model (HQ).** Voxel store keyed by coordinate, each cell carrying
  `{block, source_drone, observed_at}`. **Staleness decay is mandatory** — the world changes and a
  confidently-wrong map is worse than an empty one. Pathfinding, blueprint validation, and target
  selection all read L2. This is `MapServer`'s cached world, promoted out of Lua and given a memory.
- **L3 — ground truth (BlueMap).** 3D render of the *actual* server world, over HTTP.

**Open design decision — god view or fog of war?** L3 is omniscient. Letting the commander read it
makes planning trivially easy and makes scouting pointless. Restricting the commander to L2 means
exploration has real value and drone loss has real cost. *Recommendation: L2 for planning, L3 for
human dashboard + a deliberate "satellite intel" order that costs something.*

---

## 7. Orders, tasks, and the AI interface

Keep TaskMan's model: priority 1–5 with push-down, `MaxCooperativeProjects` capping how much of the
fleet one project can eat, decomposition into per-drone work with saved `taskVars` so a worker can
resume at the same position and heading. Keep fuel-aware dispatch — *can this drone reach the work
and get home?* — which V2 already specifies and which most swarm designs forget.

**Layering above it:**

```
Claude          intent      "clear the hill north of base, build the dock, keep 4 drones on ore"
  ↓
HQ planner      orders      decompose → dig(min,max) · build(schematic) · standing(quarry)
  ↓
TaskMan         tasks       priority queue, worker assignment, progress
  ↓
Drone           behaviours  goto · mine_vein · place · scan · dock · recover
```

The commander never emits `turtle.forward()`. Round-trip latency and link loss make remote
micromanagement both slow and fragile; behaviours degrade gracefully, instruction streams don't.

### Tools come from the callable registry

`RegisterCallable` already carries typed params. HQ mirrors the registry and emits JSON Schema, so
**every module that registers a callable automatically becomes an AI tool** — no parallel API to
maintain and no drift. New module → new capability → commander can use it immediately.

Reserved commander tools beyond the mirrored ones:

| Tool | Purpose |
|---|---|
| `world.query(region\|block\|nearest)` | read L2 with staleness |
| `fleet.status()` | drones, roles, fuel, position, current order |
| `order.issue / amend / abort` | intent in, task IDs out |
| `blueprint.plan(schematic)` | material bill + placement order + cannon vs. turtle decision |
| `craft.request(item, n)` | via ME Bridge → AE2 |
| `recover.dispatch(drone)` | rescue mission (§8) |

**Safety rails, non-negotiable:** every order is auditable, bounded (a dig has a max volume), and
abortable; a global stop-all is reachable from the pocket remote without HQ. An autonomous swarm with
a mining laser and no brakes is a griefing bot pointed at your own base.

---

## 8. Capability tiers

Ordered by realism, not ambition:

1. **Solved by V2** — goto, dig area, follow, dock, refuel, drone registration, GPS.
2. **Near-term** — scan-driven exploration feeding L2; quarry with ore detection via `geoScanner`
   (V2 planned this with a scanner-drone role); auto GPS-mast placement to extend coverage.
3. **Recovery** — the README's "automatic rescue missions". A dead drone can't call for help, so this
   is heartbeat + last-known-position + dead reckoning along its assigned path, then a scout sweep.
   Design it in now; retrofitting position history is painful.
4. **Building** — Schematicannon does placement; drones do the material logistics and cannon
   resupply. `blueprint.plan` decides cannon vs. turtle per structure.
5. **Crafting** — ME Bridge → AE2 autocrafting. Drones become AE2's hands in the field rather than
   crafters themselves.
6. **Carriers** — Sable airship as a mobile forward base (§9).

"Fully autonomously build and craft and wire everything up" = tiers 4+5 composed, with tier 2 feeding
the map. It is an integration problem, not a research problem — *provided* the probes in §9 pass.

---

## 9. Open questions — resolve by experiment

The server is live; these stop being speculation the moment someone runs them.

**Sable / carrier probes** — Sable's own description says sub-levels are *"moving regions of blocks,
block-entities, and entities that remain interactive while assembled"*. Computers and turtles are
block entities, so they should keep ticking on an airship — unlike classic Create contraptions, where
block entities freeze and only Create's own contraption-aware parts (Deployers, etc.) work.

| # | Probe | Why it matters |
|---|---|---|
| P1 | Does `gps.locate()` return sane world coords on a moving sub-level? | If yes, nav on carriers is free. If no, the whole nav layer needs a coordinate bridge. **Highest value.** |
| P2 | Does `turtle.forward()` work inside a sub-level? | Decides whether drones are crew or cargo |
| P3 | Modem range across sub-level ↔ world boundary | Decides whether a carrier can command ground drones |
| P4 | Does a sub-level keep its contents ticking in unloaded chunks? | **Would make carriers the answer to chunk loading** (§10) |
| P5 | Can a drone cross the boundary under its own power, or must it be placed (Deployer)? | Deployment mechanism |

**Other unknowns**

- ~~**AP 0.7.62b vs CC:T 1.120.2.**~~ **RESOLVED 2026-08-13.** AP declares CC:T 1.113.1 and we forced
  latest anyway; both load cleanly together on a healthy server (`Done (7.572s)`, no dependency
  errors, no AP entries in the mod-sorter failures). Tiers 2 and 5 are unblocked at load time —
  still to confirm that `geoScanner` and the ME Bridge behave at *runtime*, which needs a live
  peripheral test, not a boot log.
- Do Turtlematic / UnlimitedPeripheralWorks provide scanner upgrades that cover L1 without AP?
- CC:C Bridge's actual surface — how much Create state can a computer read/drive?

---

## 10. Constraints & risks

- **Chunk loading is the ceiling.** A turtle in an unloaded chunk stops dead. This bounds operational
  radius more than fuel or intelligence. V2 already listed "dynamic chunk-loading" as planned; P4 may
  hand us the answer for free.
- **Server performance.** Each drone is a Lua VM, on a Colima VM already running Create contraptions,
  Distant Horizons and AE2. Fleet size will be capped by the host, not the design. Measure early.
- **Fuel economy** dominates dispatch. V2's "can it get there and back" check stays load-bearing.
- **Mobs.** Drones have no entity awareness without a sensor peripheral; night-time surface work
  loses drones. Turret/patrol roles from the V2 task list mitigate.
- **MineColonies is a snapshot build** and a parallel automation stack. Complementary at best
  (colonists build, drones supply) — explicitly out of scope for v1.

---

## 11. Roadmap

| Phase | Deliverable | Gate |
|---|---|---|
| **0** | Run §9 probes; confirm AP↔CC:T | — |
| **1** | HQ skeleton + Bridge computer; heartbeats and drone registry flowing out of world | Drone state visible via HTTP |
| **2** | L2 world model + scan ingestion; A* moved to HQ, `MapServer` proxies to it | Pathfinding parity with V2 |
| **3** | Callable-registry mirror → tool schemas; commander can issue V2 tasks | Claude runs a dig end-to-end |
| **4** | Recovery missions; scan-driven exploration | A stranded drone gets rescued unattended |
| **5** | `blueprint.plan` + Schematicannon logistics; ME Bridge crafting | A structure built from a schematic, unattended |
| **6** | Carrier ops (gated on P1–P5) | A carrier deploys and recovers a drone team |

Phase 1–3 are pure integration on top of working code. Everything genuinely new starts at 4.

---

## 12. Repo layout (proposed)

```
HiveMind/
├── SPEC.md                 this document
├── hq/                     out-of-world service (Docker, PowStation)
│   ├── src/                world model · planner · API · MCP
│   └── docker-compose.yml
└── lua/                    in-world, deployed via MainFrame's updater
    ├── Bridge.lua          websocket relay  (new)
    └── …                   PowNet V2 modules, extended
```

Lua stays deployable through the existing MainFrame `UPDATE` mechanism — **don't replace a working
deploy path.** HQ is a normal PowStation service behind Traefik (`hive.pow`).
