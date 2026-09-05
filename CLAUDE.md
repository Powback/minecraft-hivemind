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
| `bin/` | Sync helpers; `fleet-watch.sh` polls `/brief` and prints fault changes |
| `hq/test/lua/` | The Lua, executed: `cc_stubs.lua` (a stub ComputerCraft world) and `run.lua` (behavioural tests run under Lua 5.4 by `hq/test/lua-behaviour.test.ts`) |
| `.luacheckrc` | luacheck config for `lua/`; gated by `hq/test/luacheck.test.ts`, baseline in `hq/luacheck-baseline.json` |
| `hq/scripts/*.mjs` | The ratchets' scanners (`complexity`, `adoption`, `duplication`, `silence`, `luacheck`); each takes `--update` to bank a win |

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

Run `cd hq && npx vitest run` before deploying anything. It includes the Lua guards, `luac -p` on
every file, and **luacheck** (`.luacheckrc` at the root; `brew install luacheck` -- the luarocks build
under Lua 5.5 cannot load itself). luacheck's W113 "accessing undefined variable" is zero tolerance:
it is the local-declared-below-its-use bug this file counts nine outages for, and its first run
found 29 of them that months of regex "guards" had not -- the GPS relay's position read in nine
places, a fly budget computed and then read out of scope, a bare `dig` that would have thrown the
moment a multi-miner dig was placed. Every other warning ratchets per file in
`hq/luacheck-baseline.json`; `node hq/scripts/luacheck.mjs --update` banks a win. A deliberate
runtime global goes in `read_globals`/`globals` in `.luacheckrc` with a reason, never a `local`
added to a file at the 200-local limit.

**A test that greps the source for a line is a comment with a CI bill.** Most of the older guards
here are that. They break on every rename while the behaviour stands, and pass when the behaviour is
wrong. The Lua is now RUN: `hq/test/lua/run.lua` loads each module under a stub ComputerCraft world
(`hq/test/lua/cc_stubs.lua`: a turtle with an inventory and fuel values, fake peripherals with
inventories, an in-memory `fs`, a `PowNet` whose replies the test chooses, a `pgps` that always knows
where it is) and calls the real functions -- "a drone with 400 fuel is not offered a 588-fuel job,
and the reason names the number". `hq/test/lua-behaviour.test.ts` runs it under **Lua 5.4** and turns
each result into a vitest case. Locals worth testing are exported by the module itself through the
`HiveMindTest` seam at its tail (nil in the world). To add a test: add a `test(...)` to `run.lua`;
if it needs a local, add it to that module's seam.

Lua 5.4 enforces the 200-local limit exactly; Cobalt in-game is more lenient. So the test runner is
the binding constraint on `DroneLogic.lua`'s main chunk, and it is why several helpers there are
globals (`TravelToBody`, `FellTargets`, `RelieveBody`, `BurnAboard`...) rather than `local function`.

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

**The cause was found and fixed.** `meshForward` relays a stranded drone's heartbeat from a
NEIGHBOUR's computer, and `OnHeartbeat` keyed the registry off the rednet sender -- so a relayed
beat wrote the ORIGINATOR's fuel, cargo, position and role into the RELAYER's record. The numbers
above were not stale; they belonged to a different drone. It went unseen for months because nothing
logged which computer wrote which record, and it was found only by adding that one line:

```
role: cc #47 -> record 4 (D4) scout -> crafter
role: cc #47 -> record 4 (D4) crafter -> scout
```

Same computer, same record, alternating -- one drone's own beat and a relayed one landing together.
The heartbeat now carries `ccid` and DroneMan believes it over the sender.

Keep verifying at the effect anyway: a heartbeat is periodic, so these fields still lag by up to an
interval, and a drone that cannot reach base still has an old one replayed. What should no longer
happen is a field belonging to somebody else.

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

### This is the #1 recurring defect here, and it is now COUNTED

Saying it was not enough -- it came back ten times in a single evening, always the same shape: a
success value produced by something other than the effect.

| what said "fine" | what was true |
|---|---|
| `redeploy.sh` printed `redeploy ok` | shipped to no drone; 17 of 20 ran stale code for hours |
| `OnBuild` / `OnLumber` returned a result table | the job had been aborted; TaskMan marked it 100% done |
| the build memo was marked | written on ARRIVAL, so aborts retired blocks nobody placed |
| `noteObservation` recorded a block | filed at a coordinate that had none -- the map filled with phantom structure |
| `task.stop` returned `ok: true` | 25 tasks kept being dispatched for another two hours |
| `positionVerified()` | answers "is the fix RECENT", not "is the position RIGHT" -- it logged zero refusals while blocks landed in the wrong places |
| `tooManyMissedStarts` | declared below its use: a nil global, so the filter was silently dead |
| `stopTasksNamed` reported `stopped 32 of 32` | it could only SEE 40 of the 131 tasks -- see the caps below |
| `saveSupply` persisted `towerLevel` correctly | `loadSupply` read a five-field whitelist and dropped it on every restart |

The individual bugs were cheap. What is expensive is that **a false success corrupts the
diagnosis** -- you measure the proxy, believe it, and spend hours fixing something that was never
broken. Three separate wrong causes were chased that night for exactly this reason.

**`hq/test/verify-at-effect.test.ts` now counts it.** Every tool marked `danger: 'mutate'` must
carry a `// verify-at-effect: <what it re-reads>` note, or sit in `hq/verify-baseline.json`. The
baseline may fall and may not rise, and a NEW mutating tool cannot ship without one. The note is
the mechanism: it forces whoever writes the tool to answer "how do I know it worked?"

`task.stop` is the worked example -- it re-reads the queue and reports `stopped` from whether the
task is actually gone, plus a `stillQueued` list naming the ones that are not.

**A CAP THE CALLER CANNOT SEE TURNS EVERY ANSWER INTO A SAMPLE.** Three separate size limits sit
between HQ and the queue, each of them correct on its own and none of them visible to the code
asking the question:

| where | limit | why it exists |
|---|---|---|
| `TaskMan.GetTasks` | 40 tasks | the reply must fit a 61,440-byte websocket frame |
| `fleet.tasks` | 60 live | same reason, one layer up |
| `task.stop` | 32 ids | schema `.max(32)` |

So a loop that read the queue, filtered by name and sent the ids back to be stopped saw 37 of 131
`tower-L0` patches, stopped what it could see, and reported complete success. Clearing a finished
floor's leftovers is the ONLY thing that lets the next floor be ordered, so the tower sat at level 0
behind a backlog that could not shrink while every log line said the clear had worked. The same cap
silently broke `task.stop`'s holder lookup, which searches `GetTasks` for the drone to release: for
any task outside the window it found nobody, released nothing, and still answered `stopped: true` --
leaving a drone executing a cancelled task for ever, which from outside looks like a dead fleet.

