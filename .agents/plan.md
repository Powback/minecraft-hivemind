# HiveMind — phases and next step

## Phases (from SPEC.md roadmap)

- **Phase 0** — Run §9 probes (Sable carrier behavior). Pre-integration.
- **Phase 1–3** — Integration: HQ + Bridge, world model, tools.
- **Phase 4+** — Recovery, building, crafting, carriers.

## Next concrete step

**Task: Fix the inconsistent volume number in the `order.issue` teach example
and add a test that locks it in.**

Evidence (all verified against source):

| Teach example | bounds | computed volume | claimed in result |
|---|---|---|---|
| order.issue #1 (core.ts:167-171) | {120,64,-50}→{120,64,-50}→{129,68,-41} | 10×5×10 = **500** | `volume: 500` ✓ |
| order.issue #2 (core.ts:178-185) | {0,0,0}→{200,60,200} | 201×61×201 = **2,464,461** | `2452200` ✗ (off by 12,461) |
| world.query (core.ts:131-133) | {100,60,-60}→{:130,90,-30} | 31×31×31 = **29,791** | `volume: 29791` ✓ |

- Volume formula (core.ts:23, state.ts:106): `(max.x-min.x+1)*(max.y-min.y+1)*(max.z-min.z+1)`
- MAX_DIG_VOLUME = 32,768 = 32³ (core.ts:21)
- `dist/` does not exist; no `"test"` script; no `*.test.ts` files

## Deliberate omissions (ruled out)

- No browser check needed — this is a source-only fix + test, no UI.
- No git repo to branch from — run operates on the shared checkout directly.
- Not touching `lua/` — this fix is HQ-side only.
