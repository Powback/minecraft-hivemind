---
name: autonomous-fleets
description: Hard-won rules for building and debugging autonomous robot fleets — ComputerCraft turtles specifically, but most of it applies to any swarm of unreliable agents with imperfect self-knowledge. Use when working on drone movement, positioning, task dispatch, or when a fleet "looks busy" but is achieving nothing.
---

# Running a fleet that lies to you

Every expensive failure in this system has had the same shape: **a component reporting sincerely,
and wrongly, about itself.** Not crashes — crashes are easy. A drone that says "closing the gap on
home" while flying away from it. A task list that says "assigned" for work nobody is doing. A fuel
gauge reading 41,234 when every drone that can move has zero.

The rules below are what that cost to learn. Each one is here because it was paid for.

---

## 1. Position and heading are different problems, and only one self-corrects

A wrong **position** is self-limiting. GPS fixes it the moment the drone is in range, and every
approach toward known ground improves the odds. Small errors wash out.

A wrong **heading** never self-corrects and gets worse on its own:

- Every successful move advances the cache by the *wrong* delta.
- Belief and reality separate at **twice** the distance travelled.
- The drone therefore moves *away* from the coverage that could correct it.
- Measured: a drone 118 blocks out in x — about 59 blocks flown backwards — logging progress the
  entire way. Another believed it was standing at home while sitting 121 blocks away.

**Failed moves are not the problem.** `forward()` correctly only advances the cache when
`turtle.forward()` returns true. A *successful* move on a wrong heading is locally
indistinguishable from a good one — that is what makes it invisible.

**Rule:** anything that repairs position must also question heading. Correcting where you are while
leaving which-way-you-face wrong just resets the counter on the same failure.

## 2. Audit intent against reality — it is free

Between two GPS fixes the drone knows what it *intended* to do (sum the deltas of its own moves) and
GPS says what it *actually* did. Comparing them:

- costs nothing — no probe, no fuel, no open space, no idle drone;
- fires on the **first fix after the first bad move**, not after drift accumulates;
- and when both vectors lie along one horizontal axis, the angle between them **is** the heading
  error, so it can be corrected outright by rotating the cached heading.

Compare **all three axes**. A first version compared x/z only, reasoning that vertical movement says
nothing about facing. True — and it made the check blind to the commonest disagreement there was,
because the error was in y.

The diagnostic that matters most: log when the audit *matches* but the fix still moved you. That
contradiction proves something is writing the position cache **outside** the move functions, and it
is the fastest way to find it.

## 3. Probes that move the turtle are a last resort

Deriving heading by stepping out, reading GPS, and stepping back is the obvious approach and it is a
trap:

- it costs two moves and needs open space and an idle drone, so it only runs in the recovery path a
  drifting drone struggles to reach;
- **`turtle.back()` must be checked.** Unchecked, anything behind the drone leaves it one block
  forward while believing it never moved. One block per occurrence, running constantly for a drone
  with no GPS. This produced 28- and 45-block errors before anyone noticed;
- it writes the position cache directly, so it corrupts the very thing the audit in §2 depends on.

Prefer passive inference. Keep the probe only for the genuinely ambiguous case, and never let it
write position without recording that it did.

## 4. A wrong fact is worse than no fact

Observations are keyed by the drone's *believed* position. An unverified drone teaches the map
terrain at coordinates it was never at — and because it believes it is inside the operating region,
the junk lands **inside** the region where no distance-based prune will ever find it.

What gave it away was height: flat layers of ~250 solid cells from y=96 to y=109, with **213 of 250
columns solid at both ends of that range**. Real hills taper. That was a slab of fiction hanging over
the settlement.

**Rule:** if you cannot say where you are, you do not get to say what is there. Gate observation
recording on a verified fix, at the choke point — not at each call site, where two of the callers
remembered and the rest did not.

Corollary: **a bad trilateration is worse than none.** A linear solver always returns *something*;
"it solved" and "it is right" are unrelated statements. Check the solution against the ranges it came
from and reject it if it misses. Before that check, one fix put a drone 239 blocks from where it
actually was — and that garbage was written straight into the map.

## 5. Prune surgically; measure before you wipe

