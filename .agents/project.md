# HiveMind — what this project IS

HiveMind extends **PowNet V2** (prior art: `Powback/CC-PowNet`) into an autonomous
Minecraft turtle "drone army" commanded by Claude. Substrate: Minecraft 1.21.1 NeoForge
with CC:T, Advanced Peripherals, Create + Sable, AE2.

Core idea: drones stay dumb (mine, build, craft, scout, recover; execute and report);
intelligence moves out of world into **HQ** — a Docker service on PowStation (`hive.pow`)
holding the voxel world model (L2, staleness decay), planner, fleet state, and HTTP/WS +
MCP API. Claude talks to HQ via typed tools mirrored from PowNet's callable registry.

## Layout

- `lua/` — in-world code:
  - `Bridge.lua` (212 LOC) — dedicated CC computer next to MainFrame; relays
    rednet ↔ websocket↔HQ. Handles reconnect/backoff, idempotency, correlation, PING.
  - `Sync.lua` (137 LOC) — pulls the Lua tree from HQ onto MainFrame's disk via
    `/lua/manifest` + `/lua/file/:path`; hash-diffed so no-change sync is one small request.
  - `PowNet` (92 LOC) — PowNet V2 module. 8 symbols on the `PowNet` global:
    `Connect()`, `newMessage(type,key,data)`, `sendAndWaitForResponse(module,message,protocol)`,
    `control`, `MESSAGE_TYPE.CALL`, `MESSAGE_TYPE.INIT`, `DRONE_PROTOCOL`, `SERVER_PROTOCOL`.
    Loaded via `os.loadAPI("disk/PowNet")` by Bridge.lua and Sync.lua.
- `hq/` — out-of-world service (TypeScript, Node 22, ~1620 LOC total):
  - `src/server.ts` (178) — HTTP server: `/health`, `/tools`, `/brief`, `/prime`,
    `/invoke`, `/lua/manifest`, `/lua/file/:path`; WS on `/bridge`.
  - `src/tools/core.ts` (265) — tool definitions: `hive.brief`, `fleet.status`,
    `world.query`, `order.issue`, `order.abort`, `recover.dispatch`.
  - `src/tools/registry.ts` (197) — single-source contract layer; generates JSON Schema,
    runtime validation, and priming examples from one `ToolDef`.
  - `src/world/state.ts` (168) — in-memory HiveState: cells, drones, orders; staleness decay.
  - `src/agent/profiles.ts` (137) — commander / scout / quartermaster profiles.
  - `src/agent/priming.ts` (120) — synthetic boot transcript: teach turns + live brief.
  - `src/bridge/ws.ts` (206) — Bridge class: WS server, CALL/REPLY correlation,
    timeouts, backpressure, event ingestion.
- `hq/skills/` — empty (0 files).
- `hq/node_modules/` — installed (tsx, typescript, ws, zod, zod-to-json-schema).
- `hq/dist/` — does not exist yet (not yet built).

## Current state

Phase 1 (HQ + Bridge integration) — in flight.

**Live service**: HQ running on `:4400`, 6 tools registered, 3 profiles
(commander/scout/quartermaster). All endpoints verified working:
- `/health` — `ok:true`, `bridge.connected:false` (no bridge yet), `tools:6`
- `/tools?profile=commander` — 6 tools
- `/tools?profile=scout` — 3 tools (hive.brief, fleet.status, world.query)
- `/tools?profile=quartermaster` — 4 tools (hive.brief, fleet.status, order.abort, recover.dispatch)
- `/brief` — fleet (0 drones), orders, world coverage, problems
- `/lua/manifest` — lists Bridge.lua, Sync.lua, PowNet with sha1 + bytes
- `/lua/file/:path` — serves raw source
- `/prime?profile=commander` — full boot transcript

**In-world**: Bridge computer #78 `hivemind--1` at -85 81 -44, running, persistent.
Wireless modem on its right (rednet works). Disk drive on its left with a floppy,
mounted as /disk, WRITABLE.

**lua/ tree** (3 files):
- `Bridge.lua` (212 LOC) — websocket ↔ rednet relay
- `Sync.lua` (137 LOC) — file sync from HQ
- `PowNet` (92 LOC) — PowNet V2 module with 8 symbols

**Next steps**:
1. Verify Sync.lua works on Bridge computer #78
2. Verify Bridge.lua connects to HQ (ws://hive.pow/bridge)
3. Verify HQ /health shows bridge.connected:true
4. Verify drones can register

## Open questions

- Are the Sable carrier probes (Phase 0, §9 of SPEC.md) run yet?
- What is the target small model for the commander profile? (profiles.ts says 'small' as a hint)