**The fix is never a bigger window.** "Which tasks are named like this" is a question about the
queue, and the queue lives in TaskMan -- `StopNamed` answers it there, where there is no gap between
deciding and acting, and reports what it actually marked. When a decision needs to see ALL of
something, do not ship the something to the decision; send the decision to it.

**A ROUND TRIP HAS TWO HALVES, AND FIXING ONE OF THEM FIXES NOTHING.** `saveSupply` wrote a
hand-picked subset, so fields added later were never persisted. That was found, fixed and given a
test -- and the tower still reset to the ground floor on every redeploy, because `loadSupply` read
five fields by name. `towerLevel` was written to disk perfectly and thrown away on the way back in:
`supply.json` holding `towerLevel: 2` with the running loop reporting 0. The test passed throughout,
because it only ever looked at the save. Persist everything and name the exclusions -- in BOTH
directions -- and when you check one direction, check the other in the same commit.

**A REMEMBERED BLOCK IS NOT A BLOCK.** The world map records what a drone once saw, and nothing
removes a record when the thing is gone -- so it drifts from the world in one direction only, and
every consumer of it inherits that drift as confident wrong answers.

Measured: `world.find oak_log` reported 767 trunks; spot-checking four found TWO already felled. The
lumber site picker does the right thing with that data -- it goes to the densest cluster -- and the
densest cluster was a grove cut down hours earlier. So every sweep flew to `-521,66,40`, where a
direct rcon query found ZERO logs, felled nothing, and honestly logged `JOB Lumber done`. Wood sat
at 0 for an entire session with 767 trees "known", the plank and chest chains starved behind it, and
nothing in any log said anything was wrong.

The same shape applies to ore: `gather: 1/768 checked, 0 taken` is the ore version of this, and it
was read as a pathing problem for a long time.

`world.forget <match>` clears the records so the fleet re-observes. Treat a persistent "job completes
but produces nothing" as a stale-map symptom before assuming the job is broken -- and prefer a
direct query of the world over the map when the two could disagree.

**The same rule applies to MEASUREMENT, not just code.** Three of that evening's wrong turns were
instrument error, not system faults:
- rapid-fire `rcon-cli` silently drops commands -- a known-present block read as absent. Space the
  calls and interleave a control that must return a HIT, or the scan is fiction.
- `built %d of %d blocks` is the value RETURNED to TaskMan; it is never written to the drone log.
  Grepping for it reported "0 completions" while 18 patches had completed. Grep `JOB Build done`.
- `fleet.tasks` returns a SUBSET of the queue. Purges built from it miss most of their targets;
  read TaskMan's own store when completeness matters. `task.countNamed` answers "how many of these
  are outstanding" in TaskMan itself, which is the only count worth acting on.
- **`drone.log` ROTATES.** Counting occurrences at two points in time and subtracting reported
  "5 aborts, then 0" -- a negative delta, from a drone that had not rebooted and whose clock had not
  reset. Any measurement that spans a rotation is fiction; anchor on timestamps in the file you are
  holding, not on counts taken minutes apart.
- **A handler that discards `p_ID` makes "who did this" unanswerable.** `OnAbort` logged that an
  abort had arrived and not who sent it, with five possible senders. Identifying one took an evening
  of eliminating candidates against four different log files, and the answer was in the message.

## Traps that have bitten repeatedly

**A `local` declared below a function that uses it is a nil global.** No error, no warning — the
branch is simply dead. This has caused nine separate outages, including one where `OnGoTo` called
`reachableTarget` 465 lines before its declaration, so *every* `GoTo` — and therefore every rescue —
threw on its first line for days while TaskMan logged successful dispatches.

**`x and nil or y` CANNOT PRODUCE nil — it is always `y`.** Lua's and/or is not a ternary: `x and nil`
is nil for every x, so the `or` branch always wins. Three modules independently wrote
`local s_Now = s_Ok and nil or tostring(s_Err)` after a `pcall`, and pcall's second return on
SUCCESS is the function's return value — so every healthy maintenance pass reported itself failed
with its return value as the reason (`FAILED -- 0`, `FAILED -- 1`, `FAILED -- nil`), once per change
of that value, for ever. The mechanism whose only job is to announce "a pass has silently died and a
whole class of recovery has stopped happening" had never worked in any of the three, and a real
failure was indistinguishable from routine operation. `lua-hygiene` now bans the shape outright —
there is no correct use of it — and the wrapper lives once, in `PowNet.WatchPass`.