When the map is polluted the instinct is to clear and re-survey. Read the data first. Here, 343,349
of 355,516 cells were good — a wipe would have destroyed days of survey to remove 3% junk.
Altitude-based pruning removed 28,397 cells and kept the rest.

## 6. Verify at the effect, never at the call

Tools return `ok: true` while doing nothing. Check the world, the log, or the state. This applies to
drones too: `status` is a claim. Movement and deliveries are observations. A drone that *claims* to
be working while it has neither moved nor delivered for minutes is the state every expensive failure
was in, and the only one reported status could never distinguish from progress.

## 7. Count the population that can actually act

The fuel threshold summed **every** drone on the books. Fuel inside an unreachable drone is not fuel
the fleet has. The loop read 41,234, concluded there was a comfortable reserve, and kept dispatching
dirt and copper while all eleven reachable drones ran dry — the exact death spiral the threshold
exists to prevent, entered through its own input.

Worse: those figures were stale heartbeats. One drone reported 3,339 while its own log said
`fuel at 0`. **Aggregates over stale, unreachable members are fiction.**

## 8. Fire-and-forget dispatch loses the refusal

`SendToDrone` does not wait, and the assignment was recorded regardless. A busy drone refuses
("JOB Build REFUSED: busy") and nothing hears it, so the task belongs to a drone that will never run
it. It cannot be swept up by a "release work held by idle drones" pass either — a drone that refused
*because it was busy* is by definition not idle.

**Rule:** a refusal is information. Send it back, and release the assignment on receipt. Add a
timeout-based release as the backstop, not the primary mechanism.

## 9. Order matters when phases return early

A rule placed after two phases that `return` the moment they do anything will effectively never run.
Storage expansion sat behind a queue top-up that fires almost every tick — so the one rule that could
unjam the settlement was permanently preempted, and storage sat at 0 free slots with ten drones idle.

This is invisible from outside: there is no way to observe "would have run". Pin the ordering with a
test that reads source order, because that is the only place the fact exists.

Related: **read shared state before any phase that mutates it.** The queue was read halfway down, so
earlier phases had to guard themselves with timers instead of facts — and a timer expires while the
previous build is still running, which is how five duplicate builds got queued for one shortage.

## 10. Never queue work that cannot succeed

A drone blocked by something it cannot dig queued a priority-1 "clear this" task. The blocker was
often another drone, or protected infrastructure — including, in one case, **a standing request to
dig the Bridge computer**. A miner arrives, correctly refuses, and the task can neither complete nor
fail. Eighteen accumulated, outranking everything real, and the queue looked fully staffed.

Check against the same modular "never dig this" list every other component uses. A second copy of
that list will be wrong the first time somebody adds a machine to one and not the other.

## 11. Deadlocks that need X to get X

Watch for these; they do not resolve on their own:

| deadlock | shape |
|---|---|
| Fuel | mining coal needs a fuelled drone; fuelling needs coal |
| Storage | depositing needs a free slot; freeing slots needs to deposit |
| Bootstrap infra | a furnace on the network needs a modem; a modem needs smelted stone |

A drone at 0 fuel **can still dig, turn, suck and craft** — it just cannot move. So putting fuel in a
chest it must fly to is useless; the fuel has to go where the drone already is. (A turtle is a
container: `item replace block <x> <y> <z> container.<slot>` works. Use an explicit ID allowlist so a
module computer can never be hit by it.)

Breaking these requires a deliberate one-time injection. That is not cheating — it is a bootstrap.
Cheating is doing it *routinely* instead of building the loop that makes it unnecessary.

## 12. CC:T specifics that cost hours

- **`os.sleep(0)` is a tick, not a yield.** It is `startTimer(0)` + `pullEvent`, and a zero-delay
  timer does not fire until the next game tick — 50ms of doing nothing. As a periodic yield inside a
  loop over a large structure it dominates everything: an A\* yielding every 200 nodes spent **five
  seconds waiting** per exhausted search, serialised across the fleet. Use
  `os.queueEvent(tag)` + `os.pullEvent(tag)`, which satisfies the watchdog (it wants a *yield*, not a
  delay) and resumes in the same tick. Map parse: **49s → 3.65s**.
- **A `local` declared below a function that uses it is a nil global.** No error, no warning — the
  branch is simply dead. This has caused nine separate outages here. Enforce it with a lint rule; it
  caught three more of mine while writing these fixes.
