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