**`DroneLogic.lua` sits at Lua's hard limit of 200 `local`s in the main chunk.** The 201st makes the
whole file refuse to compile -- and a drone that cannot compile its logic reboots into nothing, with
no log line. `hq/test/pownet-reply.test.ts` runs `luac -p` on every Lua file for exactly this. When
adding state or a helper at file level, nest it inside the one function that uses it, or spend a
global (the codebase's `function Name()` style); do not add a top-level `local` without removing one.

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

### EXTRACTING A HELPER IS NOT ADOPTING IT. THIS IS THE OTHER RECURRING DEFECT, AND IT IS NOW COUNTED.

The same shape, over and over, for ten days:

1. The same logic gets written in four places.
2. Somebody notices, extracts a helper, and writes a good comment explaining why.
3. **One** call site is converted. The others are left exactly as they were.
4. The comment now reads as if the problem is solved, so nobody looks again.
5. A bug is found and fixed — in whichever copy the reporter happened to be standing in.
6. The other copies keep the bug, and now they disagree with the helper too.

The comments in this repo are confessions of steps 1–4, written by people who had just done step 2
and believed they had finished:

| the comment said | what was actually true |
|---|---|
| `pgps`: "Exported name -> number, so callers stop writing their own copy" | three `if/elseif` ladders still answered it, in the module where a wrong heading strands drones |
| `core.ts`: "the same eight lines were written out three times" | `readStock` was written and **one of four** call sites adopted it — and the three survivors never got `luaList()`, so an object-shaped stock list threw inside their own `catch` and the planner concluded the settlement owned nothing |
| `DroneLogic`: "'unload here' is the same six lines in three places" | a fourth copy sat in `CollectFuel`, without the `ContainerBelow()` guard |
| `TaskMan`: "One function because this exact pcall was written out SEVEN times" | four call sites went on doing it by hand |

Step 5 is the expensive one and it is **invisible**: the fix looks complete, the tests pass, and the
copies fail later somewhere else looking like a brand-new bug. No amount of care prevents it —
the person fixing the bug has no way to know the other copies exist.

**`hq/test/adoption.test.ts` now asks the one question that has no judgement in it: does a named
function's body also appear somewhere else?** If it does, the extraction was never finished, and the
fix is never ambiguous — call the thing that already exists. `hq/adoption-baseline.json` may fall and
may not rise. `hq/test/duplication.test.ts` is the wider net (copy-paste that never had a helper),
and it counts **one-line** idioms too, because a block scanner structurally cannot see the shape that
turned out to be the worst offender: `math.abs(a-x) + math.abs(b-y) + math.abs(c-z)`, written out
**twenty-three times**, and it *is* the fuel budget.

**A CHECK THAT CANNOT FAIL IS NOT A CHECK, AND REFACTORING IS WHAT SILENTLY DISARMS THEM.** Folding
duplicated loops into helpers made `lua-hygiene`'s "bulk chest write must call `ReportChest`" rule
and `lua-traps`' peripheral-yield rule stop matching anything — both scanned for a literal call
(`PutDown(`, `peripheral.wrap`) that had just moved behind a new name. Neither failed. They went
**quiet**, which is worse: the wrap rule is what stops StorageMan being killed mid-scan, and it would
have been switched off by a commit that made the code better. So: when you extract something a guard
watches, teach the guard the new name in the same commit, and give the check a canary that proves it
still fires. `adoption.test.ts` runs its detector against a planted duplicate for exactly this reason.

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

## THE FUEL TRAP: the one state the settlement cannot leave

Every other failure here is recoverable. This one is not, and it is worth recognising early:

```
FUEL TRAP: all 4 miners dry, 0 burnable -- nothing can make fuel
```

Mining coal needs a fuelled drone. Felling wood needs a fuelled drone. Smelting charcoal needs fuel.
So once storage reaches zero burnable AND every drone is at zero, there is no sequence of actions the
settlement can take -- the graph of "what produces fuel" has no node that does not consume it first.
Reached on 2026-09-03 with six of seven drones at zero and the seventh at 350 and falling.

**It is approached gradually and looks fine the whole way down.** The fleet keeps working, jobs keep
completing, nothing errors. The signal is not a failure, it is a TREND: burnable in storage falling
while `felled 0 tree(s), 0 log(s)` and `gather: N/768 checked, 0 taken` repeat. Both of those read as
healthy completions.

What was fixed after the fact, and would have prevented it:
- lumber sweeps started at whatever log the map scored highest -- usually a CANOPY log -- so the
  drone walked above the trees inspecting air, and every sweep honestly reported felling nothing;
- fuel reliefs were queued on `storageFuelCount() ~= 0`, so one stray log kept the last mobile drones
  running deliveries that could collect nothing (`CollectFuel` needs 8 of an item to fetch it);
- `CollectFuel` fetched only coal and charcoal while the gate counted logs and wood as fuel;
- tower work was outranked by fuel work but still QUEUED, so a freed drone took a build and spent
  its last fuel laying blocks. Ranking is not enough -- the work has to be unavailable.

**Recovery requires putting burnable material in a chest by hand.** There is no in-system path, and
that is worth saying plainly rather than discovering it again: `FUEL_STRANDING_RISK` and
`FuelFloorNow`'s dry-storage collapse are both designed to keep drones WORKING through a shortage,
which is right until the shortage is total and then keeps them working to zero.

### Where the fuel actually went (measured against the world, 2026-09-03)

Three hand-fed loads of 192 coal each vanished within the hour, and every log line said the fleet was
working. Read from the world -- `data get block` on the drones and chests, positions dumped every two
seconds -- the coal took four exits. Each is now a check in `hq/test/fuel-leaks-closed.test.ts`:

| exit | what it looked like | what it was |
|---|---|---|
| **three numbers for "full"** | coal reached a chest and was gone within minutes | `CollectFuel` topped up to 1,200 and left the rest; `TryRefuel` ran every 20 s with its own gate (4,000) and target (2,500) and sucked 96 items out of the chest below. Seven tanks × 2,500 had to fill before one lump could stay in storage |
| **the reliever ate the payload** | `JOB Relieve FAILED arrived but dropped nothing` | `carrying 28 fuel` … `refuelled +559` ×5 on the way. Every relief that reached its casualty had already burned what it brought |
| **pacing** | `DISTRESS: low fuel` every 30 s, fuel −20 each, nothing else logged | `moveLeg` compared each replan with the LAST one, so a two-cell bounce never tripped the stall counter and ran all 40 replans, one GetPath and one move each. Only a position trace showed it -- the log was silent |
| **the mesh fix threw** | `FAILED to adopt the meshed position -- pgps:2403` | `setLocation(x, y, z, nil)` did `string.lower(nil)`. Every underground recovery kept the position it had just been told was wrong |

And a fifth, in StorageMan: `WhereIs` answered from a drone's *remembered* observation before the
peripheral index it rescans for every other question, and sent D38 45 blocks to a chest that once held
coal while 64 coal sat two hops away. It died in the sweep. **A chest on the network is read, not
remembered.**

**The "ghost grove" was partly instrument error.** The paragraph above about `-521,66,40` holding
zero logs was written from rapid-fire `rcon-cli` reads with no control. Re-checked with
`execute if block` and a chest as the control, nine of nine "phantom" trunk positions were oak_log.
What had happened was smaller and worse: earlier passes cut the bottom logs and left the trunks
FLOATING (air at y64-66, logs at y67-70), and the sweep inspected only FORWARD along one plane -- so
the drone dug its way into a trunk column on approach, stood with five logs over its head for all
sixty-four cells, and reported `felled 1 tree(s), 1 log(s)`. The sweep now checks overhead at every
cell and starts at the lowest foot in the window. Verify a "stale index" claim against the world
with a control before forgetting anything.

**Known hole: the tower judges a floor finished by "fewer than 8 bricks consumed since the last
batch".** A fleet that placed nothing because it was dry reads the same as a floor with nothing left
to place, and the level advanced to 1 with 67 blocks on floor 0. Stale floors are now cleared before
the emergency gate and the level was reset by hand; the heuristic itself still cannot tell starved
from finished.

### The structural fix (2026-09-03, late)

After eight real leaks were closed one at a time and the loop still had not closed, the shape of the
problem was named: **nothing was verified against the world, and the fuel economy was assumed rather
than designed.** Four programs each kept their own fuel policy (about ten thresholds, none derived
from another), every layer reported success from its own intent, and the sweep hoped trunks would
cross its plane. What changed, and the rule each change encodes:

- **One floor, one authority.** `FuelFloorNow` is trip home plus a margin -- nothing else. Whether a
  drone can AFFORD a job is TaskMan's decision (`jobMinFuel`: work estimate plus margin, and
  `pickDrone` charges the round trip per block from where the candidate actually is). An idle drone
  that cannot afford a job is reported as exactly that, never as "busy".
