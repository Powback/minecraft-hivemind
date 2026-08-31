# Working in this repo

Read `ARCHITECTURE.md` for what the system is meant to be. This is about how to change it without
breaking the fleet, and it is written from mistakes that were actually made here — every rule below
cost hours at least once.

## Layout

| Path | What it is |
|---|---|
| `lua/` | Code that runs on in-world computers. `DroneLogic.lua` (drones), `TaskMan`, `DroneMan`, `MapServer`, `StorageMan`, `DockingMan`, `MainFrame`, `pgps` (movement/position), `PowNet` (messaging) |
| `hq/` | TypeScript. Tools, the agent loop, the `/map` page, and every test |
| `bootstrap/` | Shell recipes for placing things in the world: drones, GPS hosts, modules, storage |
| `bin/` | Sync helpers |

The world save lives at `~/Projects/minecraft-create121/data/world`. Drone logs are at
`data/world/computercraft/computer/<id>/drone.log` — that is the primary debugging surface.

## Deploying

```
# Lua -> the fleet. MainFrame's disk is the source of truth; drones pull on boot.
cp -R lua/* <world>/computercraft/computer/<mainframe-id>/disk/
bootstrap/redeploy.sh TaskMan        # one module, cycled and verified
# HQ
cd hq && docker compose up -d --build
```

**`redeploy.sh MainFrame` stands the ENTIRE fleet down.** `MainFrame.Connect()` broadcasts INIT,
which every drone treats as a shutdown. That is by design and fine — jobs survive it via
`Resumable(d)` — but it interrupts everything, so do not do it casually and do not reboot a drone
that is carrying something you care about. Prefer redeploying the single module you changed.

Run `cd hq && npx vitest run` before deploying anything. It includes the Lua guards.

## Verify at the effect, never at the call

Tools here return `ok: true` while doing nothing. All of these did, on the same day:
`task.stop` (requeued instead of stopping), `storage.recall` (dispatched nothing),
`fleet.retire` (HQ still listed the drone), `DroneMan.GoTo` (silently dropped undeclared params).

So: check the world, the drone log, or the state — not the return value. `hive.plan` and
`hive.nodes` are the honest views.

**`fleet.status` is NOT one of them for fuel, cargo or position.** Those three fields are replayed
from the last heartbeat a drone managed to get home, and a drone that is out of radio range, dry, or
lost is precisely the one whose heartbeat is oldest — so the numbers are freshest exactly when they
matter least. Measured side by side in one minute:

| | `fleet.status` said | actually |
|---|---|---|
| D21 fuel | 2,534 | **0** |
| D21 cargo | 32 coal | 34 cobblestone, no coal |
| D21 position | -534,69,26 | -481,65,55 (**53 blocks out**) |
| D14 position | -439,109,56 | -369,64,60 (**70 blocks out**) |

Two hours went into planning around fuel that did not exist: `storage.recall` cheerfully reported
"D21 held 32, asked: true" for coal nobody had, and the drone was written off as stranded 74 blocks
away when it was sitting 22 blocks from home. `computercraft dump` gives true positions, and
`fleet.probe` gives true fuel and inventory in seconds:

```
fleet.probe { id: 51, code: 'return turtle.getFuelLevel()' }
```

Ask one of those before spending a decision on a number from `fleet.status`.

**`fleet.probe` answers questions about the game in seconds.** Use it instead of inferring.

```
fleet.probe { id: 47, code: 'peripheral.wrap("bottom").list()' }
# answer appears in that drone's drone.log as `probe [...] = (type) value`
```

Three wrong implementations of chest withdrawal were written because nobody checked whether a
turtle can read the inventory beneath it. It can.

## Traps that have bitten repeatedly

**A `local` declared below a function that uses it is a nil global.** No error, no warning — the
branch is simply dead. This has caused nine separate outages, including one where `OnGoTo` called
`reachableTarget` 465 lines before its declaration, so *every* `GoTo` — and therefore every rescue —
threw on its first line for days while TaskMan logged successful dispatches.

**CC APIs degrade silently rather than failing.** `turtle.dropDown()` throws items on the ground and
returns `true` when there is no container below (use `PutDown()`). `setblock` drops a turtle upgrade
given the wrong namespace — tools are `minecraft:`, modems are `computercraft:`. A `local` numeric-for
control variable cannot be assigned. `turtle.refuel(0)` is not a reliable fuel test here.

**`turtle.craft()` matches against the WHOLE inventory, not just the 3x3 grid.** Every slot outside
the recipe must be empty, including 4, 8 and 12-16. A correct layout with 14 surplus logs parked in
slot 16 returns "No matching recipes", which reads as a broken recipe and is not one.

**`turtle.transferTo(n)` while slot `n` is selected moves nothing and reports nothing.** Anything
that deals items into a grid has to treat source == destination as already-satisfied, or it raises
"short of X" with X sitting in the destination slot.

**PowNet drops undeclared params.** If a field is not in the endpoint's `params` spec it never
reaches the handler, and the call still succeeds. This swallowed the MapServer bounds push and every
`Handover`/`Unload` for hours.

**One question, one function — "what counts as fuel" was answered three different ways in TaskMan
alone.** The emergency filter matched the substring `"coal"`, the queue ordering had its own idea,
and `preemptable()` kept a third local `producesFuel()` that also only knew coal. So `gather:oak_log`
— the settlement's only renewable fuel — was banned during fuel emergencies, sorted below coal, and
preempted mid-run for rescue duty. Three separate bugs, one duplicated concept. When a predicate
answers a question the whole file cares about, there is exactly one of it.

