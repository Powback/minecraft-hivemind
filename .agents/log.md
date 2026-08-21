# HiveMind — log (append-only, newest first)

## 2026-08-21 — PowNet V2 written, service verified, card updated

- Wrote `lua/PowNet` (92 LOC) — PowNet V2 module with 8 symbols:
  Connect(), newMessage(type,key,data), sendAndWaitForResponse(module,message,protocol),
  control, MESSAGE_TYPE.CALL, MESSAGE_TYPE.INIT, DRONE_PROTOCOL, SERVER_PROTOCOL.
- Verified HQ service running on :4400, all 7 endpoints working, 3 profiles, 6 tools.
- Verified /lua/manifest lists Bridge.lua, Sync.lua, PowNet with sha1 + bytes.
- Verified /lua/file/PowNet serves the source.
- Bridge computer #78 confirmed in-game (hivemind-1 at -85 81 -44, modem on right,
  disk drive on left with writable floppy at /disk).
- Updated project.md to Phase 1, added PowNet to layout, listed live service state.

## 2026-08-18 — Project read, task filed, run started

Read all ~1620 LOC across `hq/src/` (7 files) and `lua/` (2 files). Verified:
- Volume formula at core.ts:23 and state.ts:106
- order.issue teach ex2 claims 2,452,200 blocks but actual is 2,464,461
- order.issue teach ex1 (500) and world.query teach (29,791) are correct
- No test suite, no `"test"` script, no `dist/`
- `hq/skills/` is empty
- All 22 gateway workflows listed; picked `dev-review` (develop→review→merge, $10, 1M tokens)
- Filed task and started run.