- **The job is the trunks, not the square.** HQ sends the feet of the standing trunks it knows
  (`targets`); the drone approaches each from the side, climbs it, and records the ones that are
  gone so the index forgets them. The sweep is the fallback for a task with no targets.
- **Wood is furnace fuel of last resort.** Zero coal with logs on the shelf was a dead end: the
  furnaces would not start. Two logs smelt three into charcoal, and the loop bootstraps from wood.
  The crafting reserve on wood yields while fuel is short -- fuel before furniture.
- **The brief reports the economy.** `economy.ts` samples networked burnable, fleet fuel and blocks
  moved every minute; `/brief` carries income, burn and fuel per block over 20 minutes, and raises
  `NO INCOME` when drones work and nothing arrives. That is the fault the whole evening needed.

**Where things stood at the end of 2026-09-03.** Every mechanism above was verified once in the
world -- targeted felling (5, 9, 8 logs), wood-fired smelting (5 logs became 5 charcoal), relief
(three revivals in two minutes), planting (2 saplings on grove-01) -- and the settlement still
stranded overnight: 6 of 7 drones at zero, 377 fuel in the fleet, 0 burnable on the shelf, 26 logs
and 11 coal in a cache 45 blocks out that no drone could afford to fetch. Nothing has been built
since: tower level 0 with 67 blocks placed all day, 546 stone bricks and 121 cobblestone waiting,
`planks-01` and `charcoal-01` "running" with nothing to consume, 13 storage plots and the docks
"clearing" since they were planned, `crafting-01/02` and `grove-01` planned. **Base and factories
are not being built.** The economy is not fuel-positive at 1.2-2.8 fuel per block with trees 40-60
blocks out, and no amount of scheduler correctness changes that; the grove and the movement cost do.

**THE MONITOR IS A COMPOSE SERVICE NOW: `hive-fleet-watch`** (`hq/watch/`, `docker compose logs -f
fleet-watch`). `bin/fleet-watch.sh` run as a terminal background task died with the session at
03:38 on 2026-09-04 and nobody knew for ten hours; the service polls HQ on the compose network
and raises alarm-class faults in-game over RCON on the game server's network (`.env` holds the
password, gitignored). Two lessons from the same morning: `pkill -f` with a pattern that includes
the arguments misses the copies started with different arguments -- twelve fuel faucets were
running at once; and a script that fetches from INSIDE a container is right to say localhost.

**A DRONE THAT REPORTS BUSY AND DOES NOT MOVE IS NOT BUSY.** `OnGoTo` and `OnSurvey` set
`executing` without RunJob's `finish`; an early return left it set, the heartbeat reported "busy"
with a detail line from a job hours gone, every dispatch was refused, and TaskMan -- which only
reclaimed idle or fuel-less drones -- logged "reclaim? held by 58: busy" every 15 s for 44 minutes
with three drones docked. Both sides are fixed: `ClearStuckExecuting` clears a job-less flag after
300 game seconds without movement, and TaskMan's `heldForNothing` reclaims from a drone that has
not moved for three real minutes whatever it reports.

**THE REACH IS 60 (2026-09-04, 22:05).** Every tree inside 56 was gone; the nearest real trunks
(a 27-log column at -525,29 among 17 tall columns) stand 51-58 blocks out. `HIVE_REACH=60` in
`hq/docker-compose.yml`; HQ pushes it to MapServer at start and drones fetch bounds at boot, so a
reach change needs `redeploy.sh Drones` to reach the fleet (`pgps: coverage: ... reach 60` confirms).
The mast's radio is 64 at ground level; the two drones lost before were at 82.

**A DRONE THE BRIEF CALLS LOST WHILE ITS COMPUTER IS ON IS HUNG.** D37 sat 28 minutes at y=81 with
96 coal aboard, fuel 0, log stopped mid-deposit, computer on. `computercraft shutdown <id>` then
`turn-on <id>` brought it back in ten seconds (`turn-off` is not a command). The faucet does this
for any "lost" drone present in the dump. D35 is the other kind: `computercraft dump 52` says no
such computer -- it is in an unloaded chunk somewhere its last heartbeat did not say.

**WHY THE TOWER WAS SLOW (2026-09-04, 23:00), and the rules that came out of it:**
- **Fuel work outranks building, but not with the whole fleet.** `orderedTasks` puts every lumber
  and coal job ahead of every patch, and with wood perpetually short one is always queued, so all
  four miners felled and mined while the tower got one build an hour. Outside an emergency
  `FUEL_WORKERS_MAX = 2` miners take fuel work; the rest build (`notPlaceableNow`).
- **Scouts are the tower's fallback hands; caves wait while patches queue.** `surveyCaves` sent
  them underground instead, where D39 was walled in for an hour.
- **A cache is not storage.** Caches are where miners drop spoils so they keep mining; haulers bring
  them home, from anywhere in reach (the shaft is a route now that the dig flag works). A FETCH for
  materials searches networked chests only (`FetchSkip`); a build's fetch of 32 bricks had swept
  every deposit point of unknown contents, including the cache at the bottom of the mine shaft, 55
  blocks down, and nearly stranded. Forgetting caches to stop that was the wrong fix and was undone.
- **One pickup chest for six drones queues** ("access is occupied 6/6"); StorageMan spreads
  deposits by asker, so materials spread over chests with time.
- **Scouts haul.** A haul is any-role work and the any-role pick was "nearest free drone", so miners
  took hauls as often as scouts. `pickForTask` offers a haul to a free scout, then the crafter, then
  anyone (the user: "scouts can help haul").
- **A job stops itself at the floor.** The gather had no fuel check; the watchdog was the only stop,
  and its trip home from underground cost more than the floor allowed: D37 "JOB Gather INTERRUPTED
  (1004 fuel spent)" then "fuel at 0 (floor 342)" four times running. `GatherMayContinue` leaves
  when the tank is the trip home plus one approach, as `FellTargets` already did.

**A monitor that prints to a file is not a monitor.** `bin/fleet-watch.sh` logged 79 fault changes
that night -- `FUEL SPIRAL`, `OUT OF FUEL` for six drones -- into a background task file nobody was
reading, and the sentinel counted 20,059 "self-resolved" incidents. Neither reached a person. A
fault the operator cannot see from where they are (in the game, at the desk) has not been raised.

Three more, from the hour after (each with a check in `fuel-leaks-closed.test.ts`):

- **One coroutine moves the turtle at a time.** `TravelTo` is owned by the first coroutine to start
  a journey (`TravelOwner`); the fuel watchdog, dock loop and region-return loop are told "travel
  busy" instead of undoing each other's steps. D31's last minute alive was four targets in ten seconds.
