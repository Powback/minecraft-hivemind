# HiveMind — log (append-only, newest first)

## 2026-08-18 — Project read, task filed, run started

Read all ~1620 LOC across `hq/src/` (7 files) and `lua/` (2 files). Verified:
- Volume formula at core.ts:23 and state.ts:106
- order.issue teach ex2 claims 2,452,200 blocks but actual is 2,464,461
- order.issue teach ex1 (500) and world.query teach (29,791) are correct
- No test suite, no `"test"` script, no `dist/`
- `hq/skills/` is empty
- All 22 gateway workflows listed; picked `dev-review` (develop→review→merge, $10, 1M tokens)
- Filed task and started run.
