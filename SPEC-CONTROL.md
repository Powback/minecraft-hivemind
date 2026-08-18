# PowCommand — an RTS control surface for Minecraft

Status: draft spec, nothing built yet.
Companion to `SPEC.md` (the HiveMind drone brain). This document covers only the
*control surface*: how a human on a phone drives both their own character and the
drone fleet.

---

## 1. The problem, stated precisely

Minecraft binds **aim**, **camera** and **selection** to one crosshair at screen
centre. One point does three jobs. That is workable with a mouse — the mouse is
fast and precise enough to timeshare — and it is miserable on touch, where you
have neither precision nor a spare hand.

The instinct is to fix the joystick. That is treating the symptom. Retuning
deadzones does not decouple three responsibilities from one point.

**Non-goal:** replacing first-person. Mouse and keyboard keep working exactly as
they do now. This is an alternate control mode, toggleable, not a fork.

---

## 2. The core idea

> One cursor. Selection-based. **You are unit #0.**

Every interaction is *select a unit, issue an order*. Your own body is simply the
unit selected by default. A drone is the same kind of thing with a different
executor behind it.

This is the whole design. Everything below follows from it.

The payoff is that the interaction grammar is written **once**. "Tap there to
move" means the same thing whether the selected unit is your character or a
turtle three chunks away. The player learns one verb set. So does the LLM in
`SPEC.md` — it emits the same orders through `/invoke` that the human emits by
tapping, which means the agent and the human are provably driving the same
machine rather than two lookalike ones that drift apart.

---

## 3. Interaction model

### 3.1 The cursor

A screen-space pointer, **decoupled from camera centre**. Camera and target are
independent, so you can look one way and act another — the single biggest win
over the crosshair.

**The finger is the cursor.** Interaction is press → drag → release:

1. **Press** — cursor appears under the finger; path preview and target
   highlight render immediately.
2. **Drag** — adjust; preview updates live.
3. **Release** — commit the order.

This deliberately replaces an earlier design in which the cursor was a persistent
pointer you dragged and then tapped with. That is a *mouse* metaphor: it costs
two interactions per order and assumes a second hand steadying the device. Press-
drag-release is one finger, and it recovers the hover-preview affordance that
touch normally cannot express — which is precisely what stops a mistap becoming a
walk into lava.

The cursor raycasts into the world and continuously reports a **hover target**:

| hover target | what it is |
|---|---|
| `Ground(BlockPos)`   | a walkable surface |
| `Block(BlockPos, Direction)` | a solid block and the face under the cursor |
| `Entity(id)`         | mob, player, or drone |
| `Nothing`            | sky / out of range |

### 3.2 Selection

- **Tap a unit** → select it (replaces selection).
- **Drag a box** → select all friendly units inside.
- **Tap empty ground with nothing under cursor** → deselect, falling back to self.
- Default and fallback selection is always **self**, so the game is never in a
  state where a tap does nothing.

### 3.3 Orders

Tap with a selection active. The verb is **inferred from the hover target**, with
an explicit override available (§3.4):

| hover target | inferred verb |
|---|---|
| `Ground`             | `MOVE` |
| `Block` (breakable)  | `MINE` |
| `Block` (container)  | `USE` |
| `Entity` (hostile)   | `ATTACK` |
| `Entity` (friendly)  | `FOLLOW` |

**Tap-and-hold appends** to the unit's order queue instead of replacing it. This
is the shift-click of RTS games and it is what makes the scheme feel deliberate
rather than twitchy.

### 3.4 Verb override

A small verb bar (`MOVE` / `MINE` / `PLACE` / `USE` / `ATTACK`). Selecting a verb
pins it until deselected. This kills the entire class of "I punched the chest"
and "I placed dirt on my own wall" errors, which exist *only* because vanilla
infers the verb from the held item.

### 3.5 Camera

Discrete presets — isometric, top-down, over-shoulder — cycled by button, with
two-finger drag to orbit and pinch to zoom. Free-look is a mouse affordance;
snap angles are a touch affordance.

### 3.6 Feedback

Non-negotiable, because tap-to-move without preview is how you walk into lava:

- **Path preview** drawn before commitment, on hover.
- **Target highlight** on the hovered block or entity.
- **Order markers** — ghost icons at each queued order, per unit.
- **Unit chips** along the screen edge; tap to select, showing health/fuel/state.

---

### 3.7 One-handed play is a hard requirement

The target posture is **one thumb, standing on a bus, interrupted constantly**.
This is a constraint on the design, not a nice-to-have, and it settles several
questions that would otherwise be matters of taste:

- **Every gesture has a one-finger path.** Two-finger orbit and pinch-zoom are
  *enhancements only*; orbit and zoom must also exist as buttons. (The Amethyst
  multi-touch risk in §7 may force this regardless, so it costs nothing.)