- **A haul from a cache holding fuel is named `haul:<pos>:log`** so TaskMan's name-based fuel ranking
  puts it ahead of lumber. 26 logs and 11 coal sat 45 blocks away behind every lumber run.
- **Saplings get planted.** `plantForestry` allocates a `forestry` plot beside the bay and queues a
  `Plant` job (any role; from one above the ground, confirm soil, rise, place down). The distance term
  is the one the other fixes cannot touch: at 2.7 fuel per block, trees 40-60 blocks out can never
  be fuel-positive.
- Also: the deposit registry held every base chest twice (bound and unbound twins), so the unbound
  twin posed as a field cache and was hauled into itself; `dedupeDeposits` runs before both deposit
  answers. And the fetch minimum of 8 left 7 coal and 5 charcoal unfetchable by rule while a drone
  died two blocks from them -- it is 1 on both sides now.

Two measurement lessons from the same night. A drone log that shows only distress lines while fuel
falls is not idle -- **dump its position every two seconds**; the movement that costs fuel is the
movement nothing traces. And an ore gather is underground: no GPS, so no clears, so the index only
grows stale, and no relief can reach it. During a fuel emergency HQ now fells and does not mine.

**POSITION DRIFT WAS A RACE, NOT GPS NOISE (2026-09-04).** Logs were full of `position corrected
by 1-18` and `heading was W, we actually travelled E`, and a three-fix hysteresis was added to
"filter GPS jitter". Measured properly -- 12 `gps.locate` calls on each of three stationary drones,
a census of the hosts answering, and `computercraft dump` for the truth -- every fix was identical
and equal to the cache and to the server. GPS here is exact: 16 fixed hosts on a 44-block grid at
their true coordinates. The drift came from **two coroutines driving one turtle**:

- `refixLoop` took a fix while the travel coroutine was mid-leg. The hosts' distances were measured
  across a step, the cache had moved on, and the difference was adopted as a "correction" that put
  the bookkeeping behind the drone.
- A correction of 4+ called `ConfirmHeading`, whose probe is a raw `turtle.forward()`/`back()`. Under
  a traveller, the GPS delta it read was theirs plus its own, and the heading it "re-established"
  was whatever that sum pointed at. D54 was re-established to N, E, S and W in turn, 45 s apart,
  while flying straight; each wrong heading produced the next big drift, which produced the next
  probe. The `not executing` gate did not help: `executing` means a JOB is running, and docking,
  refuelling and flying home all move the drone outside one.

The rule, now in pgps, in two layers: **a fix or a heading probe during which anything else moved
the turtle is discarded**. `m_MoveSeq` catches a step that COMMITTED during the fix; `m_Moving`
(every move goes through `timedMove`, DroneLogic's raw probe brackets itself with
`holdFixes`/`releaseFixes`) catches one that was UNDER WAY -- `turtle.forward()` puts the turtle in
the next block at once and returns only when the eight-tick animation ends, so a fix in that
window reads one block of drift. The first layer alone left 18 corrections in ten minutes on one
drone; with both, the fleet logged **zero corrections, zero heading rotations and zero bookkeeping
disagreements in the next ten minutes**, against 41-90 before. `verifyPosition` returns
`nil, "moving"` / `nil, "moved during the fix"` with no back-off; the mover re-fixes between its own
steps. `ConfirmHeading`/`HeadingFromPeers` do nothing while `TravelIsBusy()`. The hysteresis is
gone. The earlier "six fixes read -496 ×4, -497 ×2 on a drone that had not moved" was taken on a
drone that WAS moving -- for a heading probe. Before calling any sensor noisy, measure it on
something that is provably still, against the world.

**A JOB'S APPROACH IS THE MOVEMENT NOTHING TRACES, AND IT MUST BE ABORTABLE AND BOUNDED.** With drift
gone, D35 still died at a leftover-canopy site: 433 fuel to zero in five minutes, no logs, one log
line. `ReachSite` fell through to `ApproachFromSide`, four sides times four movers against leaves,
none looking at the tank, none checking that the fuel watchdog had set `executing = false`; and
the loop held the travel lock, so the watchdog's own trip home was refused every 20 s until the
tank read zero. Now: a target is given up after 40 fuel (`approach: ... giving it up`), `ReachSite`
and `FellTargets` stop at an abort and `FellTargets` leaves targets it cannot afford on top of the
trip home, a miner digs the last stretch to a canopy target instead of bouncing on leaves, and the
watchdog repeats the abort (`AbortJobAndWait`) until the job lets go of the lock before it flies.
When a drone's fuel falls with one log line per minute, it is inside a loop like this one.

**WOOD INSIDE THE OPERATING CIRCLE IS EXHAUSTED (2026-09-04).** HQ's supply notes: "no standing
trees known -- 88 recorded log(s) are all leftover canopy". The densest wood left (48 logs in one
16-block cell) is 67 blocks from base, outside the 56-block circle; everything inside is single
leftover logs 37-57 blocks out. During a fuel emergency the lumber picker now harvests those
leftovers, several per trip (`chooseSweep(all, leftovers)`), and their canopies still drop
saplings. That is a bridge, not an economy: the settlement needs either the grove within a short
walk of the bay (`grove-01` sits 45 blocks from the chests because the plot spiral measures from
the tower, not the deposit point), a longer reach toward the forest, or both. Neither is a code
fix to make quietly.

**Four scheduler rules from the same night, each measured before it was written:**
- **A docked drone is a free drone.** Idle drones park and report `docking` for up to 90 s at a
  time; `pickDrone` asked for exactly `idle`, so "every crafter is busy (D4)" was logged every 15 s
  for an hour while D4 sat docked with 1,600 fuel (`FREE_STATES`).
- **A fuel emergency holds the miners' non-fuel work, not the crafter's.** Fuel is not transferable
  between tanks; holding the brick craft saved nothing for the felling and idled the only drone
  that could build.
- **Ask before flying.** `CollectFuel` asks StorageMan for burnable over the network before any
  flight; every earlier attempt flew to the chest that last held fuel and swept the bay, 14-59 fuel
  a time, at every job end.
- **In a fuel emergency HQ hauls only caches KNOWN to hold burnable, and the haul reports what it
  leaves.** A never-reported chest of stone 33 blocks out was hauled 64 at a time, trip after trip,
  by the scout carrying the fleet's last tank.
- **Work with no site costs no trip.** A craft has no position; `distTo(d, nil)` answered
  `math.huge`, so since the round-trip pricing landed no crafter could afford any craft -- "D4 has
  1252 fuel, the job needs an unknown amount" for every craft in the queue, all night. The `%d`
  crash on that very message had hidden it.
