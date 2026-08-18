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

Phase 0 (run §9 Sable carrier probes) — pre-integration. All source files exist and
type-check cleanly (strict mode, no dist yet). No test suite exists (no `"test"` script in
package.json, no `*.test.ts` / `*.spec.ts` files). No git repo.

## Open questions

- Are the Sable carrier probes (Phase 0, §9 of SPEC.md) run yet?
- Is there a live HQ instance to smoke-test against, or is this all source-only?
- What is the target small model for the commander profile? (profiles.ts says 'small' as a hint)