- **`computercraft shutdown` skips the module's exit save.** Queued work added since the last
  persist is lost. Do not redeploy a module immediately after queueing work into it.
- **Undeclared params are dropped silently** by the message layer. An unlisted field does not error —
  it never arrives, and the handler runs with it nil while the caller believes it was honoured.
- **Rebooting the fleet is not free.** Every reboot puts every drone through simultaneous
  re-registration into a single-threaded registry, burns fuel on re-pathing, and interrupts
  in-progress work. Four reboots in forty minutes generated the contention I was trying to diagnose.

## 13. Protect the debugging surface

The drone log is the primary debugging surface. Things that destroy it:

- **Dumping a payload into it.** One build task carries 192 blocks and printed **42KB on a single
  line**; the log is capped at 96KB and deleted when it exceeds that. The line describing the job
  wiped every line explaining what happened next. Cap it — 200 characters identifies a job.
- **Diagnostics that only `print()`.** In CC that goes to the turtle's screen and nowhere else. The
  movement module had 29 of them and no logging at all — including `position corrected by 90`, which
  names the bug outright and was being written where only somebody standing in the world could read
  it.
- **Replies that exceed the frame limit.** A task list carrying full work payloads hit 131,940 bytes
  against a 61,440 limit; `fleet.tasks` failed outright and the plan view silently returned nothing.
  Truncate long arrays generically — *"192 blocks"* is what a dashboard wants, never the coordinates.

## 14. Complexity is a proxy for "nobody can hold this in their head"

Not an aesthetic. Every serious outage here happened inside the largest functions, for the same
reason each time: a branch nobody had the whole of in their head.

```
rescueNeeded    CC 83   sent healthy drones to rescue each other
supply tick     CC 169  the planner
OnStartTask     CC 50   dispatched ten duplicate gathers with no region
DepositNow      CC 59   looped for four hours without logging why
```

Ratchet it: a threshold for new code, existing debt recorded, and the baseline may only shrink. Three
things must fail — a file gaining an offender, an existing one getting worse, and **the baseline
claiming debt already paid**. That last one is the ratchet; without it, paying down one function
quietly frees budget for the next regression.

Measure **total excess branches**, not the count of offending functions. Counting functions punishes
the decomposition it exists to encourage: splitting a CC-169 monster into five CC-25 helpers looks
like a regression by count and is a 107-branch improvement in fact.

## 15. When a bug appears twice, ship a check

The fix is the cheap part. Rules that earned their place here:

- turtle moves must capture their result
- chest writes must report observed contents
- every `pgps.X()` referenced must exist
- one compass definition, one order (six copies existed; one had East and South swapped, in the
  module that assigns dock orientations)
- no `os.sleep(0)` as a loop yield
- diagnostics carrying computed values must reach the log
- nothing writes map state behind the verified-position gate
- primitives are called with the shapes they document

Verify the rule **fails when it should** before trusting it. Re-introduce the exact bug and watch it
break the build. A lint that never fires is worse than none.

---

## Debugging order when the fleet "looks busy" but achieves nothing

1. **Is anything actually working?** Count `working`/`hauling`, not queue length. A full queue of
   unresolvable tasks looks identical to a busy fleet.
2. **Do assignments match reality?** Cross-check assigned tasks against drone status. Tasks assigned
   to drones that never started them wedge both sides.
3. **Fuel — of the drones that can act.** Exclude lost and stale members.
4. **Storage free slots.** Everything ends in carrying something home; at zero, every downstream
   failure looks like its own fault.
5. **Module reachability**, and check `cachedAgeMs` before believing it. I built two wrong theories
   on a 64-second-stale cache.
6. **Only then** the drone logs.

Fix upstream first. Hours went into gather, deposit and rescue while stock reported 0 items forever —
which made every downstream decision garbage.

## Monitoring

Watch the failure modes, not the happy path. A monitor that greps only for success is silent through
a crashloop, and silence looks exactly like "still running".

For a fleet, the signals worth waking someone for are: **drones at zero fuel**, **coal below a
floor**, and **nobody working**. Position streams look informative and are not — they tell you drones
are moving, not that anything is being achieved.

And do not stop the monitor because it is noisy while the system is degrading. That is precisely when
it is doing its job.