- **A fuel emergency holds the miners' non-fuel work, not everyone's; the tower pauses only while a
  miner could be felling; a failed craft does not hold the crafter out of building; the any-role
  build fallback prices the job like the first choice** (it did not, and sent a 384-fuel patch to
  scouts holding 290 and 270, who burned to the watchdog's floor).

**THE FUEL PROBLEM WAS A POLICY, NOT A SHORTAGE (2026-09-04, 02:00).** The index knows 1,143 coal
ore blocks -- 88 inside the circle at y 45-59, the nearest vein 10 blocks from the tower, about
90,000 fuel in total -- and `dispatchRule` refused EVERY ore during a fuel emergency, coal included,
because underground is where a drone cannot be rescued. The emergency never ended, so the only fuel
source the fleet was allowed was wood 50 blocks away at 15 fuel a log. Coal is fuel work now
(`oreWaitsForFuel`), and a fuel-ore gather is QUEUED even when no miner is free, because TaskMan
ranks it ahead of building and hands it to the next miner; waiting for a free miner at tick time
meant it was never queued while every miner laid bricks ("none known -> survey", with 1,143 known).
Lava is 1,000 fuel a bucket and the map has none indexed; that is the next fuel source to look for.

**THE PATHFINDER IS NOT THE PROBLEM; ASKING IT FOR A SOLID GOAL IS.** MapServer now tallies every
request once a minute (`paths: N asked, ok, failed [why], avg ms, worst ms`). Measured with seven
drones building: 23-104 requests a minute, 0-16 failures, EVERY failure "goal is solid", average
0-2 ms, worst 31 ms, no request over its node budget. "pathfinder did not answer" (19 in ten
minutes before) was PowNet's one-second reply window against a computer also indexing observation
uploads from seven drones; the window is six seconds now (`PATH_REPLY_S`) and the count went to
zero. What remains costs fuel: a caller that asks for a route INTO a brick it just placed, a chest
or leaves gets "goal is solid" and falls back to blind flight. Route to the free neighbour instead.

**THE SHELF KEEPS A RESERVE, AND A RELIEVER MAY BREAK IT.** Seven drones topping up to 1,600 took 173
of 227 coal off the shelf within a minute and re-triggered the emergency that paused the tower.
`CollectFuel` asks StorageMan how much burnable there is (`ShelfBurnable`) and a drone above its
floor leaves 192; a drone below its floor, or one fetching for a relief (`m_Relieving`), takes what
it needs -- the first ten minutes of the reserve left two drones dead behind "no fuel to deliver:
all of it reserve".

**THE DIG FLAG NEVER REACHED THE PLANNER (2026-09-04, 02:35).** pgps sends `dig` as `data[9]` of
GetPath; MapServer read `[7]` and `[8]` and called `a_star` without it, so the planner treated every
solid cell as a wall and refused any goal inside rock. Every `digTo` in the codebase failed at the
request, for as long as the flag has existed: a coal ore under five blocks of dirt cost 392 and then
1,584 fuel to *fail* to reach, every canopy log was "unreachable", and the mine shaft could never
have been dug. Two minutes after the fix D40 mined the first coal of the settlement's day. When a
capability "never works", read the handler that receives the request before the code that sends it.

**A REPLY WAIT MUST NOT EAT THE MAIL (2026-09-04, 03:20).** `PowNet.sendAndWaitForResponse` loops
`rednet.receive(protocol, timeout)`, and every message that was not the awaited reply -- another
drone's GetPath, an observation upload, a job report -- fell off the end of its if/elseif and was
gone. Every module and every drone does this, so a module waiting on a peer discarded the fleet's
requests for the length of the wait. It was invisible at a one-second window and became the whole
story at ten: path requests reaching MapServer fell from ~100 a minute to 1-3 while drones logged
"did not answer" 146 times in five minutes, uploads were "not taken" 203 times, and HQ's own
FindBlocks got "no response" -- with MapServer idle and answering every request it heard in 0-2 ms.
Held messages are now requeued as `rednet_message` events when the wait ends. When a service looks
overloaded, count what REACHES it before tuning what it does.

**TIMEOUTS ON THE COMPUTERS ARE GAME TIME.** `rednet.receive`'s timeout is a tick timer, so at
`/tick rate 200` a six-second reply window is 0.6 real seconds and "pathfinder did not answer" came
back (36 in ten minutes) while MapServer answered everything it heard in 0-2 ms. `PATH_REPLY_S` is
20 game seconds. HQ's timers are wall-clock and were halved instead (10 s tick, 30 s cooldown).

**SEVEN DRONES, ONE CHEST.** `pickDeposit` answered "the roomiest of the nearest" identically to
every asker at once, so the fleet queued over `-476,64,78` (27 "could not reach" in six minutes)
with five chests two blocks away. The asker's id now spreads the fleet over the roomy near chests.

**OVERNIGHT 2026-09-04 (03:40-13:55), UNATTENDED, WHAT BROKE:**
- **The shelf reserve deadlocked the fleet.** Drones at 150-300 fuel were refused the 172 coal on
  the shelf (below the 256 reserve) and were too low to mine more; the shelf never grew. A reserve
  must leave a drone a WORKING tank: `ShelfAllowance` hands out enough to reach 600, unlimited
  above the reserve, unlimited for survival and relief.
- **Leftover canopy only in an emergency meant no wood at all once the emergency ended.** No planks,
  no chests, storage could not expand, and 4,394 stone from the coal veins filled every bay chest to
  27/27. Lumber falls back to leftovers whenever oak_log is below its minimum.
- **The fuel faucet aimed at one chest.** That chest filled with stone; "added 0" for hours. It now
  counts and fills coal across the bay row.
- **Level 1 took 3,014 bricks for a ~2,200-brick floor and never advanced.** Every re-order queued
  every square; drones flew to squares others had filled to read "occupied"; some patch always
  consumed a brick, so "placed nothing" never held. `MapServer.BlocksSolid` now answers which squares
  already hold a block and `order.tower` queues only the rest; a floor with none left queues zero
  tasks, which is the advance condition.
- **D35 is LOST at y=27 in an unloaded chunk** (silent 31,000 s): a cave survey took it out of the
  force-loaded area and the computer stopped. Surveys and gathers must stay inside loaded chunks.

**A tower patch is 32 bricks, not 8, and a build pre-marks squares the shared map already has
solid.** A patch pays a shelf trip and a climb whatever its size; at 8 that was ~250 fuel per 8
bricks, and visiting a square another drone had filled to read "occupied" was a trip per square.

**A tower patch costs 36-910 fuel for eight bricks (avg ~250) -- 30 fuel a block.** That is the
next number to bring down: each patch fetches its own bricks from the bay and climbs to the floor;
22 patches in ten minutes cost ~5,000 fuel. Batching bricks for several patches per trip, and
routing to the free neighbour of a solid goal, are the two levers.

**Why the tower still had 67 blocks at 01:35.** With every gate above opened, three
builds ran and placed nothing: `short hop of 19 failed direct -- falling back to the map`,
`pathfinder did not answer -- MapServer may be overloaded` (136 times across the fleet that night),
`blocked by something unidentified at -480,64,64 -- asking it to move`. The tower's origin column IS
where idle drones park -- `docks-01` was never built, so "park on a dock" means the base of the
tower -- and by then two dead drones sat inside the footprint and one on top of the storage chest.
A builder cannot route into its own square, and a drone at 0 fuel cannot be asked to move. 295
tower patches were queued at once. Until the docks are built away from the footprint and the dead
drones are relieved, ordering the tower spends the last tank on replans. Stopped and dispatch
paused; D4 holds 905 fuel, the rest hold 117 and five zeros.

**THE WORLD RUNS AT 10x.** `/tick rate 200` (measured 2.3 ms per tick against a 5 ms budget on
2026-09-04). Everything on the in-world computers is game time -- `os.clock()` is ticks/20, so a
"45 s" refix interval is 4.5 real seconds and a log timestamp of 600 is one real minute after boot.
HQ is wall-clock: its supply tick is 10 s and its rule cooldown 30 s, chosen so it still takes
several turns per game-minute. Reading a drone log against a wall clock, divide by ten.

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

0. `/brief` → `economy`. Income (networked burnable over 20 min), burn (fleet tanks), fuel per block.
   If drones are "working" and income is 0, the brief says `NO INCOME` and nothing else matters until
   that does. `bin/fleet-watch.sh` prints the fault list as it changes.
1. `hive.plan` — the queue as a dependency tree with the reason each task is blocked. This answers
   "why is nothing happening" better than anything else. "no miner can afford it: D31 has 415, the
   job needs ~576" is TaskMan pricing the job; it is not a stuck drone.
2. `hive.nodes` — module reachability. A busy module gets one retry before being called dead.
3. `fleet.status` — includes `detail` (what the job is) and `carrying` (what it holds). Stock inside
   a drone is invisible to planning; `storage.recall` and `fleet.handover` move it.
4. The drone's own `drone.log`.

Fix upstream first. Hours went into gather, deposit, fuel and rescue while `storage.stock` reported
0 items forever — which made every supply decision garbage. When a foundational number looks
impossible, chase that before anything downstream.

## Why the tower was swiss cheese (2026-09-05)

Two facts multiplied. `PowGPSServer.a_star` charged a dug cell the same single step as open air --
the "dig weight" was the heuristic inflation, not a cost -- and `TravelToBody` asked for a DIGGING
plan first on every hop under 32 blocks (a leftover from when digTo went straight there without
the map). So every deposit, dock and patch trip around the base was planned as the shortest line
through whatever stood in the way, and the tower's floors and walls were what stood in the way.
The blind climbs (`ClimbToOpenAir`, `surfaceIfBuried`) cut straight up through floors as well.

Fixed without bans or zones (the user: "base is mutable, drones just shouldn't be careless"):
- `DIG_STEP_COST = 12` per dug cell in the planner (`STEP_COST` lookup), dig budget 5000 nodes.
- `TravelToBody`: open route first, ceiling retry, digging plan last.
- `RouteUpTo(x, y, ceiling, z)`: the map before any blind climb.
- `repairLowerFloors` (HQ): every 10 min each finished level is re-ordered; `order.tower` skips
  solid squares so only holes get queued. Patches BELOW the level counter are repairs, only
  patches above it are stale (`towerWorkFor`).
- `JitterWatch()` in the heartbeat: 16+ moves over <= 6 cells (or 40+ turns on <= 2) in 8
  heartbeats aborts the job / breaks the trip; three windows in a row raise a "jitter" distress.
  Counters come from `pgps.motionWindow()`.

Do not "fix" digging by protecting materials or fencing the footprint. The planner's price and the
order of asks are the controls.

## The loops of 2026-09-05, and what each one was

Every one was found by `JitterWatch` (heartbeat) and, from 00:43, by its "moved by <file:line>"
tally in pgps. Do not diagnose a bouncing drone from its position trail; read the JITTER line.

| what the user saw | cause | fix |
|---|---|---|
| tower floors shredded | planner priced a dug cell like air; TravelTo asked for a digging plan first under 32 blocks; straight hops (<=3) dug up/down/forward raw; blind climbs dug straight up | `DIG_STEP_COST` 12, open route first, straight hop never digs, `RouteUpTo` before any blind climb |
| D4 "stepping back and forth from the furnace" | chest full; idle loop deposited every 15 s, unloaded nothing | `NoteDepositOutcome` -> 10-min backoff |
| D39 move/turn/move/turn at a face | mid-job deposit unloaded nothing, returned true, mining loop went back to the face | `RoomAfterUnload` fails the deposit, job ends |
| D31 spinning at the bay, 0 moves | 0 fuel; every refused leg still turned to face it | `moveTo` refuses at 0 fuel before turning; `RefuelAtStorage` holds still |
| D38 patch "done" with nothing placed | job started while the heartbeat's fuel trip held the travel lock; 32 squares skipped as "another routine is moving" | `RunBodyWhenFree` waits/fails; `FailIfNothingReached`; top-up reports "refuelling" |
| crafter aborted mid-craft | jitter watch counted chest-hopping (6 cells) as a loop | crafting exempt, `maxCells` 4 |

Repairs: `repairLowerFloors` (HQ) re-orders every finished level every 10 min; lower-level patches
are repairs, not stale. Storage: HQ reuses the one pending storage plot and retired the 50 others;
`order.build chest-row` on it is what was missing.

The visualizer the user means is `~/Projects/McWebViewer` (http://mcwebviewer.pow), not HQ's
`/map`. Its bridge needs `MCWV_RCON_PASSWORD` in its `.env` equal to `rcon.password` in
`minecraft-create121/data/server.properties`, and `MCWV_FLUSH_ENABLE=1` or the map goes stale.

More of the same night, all named by the "moved by" tally:

| what | cause | fix |
|---|---|---|
| every idle drone bouncing over the bay chests, 200-400 moves/window | `TopUpWhileIdle` flew to the shelf each heartbeat; the shelf sat at exactly its reserve so `ShelfAllowance` gave nothing | `NoteTopUpOutcome` -> 5-min backoff; faucet target raised to 512 (above the 256 reserve) |
| a build "done" with nothing placed (chest-row with no chests; D38's 32 no-route squares) | skips counted as done | `FailIfNothingPlaced`; `NoteNoRoute` stops a walled-in build after 6 squares |
| relief "arrived but dropped nothing" | the casualty had 16 full slots | `MakeRoomBelow` sucks one stack out of the turtle below first |
| a dozen drones "lost" for a day | frozen in unloaded chunks 180 blocks out; scan region files for `computercraft:turtle` block entities (`ComputerId`) to find them | `forceload add` their chunk; `SeekHomeward` walks home by reckoning instead of a digging cross search |

Three drones (D31, D35, D40) are in no region file at all: destroyed, cause unknown.

The McWebViewer showed no bricks because its baked asset bundle predated them; it now has an
`mcwv-baker` service that re-bakes when the world gains a block type. Reload the tab after a bake.

## An edit that failed must stop the chain

A one-shot chain `edit; lint; tests; commit; deploy` committed a message describing edits the file
did not contain (efd6888, 2026-09-05): the edit script hit an anchor assertion and exited non-zero,
`;` let everything after it run, and the gate passed on the unchanged file. Chain with `&&` from the
edit step onward, and write the commit message after the edit has been confirmed, never before.

## Nothing completed for two hours (2026-09-05 01:00-03:00), and why

Measured from the drone logs: zero "JOB ... done" in two hours; 15 builds threw, 3 were
interrupted, 4 reliefs failed. Causes, in order of damage:

1. **Deploy cadence.** `redeploy.sh Drones` reboots the fleet and kills every job in flight. It
   ran ~15 times in two hours. Batch fixes; deploy drones at most once an hour while measuring.
2. **A full shelf starves everything.** Builds fetched partial bricks and threw "ran out partway";
   the crafter could not craft ("cannot clear slot -- no container"); lumber sat "no miner free"
   while both miners laid bricks; no logs -> no planks -> no chests -> no new row -> shelf still
   full. Fixes: crafts keep surplus in non-grid slots (`ClearGridForCraft`), miners take builds
   only when no lumber/gather waits (`economyWaiting`), the storage chain is exempt from the
   full-shelf gate (`makesStorage`) and TaskMan serves it first (`storageRank`) when free slots
   <= 6, HQ keeps 128 stone bricks in stock.
3. **The jitter watch tuned too tight** (12 moves/4 cells per game-minute) aborted normal chest
   work. Now 40 moves/4 cells or 60 moves in a 10-block box; crafting exempt.
4. **Two coroutines driving one turtle** (heading probe vs mover) lost quarter-turns -> zig-zags.
   pgps has a drive lock at moveLeg/ensureHeading/timedMove/turnAndTrack (`driving`, `isDriving`).

Measure completions, not deploys: `grep -o 'JOB [A-Za-z]* \(done\|FAILED\|THREW\)' */drone.log`.

## Crafting facts that cost a night (2026-09-05)

- `turtle.craft()` refuses ("No matching recipes") when ANY slot outside the 3x3 grid (4, 8, 12-16)
  holds an item. Surplus cannot be parked aboard; it must go into a container. `StowCargoForCraft`
  deposits the crafter's cargo before it fetches inputs; `ClearGridForCraft` puts surplus below.
- A crafter that also hauls arrives at the craft with twelve stacks of stone. TaskMan gives hauls
  to the crafter only when no craft waits (`crafterFreeOfCrafts`).
- A craft whose inputs are not on the shelf is held by TaskMan (`craftShortIn`, from the GetStock
  reply cached in `m_StockCounts`) instead of flown thirty times to find nothing.
- StorageMan's WhereIs rotates across holders and never names a furnace while a chest holds the
  item (`pickHolder`): five drones were queuing over one access cell.
- A full shelf never gates the storage chain (logs, planks, chests) -- HQ `makesStorage`, TaskMan
  `storageRank` -- because that chain is the only way out of a full shelf.

## Floor 0's holes, measured against the world (2026-09-05 15:00)

Compare the design (`towerFloor(specForLevel(l), l, PALETTES.brick)` at base -480,63,64) with the
region files, not the map (scratchpad scripts dump-l0.ts / check-map.ts, using McWebViewer's
region reader). Floor 0: 1677 of 2360 built; of the 683 missing, 254 have air above (plain
buildable), 231 sit under a stone brick, 160 under cobblestone from the first cobble-palette
build, and 7 under the GPS-host computers. Floors 1 and 2: 333 and 221 of their missing squares are
under a brick. A square under a block was "no route to the square" for ever from above, and six in a
row tripped "walled in", so the reachable squares in the same patch were never laid either.
`LayCovered` lays such squares from a neighbour cell at their own height (`turtle.place` facing the
gap) or from below (`turtle.placeUp`); stairs keep their heading rule.

HQ's "already built" filter (`squaresAlreadySolid`) agreed with the world within 1% -- the map is
not the problem; reachability was.

## Builds get materials by handover, and the handover needs room (2026-09-05 15:20)

`OnBuild` asks StorageMan `Provide`; StorageMan pushes items from every chest into ONE pickup
chest and the drone collects there. With the shelf at 0 free slots every push moved nothing, the
reply came back `short`, the build "placed what arrived" and threw "ran out of stone_bricks" -- 11
times in 20 minutes with 119 bricks on the shelf. Now `pickupFor` makes the chest that already
holds the most of the first item the pickup point (no push for the bulk), and a build short of one
material skips those squares (`noteSkip "short of X"`) instead of aborting the patch.

Measure floors from the region files, not the map: scratchpad `dump-l0.ts` + `check-map.ts`.

## "goal is solid" was the only pathfinder failure left (2026-09-05 15:40)

MapServer's per-minute tally showed 7-9 failures a minute, all "goal is solid": the mover was
being asked for cells that hold a block. Two senders: builds aiming at the cell above a covered
square (now `LayCovered`), and `RunJobNow`'s `ReachSite(pos)` for Lumber, whose `pos` is the
densest trunk itself -- the cell above it is wood or leaves. Lumber runs with `travel = false`
now and `FellTargets` approaches each trunk from the side. When a job dies "cannot reach site",
check what the site cell holds before blaming the planner.

## Afternoon of 2026-09-05: what moved floor 0 at last

Measured 15:19 -> 15:44: floor 0 +43 squares, floor 1 +18 -- the first movement all day -- after
`LayCovered` (side/below placement) and `pickupFor` (handover from the chest that holds the item).
Then two more blockers fell: the build resume memo trusted over the map (`DoneAndSolid`), and a
fetch keeping whole stacks (a 4-log craft withdrew 200 logs: `TakeFromChest(p_Want, p_Cap)`,
`KeepUpTo`). The user authorised wood: 256 oak logs and 8 chests were put on the shelf in place of
stone so the chest row could exist at all. HIVE_REACH is 72 because the nearest standing oak is 63
blocks out.