- **All interactive UI lives in the bottom third**, inside a thumb's reach arc:
  verb bar, unit chips, camera cycle, and above all `HALT`. Anything a panicking
  user needs must be reachable without regripping the phone.
- **Being interrupted must be safe.** Queued orders and autonomous drones mean
  putting the phone down mid-task is legitimate. This is the single biggest
  advantage of a selection-and-order scheme over first-person, and it should not
  be squandered.
- **Standing orders for self.** Because the player *will* look away mid-fight,
  unit #0 needs default behaviour — auto-retreat below a health threshold, do not
  wander, do not chase. Combat is the one part of this scheme that genuinely
  does not survive a bus, and standing orders are the mitigation.

---

## 4. The order grammar

Shared by every unit. This is the contract between the UI, the player, and HQ.

```
MOVE   (pos)                  walk/fly to a position
MINE   (pos | region)         break block(s)
PLACE  (pos, item)            place a block
USE    (target)               right-click semantics
ATTACK (entityId)             engage until dead or halted
FOLLOW (unitId)               maintain distance to a unit
HALT   ()                     clear queue, stop now
```

Two executors, one grammar:

- **Self** → resolved client-side into ordinary movement/break/place packets.
  The server sees a normal player. No server mod, no protocol change, nothing
  to trip anti-cheat.
- **Drone** → serialised to HQ over the existing WS bridge, dispatched via
  PowNet. These map onto the tools already defined in `SPEC.md`.

`HALT` must be reachable in one tap at all times. Any system that queues orders
needs a panic button or it feels like driving a bus.

---

## 5. Locomotion

Vanilla's own A* — `PathFinder` + `WalkNodeEvaluator` over a
`PathNavigationRegion`. There is no reason to write a pathfinder; this is the one
every mob uses.

The API wants a `Mob` and the player is not one, so either drive the evaluator
directly or keep an invisible client-side donor mob purely to own the navigator.

Movement is then applied by **synthesising the same input fields the keyboard
writes**, tick by tick — *not* by teleporting. The server keeps receiving
ordinary movement packets.

**Known limits, and why they are acceptable here:**

| limit | consequence |
|---|---|
| No dig-through or bridge-across | routes around obstacles only; that is Baritone's job, not ours |
| Bounded search region (tens of blocks) | fine — you cannot tap past what you can see |
| Client-side, so render-distance bound | same reasoning |
| Conservative traversal (1-block steps, poor with ladders/water) | acceptable at v1; revisit if it grates |

Long journeys, if ever wanted, are a chain of waypoints — explicitly out of scope
for v1.

---

## 6. Phases

Each phase is independently useful and independently abandonable.

- **P0 — Spike.** Tap a block, path there with the vanilla finder, walk. No
  cursor, no camera work, no UI. *Sole question: does tap-to-move feel good?*
  If it does not, stop; nothing else can save the design.
- **P1 — Cursor + camera.** Decoupled pointer, hover targeting, path preview,
  camera presets.
- **P2 — Verbs + selection.** Verb bar, inferred verbs, radial hotbar, self-only.
- **P3 — Drones.** Unit chips, selection of turtles, orders over the HQ bridge.
  The point at which this stops being a control mod and becomes HiveMind's face.
- **P4 — Queues + regions.** Tap-and-hold queueing, drag-box region ops
  (`MINE`/`PLACE` over an area) emitted as ordinary packets.

---

## 7. Risks

**Touch input availability — this can sink the design.** Amethyst emulates a
mouse and keyboard for the game; a client mod sees GLFW mouse events, not raw
Android touches. Multi-touch gestures (two-finger orbit, pinch zoom) may simply
not be reachable from inside the mod. **Verify before P1**, because §3.5 assumes
them. Fallback: on-screen buttons for orbit/zoom, driven through Amethyst's own
`controlmap`.

**Amethyst's control overlay will fight the cursor.** Its default layout draws a
joystick and buttons over everything. Expect to ship a stripped custom
`controlmap` alongside the mod.

**Interaction-semantics mods overlap.** Better Combat already hooks attack
direction and targeting. §3.4's verb override and `ATTACK` need to cooperate with
it rather than both claiming the click.

**Feel is unfalsifiable in advance.** P0 exists precisely because no amount of
spec resolves whether this is fun. Build the smallest thing that answers it.

---

## 8. Open questions

1. Does the player character need a **stop distance** for `USE`/`MINE`, or does it
   path to touching range and then act?
2. Should drones render **selection outlines** through walls? (Almost certainly
   yes — they are usually behind something.)
3. Is `FOLLOW` on a drone a HiveMind order or a client-side leash?
4. Does the verb bar persist per-unit, or reset on selection change?
5. Is there a **fog of war** for drone orders — can you order a turtle to a place
   you have never seen? `SPEC.md`'s L0–L3 perception layers imply you should not.