**For a field that grants permission to SKIP, a stale answer is worse than no answer.**
`OnDepositPoints` ships each chest's contents and the drone skips every chest "known not to hold it".
`nil` means unknown, so the drone looks — one hop across the bay. A stale `{}` means *definite*, so it
never looks again. Measured twice: a drone holding 828 fuel logging "12 of 12 chests are known not to
hold it" with 64 coal sitting in the pickup chest. The first fix kept a fallback to the last drone
report for chests off the network, and the bug came straight back through it, because six of twelve
deposit points have no peripheral name. Live read or nothing.

**A gather approaches its target from ONE face, and the face decides what it can reach.** Every
approach aimed at `t.y + 1` and dug down — correct for ore in a shaft, and unable to touch a tree
ever. A canopy log has leaves above; a trunk log has more trunk above and dirt below. Only the sides
are open. 52% of indexed wood sits at trunk height, 45% canopy — approaching vertically wrote off the
entire forest, which is why coal at y=40 worked and wood never once did. The inspect and the dig must
follow the face actually taken, or the drone reads one block and breaks another.

## Environment invariants

- **Wired modems need BOTH blockstates: `modem=true` AND `peripheral=true`.** For weeks this was
  written down here as an unfixable invariant — "a modem only attaches when right-clicked, and
  `setblock` cannot right-click" — and the entire fleet was redesigned around it: a deposit
  ledger instead of real stock, drones wrapping chests by hand, `Provide` permanently broken, and
  smelting impossible because a furnace could never join the network. **It was never true.**
  `peripheral` is an ordinary blockstate; setting it attaches the inventory for real, and
  `storage.stock` went from "0 chests (ledger)" to "4 chests, 92 free slots (peripherals)"
  immediately. An "environment invariant" that nobody has re-tested is just an old assumption —
  `fleet.probe` and one `setblock` would have settled it at any point.
- **Stock is OBSERVED, not accounted.** Drones report the actual contents of the chest they are
  standing on (`ReportChest` — `StorageMan.ChestContents`). The delta ledger that preceded it drifted
  the first time a report was missed — 22 logs withdrawn, craft failed, logs put back unreported,
  stock read zero while the chest held 22 — and the crafter was sent to the wrong chest for hours.
  Deltas cannot self-correct; a reading can. **Every path that writes to a chest must call
  `ReportChest`**, enforced by `lua-hygiene`. A chest wrongly recorded as empty is worse than an
  unknown one, because the fetch sweep skips it.
- **The bay is the most congested airspace in the settlement**, and a crafter has no pickaxe, so for
  it a blocked route is permanent. Prefer the container directly below to any flight: `FetchItems`
  reads it before looking anywhere else, and `Deposit` unloads into it before asking for a point.
  Three drones stacked in one column above a chest is normal, not a fault.
- **The operating region is a CIRCLE**, reach 56 from base, not the bounding box. The box's corners
  sit ~82 blocks from the mast against a 64-block modem range; two drones were permanently lost in
  them. Work targets must pass `withinReach()`.
- **GPS needs four audible hosts** and never reaches underground. Losing a fix underground is normal;
  `mayStep` accepts dead reckoning inside the region for exactly that reason.
- **CC kills any coroutine running >10s without yielding**, uncatchably. Long loops must yield.

## Conventions

**Comments explain why, and cite the failure.** This codebase's comments are its institutional
memory — `-- SAY WHICH HALF FAILED.` above a function that once returned a bare nil is worth more
than a description of what the code does. Do not add decorative comments; do explain a decision that
looks arbitrary.

**When a bug appears twice, the deliverable is a check, not just a fix.** `hq/test/lua-hygiene.test.ts`
fails the build on the patterns above. Exemptions need an inline justification:

```lua
-- lua-hygiene: allow (the thing below is a DRONE, verified on the line above)
```

Weakening a rule to make it pass is the wrong move; the rule is the cheap part.

**Prefer the primitive.** `TravelTo` / `ArriveAt` / `FlyHome` for movement, `TakeFromChest` /
`PutDown` for inventory, `Resumable(d)` for anything iterative, `SameItem` for item matching, and
`FetchItems` for "go get these materials". Each
exists because the same logic was written four times and each copy relearned the same trap in
production.

**Partial progress beats waiting for the full order.** `FetchItems(want, min)` stops once it holds
enough to be useful and the caller scales down — a craft short of the full order makes what it can.
The alternative is what actually happened: a crafter holding 6 of 8 logs blind-sweeping a busy bay
for two logs that did not exist anywhere.

## When something looks stuck

1. `hive.plan` — the queue as a dependency tree with the reason each task is blocked. This answers
   "why is nothing happening" better than anything else.
2. `hive.nodes` — module reachability. A busy module gets one retry before being called dead.
3. `fleet.status` — includes `detail` (what the job is) and `carrying` (what it holds). Stock inside
   a drone is invisible to planning; `storage.recall` and `fleet.handover` move it.
4. The drone's own `drone.log`.

Fix upstream first. Hours went into gather, deposit, fuel and rescue while `storage.stock` reported
0 items forever — which made every supply decision garbage. When a foundational number looks
impossible, chase that before anything downstream.
