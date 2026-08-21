# Building a city with turtles — how this should be structured

Written 2026-08-21. The goal is a procedural settlement the fleet builds and runs itself. This
describes how to get there in a way that survives being extended, and is grounded in three things
that actually broke today rather than in taste.

## The three failures that define the design

**1. The world model outgrew the machine holding it.** `blockDataDetail` reached 866 KB of
serialised Lua. An in-world computer cannot load it, so `cachedWorldDetail` is empty and every
name query — "where is dirt", "where is iron" — returns zero. The 57 KB occupancy grid still
loads, which is exactly why `world.caves` works and `world.find` does not. This is not a bug to
patch; it is a ceiling, and the survey only grows.

**2. Nothing knows where anything belongs.** There is no zoning, no plots, no reservations. Orders
carry raw coordinates and drones execute them. That is how a monitor wall got built on top of D1
and destroyed it. Every future farm, smelter and factory is one careless coordinate away from the
same outcome.

**3. Nothing knows what anything costs.** There is no recipe graph. "Build a chest" cannot expand
into "need planks, need logs, need a lumber job", so every step has to be ordered by hand. A system
that must be told each step is not autonomous, however good its individual jobs are.

## The layering

The boundary that matters is **what holds state and makes decisions** versus **what acts**.

### L1 — World and Plan. Out of world, in HQ.

Owns the map, the city plan, the recipe graph, and the job queue. No memory ceiling, testable
without a Minecraft server, and version-controlled. This is what `hq/` was always for.

- **World model** — occupancy plus block names, fed by scout uploads. Queries (ore, dirt, caves,
  coverage) run here.
- **City plan** — the plot registry, below.
- **Recipe graph** — what a thing needs, transitively.
- **Planner** — turns a goal ("a tree farm") into ordered jobs.

In-world keeps only its **working set**: current tasks, the drone registry, the storage index. When
a drone needs to know whether a cell is solid, it asks for the cells it is about to move through,
not for the world.

### L2 — Coordination. In world.

MainFrame, TaskMan, DroneMan, DockingMan, StorageMan. They execute decisions and own things that
must survive HQ being down: docking, fuel, the storage index, abort. **They must keep working with
no HQ** — a settlement that stops when a Docker container restarts is not autonomous either.

### L3 — Actuation. Drones.

Job verbs — `Dig` `Lumber` `Farm` `Build` `Haul` `Survey` `Scan` `Rescue` — plus local safety:
bounds, fuel reserve, stuck detection, resume-after-update. Drones stay dumb on purpose.

## The keystone: a plot registry

This is the missing piece, and almost everything else gets easier once it exists.

```
plot = {
  name    = "farm-01",
  purpose = "farm" | "forestry" | "mine_head" | "smelting" | "storage"
          | "docks" | "power" | "reserved",
  min, max,            -- inclusive bounds
  ground,              -- y of the working surface
  status  = "planned" | "clearing" | "active",
  owner,               -- task or module responsible
}
```

Two rules carry the whole idea:

1. **Every build or dig order must name a plot**, and TaskMan rejects an order whose bounds leave
   that plot or overlap another. Collisions become impossible by construction rather than by care.
2. **Plots are allocated by HQ from a growth grid** around the base — a street pattern, sized per
   purpose. That is what makes the city *procedural*: expansion is "allocate the next plot of type
   X", not a human picking coordinates.

It also gives siting rules a place to live: forestry needs sky and dirt, mine heads want to be near
ore, smelting wants to be near storage, docks want to be central and reachable.

## The recipe graph

Declarative, in HQ, so the planner can expand goals:

```
chest        <- 8 planks
planks       <- 1 log        (yields 4)
crafting_tbl <- 4 planks
torch        <- 1 stick + 1 coal
```

`ensure(chest, 4)` then becomes: check storage, expand the deficit, emit a `Lumber` job for the
logs, a craft job for the planks, and a craft job for the chests — in order, with dependencies. This
is the difference between a fleet that executes orders and one that pursues goals.

## The growth loop

The autonomy is one loop in HQ:

1. Compare stock and infrastructure against targets.
2. For each deficit, expand it through the recipe graph into concrete jobs.
3. Allocate or reuse a plot for anything that needs ground.
4. Dispatch by role; drones already self-assign from hardware.
5. Verify against the world model; re-plan what did not happen.

Every step above already exists in some form except the plot registry and the recipe graph.

## Where this actually starts, given a desert

The base is in a desert: no wood, no dirt, no grass within the surveyed world, and map bounds stop
165 blocks short of the nearest savanna. So the order is forced.

1. **Plot registry.** Cheap, pure data, stops the base becoming a mess, and is a prerequisite for
   siting anything. Nothing physical needed.
2. **Move the world model to HQ.** Already forced by the 866 KB ceiling. Scouts upload; HQ answers
   queries; in-world keeps a working set.
3. **A real mine.** Replace box-quarrying with a shaft and branch tunnels from a `mine_head` plot.
   This is also how dirt and ore get found — and dirt is available locally, unlike wood.
4. **The wood expedition.** One trip to the savanna for saplings, needing extended bounds and the
   chunk loader escorting. The only step that cannot be done from home.
5. **Tree farm plot.** Dirt from (3), saplings from (4), `Lumber` already written. Wood becomes
   renewable and the expedition never repeats.
6. **Crafting.** A crafty turtle turning logs into planks, chests and tools — the fleet starts
   building its own infrastructure.
7. **Field caches and haulers.** Cheap once chests are free; miners stop commuting.
8. **Farms, bonemeal, power, factories.** Each is a plot purpose plus a job type, which is the
   point of the structure.

## What to resist

- **Do not put more state in world.** The 866 KB wall is the warning.
- **Do not add job verbs that know about geometry.** Jobs act; the planner decides where.
- **Do not let HQ become required.** In-world must degrade to "keep doing the last thing safely".
- **Do not skip the plot registry.** Every shortcut here is paid for later with a destroyed drone
  or a farm built through a smelter.
