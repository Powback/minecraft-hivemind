# HiveMind

An autonomous ComputerCraft (CC:Tweaked) turtle fleet for Minecraft, with an out-of-world "HQ"
service that plans, dispatches and monitors it. Turtles ("drones") stay deliberately dumb: they
mine, fell trees, build, haul, craft and rescue each other, and report back. Planning, the world
model, the plot registry and the recipe graph live in HQ, a small Node/TypeScript service that an
AI agent (or a human) drives through typed tool calls. The long-term goal is a procedural
settlement the fleet builds and runs by itself.

HiveMind extends PowNet V2 from [Powback/CC-PowNet](https://github.com/Powback/CC-PowNet).

**Status: experimental, actively worked on.** The code runs against a live world, and the notes in
`CLAUDE.md` document the open problems. The biggest one is that the settlement's fuel economy is not
yet self-sustaining.

## What it does

- **In-world modules** (Lua, on CC computers). `MainFrame` is the hub and code distributor,
  `TaskMan` is the priority task queue and worker assignment, `DroneMan` is the drone registry and
  heartbeats, `MapServer` and `PowGPSServer` hold the shared world cache and A* pathfinding,
  `StorageMan` indexes chests over a wired-modem network, and `DockingMan` and `TankStation` handle
  docking and refuelling.
- **Drones** (`DroneLogic.lua`, `DroneBoot.lua`). An unlabelled turtle locates itself by GPS,
  registers with `DroneMan`, gets a name and a dock, and then takes jobs. Job types include dig,
  lumber, build, haul, survey and rescue. Drones also enforce fuel reserves, operating bounds and
  stuck detection, and can resume a job after an update.
- **Messaging.** `PowNet` is a rednet transport with retrying RPC. `Bridge.lua` relays between
  rednet and HQ over a websocket, with reconnect, idempotency keys and request correlation.
- **HQ** (`hq/`). It exposes about 65 tools (`fleet.*`, `order.*`, `world.*`, `storage.*`,
  `plot.*`, `plan.*`, `factory.*`, `rescue.*` and others). The tools are validated with zod and
  published as Anthropic tool-use schemas, filtered per agent profile. HQ also runs background
  loops for supply, bootstrap, the economy sampler and a fault sentinel. It contains no model
  runner; an external agent fetches `/prime` and `/tools` and calls `/invoke`.
- **World and planning** (`hq/src/world/`): a plot registry, a recipe graph, a generator for the
  tower and bay layout, a factory router, and manifests for structure placement.
- **Live 3D map** at `/map` (Three.js) showing the fleet, the surveyed voxels and materials.
- **Code sync.** HQ serves the repo's `lua/` tree with content hashes. `Sync.lua` pulls changed
  files onto MainFrame's disk, and PowNet's `UPDATE` then distributes them to drones.

## Requirements

- Minecraft 1.21.1 (NeoForge) with CC:Tweaked. The spec also uses Advanced Peripherals, Create and
  AE2.
- A Minecraft server with RCON enabled. HQ uses RCON only to set the peripheral state on wired
  modems, and the bootstrap and `bin/` scripts use `rcon-cli` to place things.
- Docker and Docker Compose for HQ, or Node 22 to run it directly.
- For tests: Lua 5.4, `luac` and `luacheck` (`brew install luacheck`).

## HQ endpoints

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness and bridge state |
| `GET /tools?profile=...` | Tool schemas a profile may call |
| `GET /brief` | Live situation summary, including faults and economy |
| `GET /prime?profile=...` | System prompt and primed messages for an agent |
| `POST /invoke` | Validated tool call |
| `WS /bridge` | The in-world Bridge connects here |
| `GET /lua/manifest`, `GET /lua/file/:path` | Lua file sync |
| `GET /map`, `/map/state`, `/map/voxels` | 3D map and its data |

## Running HQ

```sh
cd hq
npm install
npm run dev          # tsx watch src/server.ts, port 4400
# or
docker compose up -d --build
```

`hq/docker-compose.yml` is written for the author's setup and needs adapting elsewhere:

- It joins two external Docker networks: a Traefik network and the Minecraft server's compose
  network.
- It expects an RCON host named `mc-create121`.
- Its Traefik labels use a private hostname.

The compose file also starts a second service, `fleet-watch` (`hq/watch/`). It polls `/brief` and
prints a line whenever a fault appears or clears. Alarm-class faults are also sent in-game over
RCON.

### Configuration (environment)

Secrets go in `hq/.env`, which is gitignored (for example `RCON_PASSWORD`).

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4400` | HTTP/WS port |
| `LUA_DIR` | `../lua` | Lua tree served for sync (compose mounts it read-only at `/lua`) |
| `PUBLIC_DIR` | `./public` | Static files for `/map` |
| `STATE_DIR` / `HIVE_STATE` | `/state` | Persistent state (plot registry and so on); compose uses a named volume |
| `RCON_HOST` / `RCON_PORT` / `RCON_PASSWORD` | `mc-create121` / `25575` / (required) | Minecraft RCON |
| `HIVE_BASE_X` / `_Y` / `_Z` | `64` / `66` / `32` | Settlement base position |
| `HIVE_REACH` | `56` (compose sets `72`) | Operating radius around the base |
| `HIVE_RADIO_RANGE` | `88` | Assumed range of the mast radio |
| `HIVE_KEEPOUT` | `26` | Keep-out radius used for plot allocation |

The HQ address the in-world code connects to is hard-coded near the top of `lua/Bridge.lua`
(websocket) and `lua/Sync.lua` (HTTP). Set both to wherever your HQ is reachable from the
Minecraft server.

## Deploying to the world

`lua/` in this repo is the source of truth for all in-world code. MainFrame's disk is what the
fleet actually runs, and drones pull from it on boot.

```sh
bin/pownet-sync.sh             # push lua/ to the in-world floppy (--back pulls, --diff compares)
bootstrap/redeploy.sh TaskMan  # redeploy and restart one module, or omit args for everything
bin/pownet-update.sh           # push and take the whole fleet through a graceful stand-down
```

`redeploy.sh MainFrame` stands down the entire fleet, because MainFrame's INIT broadcast acts as a
shutdown. Jobs survive it, but it interrupts everything, so prefer redeploying the single module
you changed.

### Bootstrapping a fresh world

The scripts in `bootstrap/` place the initial infrastructure through RCON:

- `gps.sh`: the GPS constellation
- `module.sh <Label> <x> <y> <z>`: a module computer
- `drone.sh <role> <x> <y> <z>`: a drone; the role is `miner`, `scout`, `loader` or `crafter`
- `storage.sh`: networked storage
- `repeater.sh`: a rednet repeater

Structures placed this way are also written out as replayable manifests (see
`bootstrap/README.md`). Several of these scripts assume the author's server layout, such as the
container name, world path and computer IDs, so read each script before running it.

Other helpers in `bin/`:

- `cc-computer.sh`: create, list or remove CC computers from the console
- `pownet-build.sh`, `pownet-drone.sh`, `pownet-convert.sh`: set up the PowNet server machines and
  drones
- `watchdog.sh`, `fleet-watch.sh`: stall and fault monitoring
- `fuel-faucet.sh`: an explicit RCON cheat that tops up coal while the economy is being fixed

## Tests

```sh
cd hq
npm test             # or: npx vitest run
```

The suite has these parts:

- TypeScript unit tests.
- Behavioural tests that run the real Lua modules under Lua 5.4 against a stubbed ComputerCraft
  world (`hq/test/lua/cc_stubs.lua`, `run.lua`).
- `luac -p` on every Lua file.
- `luacheck`, configured in `.luacheckrc`.
- Ratchet checks for complexity, duplication, adoption and silence. Their baselines are in
  `hq/*-baseline.json`, and `hq/scripts/*.mjs --update` records an improvement.

## Project structure

```
lua/          In-world code: MainFrame, TaskMan, DroneMan, MapServer, StorageMan, DockingMan,
              DroneLogic, pgps (movement/position), PowNet, Bridge, Sync, startup/bootloaders
hq/           HQ service (TypeScript): src/server.ts, src/tools, src/agent, src/world, public/ (map),
              test/, scripts/ (ratchet scanners), watch/ (fleet-watch container)
bootstrap/    RCON recipes and manifests for placing initial infrastructure
bin/          Sync, deploy, monitoring and computer-management scripts
SPEC.md           Original HiveMind design spec
SPEC-CONTROL.md   Draft spec for an RTS-style control surface (not built)
ARCHITECTURE.md   Layering (HQ / in-world coordination / drones), plot registry, recipe graph
CLAUDE.md         Working notes: deploy rules, known traps, debugging history
```
