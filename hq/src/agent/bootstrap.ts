/**
 * THE BOOTSTRAP BENCHMARK: one miner, one scout, no chests, a tower out of its own shaft.
 *
 * The first thing a settlement does is the thing that tests every part of it at once: sink a shaft
 * under the tower centre, turn the cobblestone that comes out into the ground floor's walls, roof and
 * floor, then excavate the basement and line it. Two drones, no storage, nothing to hide behind. If
 * this needs a GPS correction, a rescue, or a person, the logic is wrong somewhere and this is where
 * it shows. The end-to-end time is the settlement's baseline number.
 *
 * ONE ACTION PER TICK, DRIVEN BY WHAT THE MINER CARRIES.
 *
 * There is no storage, so the miner IS the storage. The loop reads its inventory from DroneMan and
 * decides: enough cobble aboard -> place the next batch of the structure (exactly as many blocks as
 * it carries, so nothing is ordered that cannot be placed); otherwise -> dig the next chunk of the
 * next excavation. Excavations are ordered so the material arrives before the structure that needs
 * it (shaft, then the floor's interior, then the basement), and structures are gated on the
 * excavation they sit in (the floor slab waits for the interior to be cleared, the basement lining
 * for the basement to be dug). Chunks are sized to fit a turtle's free slots, so a dig never has to
 * unload -- there is nowhere to unload to.
 *
 * Everything is derived from settlement.base and the ring constants below. No coordinate is written
 * twice.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { z } from 'zod';
import { bridge } from '../bridge/ws.js';
import { registry } from '../tools/registry.js';
import { luaList, field } from '../lua-table.js';
import { settlement } from '../world/settlement.js';
import { towerFloor, specForLevel, discCells, TOWER_TOP, bayIsFlightPath, type Palette } from '../world/tower.js';
import { outfitBay, storageBayInterior, factoryBayInterior, trunkBlocks, riserBlocks } from '../world/bay.js';
import { rcon } from '../rcon.js';

const STATE_DIR = process.env.STATE_DIR ?? '/state';
const FILE = join(STATE_DIR, 'bootstrap.json');

/**
 * THE DESIGN'S TOWER, NOT A SKETCH OF ONE. Walls, floor and basement are exactly what tower.ts
 * generates for levels 0 and -1 (the user: "our proper tower walls"); the roof is level 1's slab.
 * Only the palette is narrowed: the bootstrap has cobblestone and nothing else, so glass windows,
 * stairs, the barrel and the parapet fence become cobblestone or are left for later floors.
 */
export const RING = {
  shaftHalf: 1,        // 3x3 shaft under the centre column
  shaftBottom: 8,      // absolute y the shaft stops at: deepslate starts at y8 and is not cobblestone
  shaftChunkLayers: 32,  // the miner unloads mid-job when full and returns to the face, so a chunk is two trips, not sixteen
  /** Blocks per excavation chunk: what a turtle can carry as stone without unloading (12 slots). */
  chunkCells: 350,
};
const COBBLE = 'minecraft:cobblestone';
const MIN_BUILD_BATCH = 24;     // fewer blocks aboard than this is not worth a placing trip
const MAX_BUILD_BATCH = 256;
const PREFIX = 'boot:';
// Queue depth follows the fleet: with five drones and two of each queued, D1 sat docked with 6,500
// fuel and nothing offered (2026-09-08). About half the miners dig, the rest build, one spare each.
let QUEUED_DIGS = 2;
let QUEUED_BUILDS = 2;
function sizeQueues(miners: number) {
  // Rock is the bottomless work source: keep all but two miners on it, the two cover builds, bays
  // and repairs. Half the fleet left three miners idle at every level's tail (2026-09-08 17:42).
  // Half the miners dig; "all but two" (2026-09-08 17:42) starved the lining builds instead: seven digs
  // held every miner and five of six basement-lining builds sat unassigned for an hour (2026-09-09).
  QUEUED_DIGS = Math.max(2, Math.ceil(miners / 2));
  QUEUED_BUILDS = Math.max(2, miners);
}

export interface Pt { x: number; y: number; z: number }
export interface Block { dx: number; dy: number; dz: number; item: string }
export interface Box { min: Pt; max: Pt }
/** One dig task: a list of boxes (rows of a disc) worked in order, or a single box. */
export interface DigChunk { name: string; boxes: Box[]; stage: Stage; cells: number }
export type Stage = 'shaft' | 'walls' | 'roof' | 'floor-dig' | 'floor' | 'basement-dig' | 'basement' | 'quarry' | 'unbuild' | 'done';

/** A build block belongs to a stage; the stage says which excavation must be finished first. */
export interface StagedBlock extends Block {
  stage: Stage;
  /** Excavation chunk-name prefix this block waits for (deeper basements); level 0 uses GATE by stage. */
  needs?: string;
}

const spec0 = () => specForLevel(0);
const FLOOR_H = () => spec0().floorHeight;
/**
 * Generate with MARKER items and translate afterwards. In the cobble palette slab and wall are both
 * cobblestone, so classifying the generator's output by item lumped the whole slab into "walls"
 * (2,641 wall blocks for a 245-cell ring). The markers name the ROLE of each block; the bootstrap
 * then places cobblestone for every role it can.
 */
export const MARK: Palette = { name: 'mark', slab: 'slab', wall: 'wall', stair: 'stair', window: 'window',
                               shaft: 'parapet', barrel: 'barrel', pipe: null, needs: 'nothing' };
const pal = MARK;
/** What the bootstrap can place: cobblestone. Stairs and the barrel wait for a crafter. */
function cobbleOnly(b: Block): Block | null {
  if (b.item === pal.stair || b.item === pal.barrel) return null;
  return { dx: b.dx, dy: b.dy, dz: b.dz, item: COBBLE };
}
const isWall = (b: Block) => b.item === pal.wall || b.item === pal.window;
// The slab proper is the dy-0 plane; tower.ts also uses the slab material higher up (landings), which
// belongs to the storey's fit-out, not to the floor or the roof.
const isFloor = (b: Block) => (b.item === pal.slab && b.dy === 0) || b.item === pal.shaft;

/** Every block of the structure, in the order it is built. */
/** Inside the service cavity: between the inner skin and the outer ring. */
export function inCavity(b: { dx: number; dz: number }): boolean {
  const sp = spec0();
  const r = Math.hypot(b.dx, b.dz);
  return r > sp.radius - sp.serviceDepth - 0.5 && r < sp.radius - 0.5;
}
// Both plans are pure functions of the design and are asked for many times a tick (withStand once per
// block): with eight storeys they are ~40k blocks, so they are computed once.
let structCache: StagedBlock[] | null = null;
let excavCache: DigChunk[] | null = null;
let cacheDepth = -1;   // the basement depth the caches were computed for
/** How deep the plan currently goes: the base depth plus every level the loop has added (see growPlan). */
export function deepestBasement(): number { return DEEPEST_BASEMENT + (boot?.extraBasements ?? 0); }
function freshCaches() { if (cacheDepth !== deepestBasement()) { structCache = null; excavCache = null; cacheDepth = deepestBasement(); } }
export function structure(): StagedBlock[] {
  freshCaches();
  if (structCache) return structCache;
  structCache = structureUncached();
  return structCache;
}
function structureUncached(): StagedBlock[] {
  const out: StagedBlock[] = [];
  const H = FLOOR_H();
  const f0 = towerFloor(spec0(), 0, pal);
  const push = (bs: Block[], stage: Stage, dyShift: number) => {
    for (const b of bs) { const c = cobbleOnly(b); if (c) out.push({ ...c, dy: c.dy + dyShift, stage }); }
  };
  // Walls: the outer ring and the inner service skin, every course, doorway notch and slits as
  // the design has them (slits are cobble until there is glass).
  push(f0.filter(isWall).sort((a, b) => a.dy - b.dy), 'walls', 0);
  // Roof: the slab of the floor above, one storey up. The atrium stays open through it.
  const atrium = spec0().atriumRadius;
  // THE SERVICE CAVITY IS HOLLOW. No slab between the outer ring and the inner skin, on any level:
  // chutes and shafts run up inside it ("there shouldn't be any roof or floor in between the two
  // walls on the outside" -- the user, 2026-09-08).
  push(towerFloor(specForLevel(1), 1, pal).filter((b) => b.item === pal.slab && b.dy === 0
         && Math.hypot(b.dx, b.dz) > atrium && !inCavity(b)), 'roof', H);   // the atrium is open through every storey
  // Floor: the ground slab and the atrium parapet -- minus the slab squares a wall stands on. Those
  // are under cobble for good, reachable only by breaking the wall; a repair sweep skipped 74 of 75
  // such squares at ten seconds each (2026-09-08).
  const underWall = new Set(f0.filter((b) => isWall(b) && b.dy === 1).map((b) => `${b.dx}:${b.dz}`));
  push(f0.filter((b) => isFloor(b) && !(b.dy === 0 && underWall.has(`${b.dx}:${b.dz}`)) && !inCavity(b)), 'floor', 0);
  // Basement: level -1, one storey down -- its slab first (the builder stands on what it lays),
  // then its walls.
  const fm1 = towerFloor(specForLevel(-1), -1, pal);
  const underWallB = new Set(fm1.filter((b) => isWall(b) && b.dy === 1).map((b) => `${b.dx}:${b.dz}`));
  push(fm1.filter((b) => isFloor(b) && !(b.dy === 0 && underWallB.has(`${b.dx}:${b.dz}`)) && !inCavity(b)), 'basement', -H);
  push(fm1.filter(isWall).sort((a, b) => a.dy - b.dy), 'basement', -H);

  // ── THE GROWTH PLAN, appended (the benchmark's blocks above keep their order and indices) ──────
  // The fleet is never out of work: basement -2 (its volume is the quarry), then every storey up to
  // the design's top, then basement -3 ("why aren't we expanding the tower upwards layer by layer?"
  // -- the user, 2026-09-08). Each deeper basement waits for its own excavation (needs).
  const basement = (level: number, needs: string) => {
    const fm = towerFloor(specForLevel(level), level, pal);
    const uw = new Set(fm.filter((b) => isWall(b) && b.dy === 1).map((b) => `${b.dx}:${b.dz}`));
    const n0 = out.length;
    push(fm.filter((b) => isFloor(b) && !(b.dy === 0 && uw.has(`${b.dx}:${b.dz}`)) && !inCavity(b)), 'basement', level * H);
    push(fm.filter(isWall).sort((a, b) => a.dy - b.dy), 'basement', level * H);
    for (let i = n0; i < out.length; i++) out[i]!.needs = needs;
  };
  const storey = (level: number) => {
    const fl = towerFloor(specForLevel(level), level, pal);
    push(fl.filter(isWall).sort((a, b) => a.dy - b.dy), 'walls', level * H);
    const above = towerFloor(specForLevel(level + 1), level + 1, pal);
    const at = specForLevel(level + 1).atriumRadius;
    push(above.filter((b) => b.item === pal.slab && b.dy === 0 && Math.hypot(b.dx, b.dz) > at && !inCavity(b)), 'roof', (level + 1) * H);
  };
  basement(-2, 'quarry-L');
  for (let L = 1; L <= TOWER_TOP; L++) storey(L);
  basement(-3, 'basement3-L');
  // ...and down: each deeper basement waits for its own volume (excavations() digs them in order).
  for (let B = 4; B <= deepestBasement(); B++) basement(-B, `basement${B}-L`);
  return out;
}

/** Contiguous x-runs of a set of cells, row by row: the boxes that dig a disc without its corners. */
export function rowsOf(cells: Array<{ dx: number; dz: number }>): Array<{ dz: number; x0: number; x1: number }> {
  const byRow = new Map<number, number[]>();
  for (const c of cells) { if (!byRow.has(c.dz)) byRow.set(c.dz, []); byRow.get(c.dz)!.push(c.dx); }
  const out: Array<{ dz: number; x0: number; x1: number }> = [];
  for (const dz of [...byRow.keys()].sort((a, b) => a - b)) {
    const xs = [...new Set(byRow.get(dz)!)].sort((a, b) => a - b);
    let x0 = xs[0]!, prev = xs[0]!;
    for (let i = 1; i <= xs.length; i++) {
      const x = xs[i];
      if (x !== prev + 1) { out.push({ dz, x0, x1: prev }); if (x !== undefined) { x0 = x; } }
      if (x !== undefined) prev = x;
    }
  }
  return out;
}

/** Rows of `cells` at absolute layer y, packed into chunks of at most RING.chunkCells blocks. */
function chunksOf(name: string, stage: Stage, cells: Array<{ dx: number; dz: number }>, yTop: number, yBottom: number): DigChunk[] {
  const b = settlement.base;
  const layers = yTop - yBottom + 1;
  const out: DigChunk[] = [];
  let boxes: Box[] = [], cellsIn = 0, n = 0;
  const flush = () => { if (boxes.length) { out.push({ name: `${name}-${n++}`, stage, boxes, cells: cellsIn }); boxes = []; cellsIn = 0; } };
  for (const r of rowsOf(cells)) {
    const c = (r.x1 - r.x0 + 1) * layers;
    if (cellsIn + c > RING.chunkCells && boxes.length) flush();
    boxes.push({ min: { x: b.x + r.x0, y: yBottom, z: b.z + r.dz }, max: { x: b.x + r.x1, y: yTop, z: b.z + r.dz } });
    cellsIn += c;
  }
  flush();
  return out;
}

/** Every excavation, in the order it is dug. Chunks fit a turtle's inventory without unloading. */
export function excavations(): DigChunk[] {
  freshCaches();
  if (excavCache) return excavCache;
  excavCache = excavationsUncached();
  return excavCache;
}
function excavationsUncached(): DigChunk[] {
  const b = settlement.base, h = RING.shaftHalf, H = FLOOR_H();
  const sp = spec0();
  const out: DigChunk[] = [];
  // No trench for the walls: the builder digs whatever stands in a wall cell as it places there
  // (the user, 2026-09-08: "it can dig as it's placing the wall if there's existing shit there"),
  // so nothing is cleared that is not replaced in the same breath.
  // The shaft: 3x3 from just under the slab down, a few layers per chunk. The slab plane and the
  // core column above it belong to the structure; the atrium opens through them by design.
  for (let top = b.y - 1, i = 0; top >= RING.shaftBottom; top -= RING.shaftChunkLayers, i++) {
    const bottom = Math.max(RING.shaftBottom, top - RING.shaftChunkLayers + 1);
    out.push({ name: `shaft-${i}`, stage: 'shaft', cells: 9 * (top - bottom + 1),
      boxes: [{ min: { x: b.x - h, y: bottom, z: b.z - h }, max: { x: b.x + h, y: top, z: b.z + h } }] });
  }
  // The storey's interior above the slab (dy 1..H-1), so the ground floor is a room and not a hill
  // with a roof. Rows are filtered at issue time to those the shared map holds solid, so open air is
  // never swept; the slab itself replaces the ground layer as it is laid.
  // ...minus every cell the structure occupies at that height: the inner service skin (radius 18)
  // stands inside the disc, and clearing "the interior" dug it out course by course (2026-09-08).
  const f0 = towerFloor(sp, 0, pal);
  // The atrium at slab height: the slab has no squares inside the atrium radius, and the shaft is dug
  // from one below it, so the disc at y0 stayed dirt -- "the mine shaft head entrance is full of dirt"
  // (the user, 2026-09-08). Cleared like the interior, as a target list of map-solid cells.
  const struct0 = new Set(f0.filter((x) => x.dy === 0 && x.item !== pal.stair && x.item !== pal.barrel).map((x) => `${x.dx}:${x.dz}`));
  out.push(...chunksOf('atrium-L0', 'floor-dig', discCells(sp.atriumRadius).filter((c) => !struct0.has(`${c.dx}:${c.dz}`)), b.y, b.y));
  // The cavity slabs laid before the cavity was declared hollow: removed as un-build digs (map-solid
  // cells only, issued with unbuild so the drone may take placed cobble).
  const wallsAt = (dy: number) => new Set(f0.filter((x) => isWall(x) && x.dy === dy).map((x) => `${x.dx}:${x.dz}`));
  const cavity = discCells(sp.radius).filter((c) => inCavity(c));
  out.push(...chunksOf('cavity-L0', 'unbuild', cavity.filter((c) => !wallsAt(0).has(`${c.dx}:${c.dz}`)), b.y, b.y));
  out.push(...chunksOf('cavity-roof', 'unbuild', cavity.filter((c) => !wallsAt(H).has(`${c.dx}:${c.dz}`)), b.y + H, b.y + H));
  for (let dy = H - 1; dy >= 1; dy--) {
    const walls = new Set(f0.filter((x) => x.dy === dy).map((x) => `${x.dx}:${x.dz}`));
    const interior = discCells(sp.radius - 1).filter((c) => !walls.has(`${c.dx}:${c.dz}`));
    out.push(...chunksOf(`floor-L${dy}`, 'floor-dig', interior, b.y + dy, b.y + dy));
  }
  // The basement: the whole footprint including the wall ring (the lining replaces the rock), one
  // storey down, layer by layer from the top.
  const footprint = discCells(sp.radius);
  for (let dy = -1; dy >= -H; dy--) out.push(...chunksOf(`basement-L${-dy}`, 'basement-dig', footprint, b.y + dy, b.y + dy));
  // THE QUARRY. The basement's dirt and the shaft's stone did not cover the lining: 4,393 placed and
  // 2,160 to go with 475 on the shelf (2026-09-08). The storey below the basement is solid stone at
  // this depth; it is dug layer by layer only while cobble is short (the user: "finish the basement and
  // then continue the shaft or strip-mine the next few basements"). It is not part of the benchmark's
  // finish line -- see currentStage.
  for (let dy = -H - 1; dy >= -2 * H; dy--) out.push(...chunksOf(`quarry-L${-dy}`, 'quarry', discCells(sp.radius - 1), b.y + dy, b.y + dy));
  // Basement -3's volume, the same way (its lining waits for these by name).
  for (let dy = -2 * H - 1; dy >= -3 * H; dy--) out.push(...chunksOf(`basement3-L${-dy}`, 'quarry', discCells(sp.radius - 1), b.y + dy, b.y + dy));
  // Deeper basements, one storey at a time: the hands are never without rock to dig (all stone at
  // these depths, still above deepslate at y8 for DEEPEST_BASEMENT 6 -> y30).
  for (let B = 4; B <= deepestBasement(); B++)
    for (let dy = -(B - 1) * H - 1; dy >= -B * H; dy--) out.push(...chunksOf(`basement${B}-L${-dy}`, 'quarry', discCells(sp.radius - 1), b.y + dy, b.y + dy));
  return out;
}
const DEEPEST_BASEMENT = 8;   // y18 at the bottom, still above deepslate (y8); the fleet had run out of rock to dig at 6 (2026-09-08)
// THE PLAN GROWS. When every block is built and every row dug, one more basement level is added
// ("base and factories continuously expanding" -- the user, 2026-09-08). Bedrock is at y-64; the cap
// keeps the lowest slab above y-40 (level 17 -> y-36).
const MAX_BASEMENT = 17;
// Grow when the ROCK runs out, not when the last block is laid: deeper basements append to both
// lists, so nothing above shifts, and a level's lining always trails its dig by a while -- waiting
// for it left five miners idle with two chunks left to dig (2026-09-08 17:30).
// "Rock ran out" = every chunk is dug or in flight AND the queue could not be filled to QUEUED_DIGS;
// without the second half the plan grew five levels in one tick (2026-09-08 17:34).
const planComplete = (_s: StagedBlock[], e: DigChunk[]) =>
  (boot.dugSet ?? []).length + (boot.digs ?? []).length >= e.length && (boot.digs ?? []).length < QUEUED_DIGS;
function growPlan(): boolean {
  if (deepestBasement() >= MAX_BASEMENT) return false;
  boot.extraBasements = (boot.extraBasements ?? 0) + 1;
  note(`plan grown: basement -${deepestBasement()} added (${structure().length} blocks, ${excavations().length} excavation chunks)`);
  save();
  return true;
}
/** Is the excavation a block waits for complete? */
function gateOpenFor(b: StagedBlock | undefined, done: (c: DigChunk, idx: number) => boolean): boolean {
  if (!b) return true;
  const e = excavations();
  if (b.needs) return e.every((c, i) => !c.name.startsWith(b.needs!) || done(c, i));
  const gate = GATE[b.stage];
  return !gate || e.every((c, i) => c.stage !== gate || done(c, i));
}
const doneByName = (dugSet: string[]) => (c: DigChunk) => dugSet.includes(c.name);
/** Cobble on the shelf and aboard below which the quarry is dug. */
const QUARRY_BELOW = 700;
const FUEL_FLOOR = 3000;
const FUEL_TOPUP = 20000;

/** Which excavation a structure stage waits for. Walls and roof wait for nothing but material. */
const GATE: Partial<Record<Stage, Stage>> = { floor: 'floor-dig', basement: 'basement-dig' };

export interface BootState {
  active: boolean;
  startedAt: number | null;
  finishedAt: number | null;
  /** First time each stage was seen complete, for the phase breakdown of the benchmark. */
  stageDone: Partial<Record<Stage, number>>;
  built: number;         // blocks of structure() issued and completed
  dug: number;           // chunks of excavations() issued and completed
  /** The dig in flight (legacy single slot; digs[] carries concurrent ones). */
  inflight: { kind: 'build' | 'dig'; name: string; from: number; to: number } | null;
  /** Digs in flight, one per miner at most; shaft chunks (one column) never overlap. */
  digs?: Array<{ name: string; from: number; to: number; chunk?: string }>;
  /** A wall batch in flight (legacy single slot; builds[] carries concurrent ones). */
  buildInflight: { kind: 'build'; name: string; from: number; to: number } | null;
  /** Wall batches in flight, all of one course so no batch pre-marks another's standing cells. */
  builds?: Array<{ name: string; from: number; to: number; dy: number }>;
  /** Which finished course the scout inspects next, and when it last did. */
  inspectCourse?: number;
  lastInspect?: number;
  /** The repair pass in flight, in its own slot. */
  repairInflight?: { name: string } | null;   // legacy single slot; `repairs` is the list
  repairs?: string[];   // repair sweeps in flight, up to REPAIRS_MAX
  scoutInflight: string | null;
  /** Bays ordered by the loop: name -> what was ordered and where its modems are (for activation). */
  extraBasements?: number;   // levels added by growPlan beyond DEEPEST_BASEMENT
  trunks?: Record<string, number>;   // level -> task id of its cable trunk (ordered once, before the level's first bay)
  bays?: Record<string, { level: number; sector: number; role: string; task: number | null; state: 'building' | 'built' | 'active'; tries?: number; retryAt?: number; activating?: boolean; missing?: Record<string, number>; lastUnnamed?: number; design?: number; modems: Array<{ x: number; y: number; z: number }>; chests: Array<{ x: number; y: number; z: number }> }>;
  /** Inspection sweeps outstanding, one per scout, and which course each covers; when each course was last inspected. */
  inspecting?: string[];
  inspectingKeys?: Record<string, string>;
  lastBayTry?: number;
  lastFuelPass?: number;
  deferCount?: Record<string, number>;
  lastBayShort?: string;
  courseSeen?: Record<string, number>;
  /** A wall batch handed to the scout, drawing cobble from storage; the miner's batches wait for it. */
  scoutBuild: { name: string; from: number; to: number; full?: boolean } | null;
  /** The scout found the current stretch buried; it does not re-check until the miner has passed it. */
  scoutSkipUntil?: number;
  /** Consecutive failures of the current step; three stops the loop rather than digging blindly. */
  attempts: number;
  /** Names of excavation chunks completed (digs finish out of order, and the list may be re-cut between builds). */
  dugSet?: string[];
  /** The chunk index the scout last surveyed, so it scans once per chunk rather than once per tick. */
  lastSurveyDug?: number;
  log: string[];
  lastTick: number;
  /** What the last tick decided, acted or not -- an idle fleet with no log line was unreadable without it. */
  lastReason?: string;
  /** Chunks set aside after repeated failures; retried once everything else is dug. */
  deferred?: string[];
  /** Which cell of the 3x3 survey grid the scout scans next. */
  surveyIdx?: number;
  /** When a repair batch was last issued (small holes wait for company). */
  lastRepairDone?: number;
  /** When the last repair pass ran. */
  lastRepair?: number;
  /** Cells of batches in flight ("dx:dy:dz"), so no two batches share a square. */
  claimed?: Record<string, string>;
}

function load(): BootState {
  const base: BootState = { active: false, startedAt: null, finishedAt: null, stageDone: {}, built: 0, dug: 0,
                            inflight: null, digs: [], buildInflight: null, scoutInflight: null, scoutBuild: null, attempts: 0, log: [], lastTick: 0 };
  try {
    const st: BootState = { ...base, ...JSON.parse(readFileSync(FILE, 'utf8')) };
    // Older state kept only a cursor; the set of finished chunks is everything below it.
    if (!st.dugSet && st.dug > 0) st.dugSet = excavations().slice(0, st.dug).map((c) => c.name);
    if (st.dugSet && st.dugSet.some((x: any) => typeof x === 'number')) st.dugSet = (st.dugSet as any[]).map((x) => typeof x === 'number' ? excavations()[x]?.name ?? String(x) : x);
    return st;
  } catch { return base; }   // silent: allow (no saved state is the first-run case)
}
export const boot: BootState = load();
function save() {
  try { mkdirSync(dirname(FILE), { recursive: true }); writeFileSync(FILE, JSON.stringify(boot, null, 2)); } catch { /* silent: allow (a failed state write loses one tick of bookkeeping; the next tick rewrites it, and the loop must not die on a disk hiccup) */ }
}
function note(msg: string) {
  const line = `${new Date().toISOString().slice(11, 19)} ${msg}`;
  boot.log.push(line); if (boot.log.length > 200) boot.log.splice(0, boot.log.length - 200);
  console.log(`[bootstrap] ${msg}`);
}

/**
 * registry.invoke answers {ok, data} (or {ok:false, error}); the callers below want the tool's own
 * result. The first run of this loop read `dispatched` off the ENVELOPE, saw undefined, concluded
 * every dig had failed to dispatch, and issued the same shaft chunk twelve times in a minute --
 * while its own log said nothing had happened. Unwrap once, here, and treat a refusal as a throw.
 */
async function tool(name: string, args: unknown): Promise<any> {
  const r: any = await registry.invoke(name, args, { agent: 'bootstrap', callId: `boot-${Date.now()}`, log: () => {} });
  if (r && typeof r === 'object' && 'ok' in r) {
    if (r.ok === false) throw new Error(`${name}: ${r.error ?? 'refused'}`);
    return r.data;
  }
  return r;
}

/**
 * The queue, split into live and finished names. ABSENCE IS NOT COMPLETION: a task TaskMan dropped
 * (no drone could take it, or it failed three times) is gone from the live list exactly like one
 * that finished, and the first run of this loop advanced through six shaft chunks in thirty seconds
 * on that misreading while the miner was still holding the first one. A step is done only when the
 * task is reported at 100%; gone without that is a failure and is re-issued.
 */
async function queueNames(): Promise<{ live: string[]; done: string[] }> {
  const r: any = await tool('fleet.tasks', {});
  const live: string[] = [], done: string[] = [];
  for (const t of (r?.tasks ?? []) as any[]) {
    if (typeof t?.name !== 'string') continue;
    if ((t.progress ?? 0) < 100) live.push(t.name);
    else if (!t.failure) done.push(t.name);      // 100% WITH a failure is "given up", not done
  }
  return { live, done };
}
// Exact names, and every issued task gets a unique suffix: a prefix match let a stale twin from an
// earlier run ("boot:shaft-0" at 100%) stand in for the new step, so the loop advanced past a chunk
// nobody had dug (2026-09-08).
const named = (list: string[], name: string) => list.includes(name);
const unique = (base: string) => `${base}#${Date.now() % 1000000}`;
const MAX_ATTEMPTS = 3;

/** What the current stage is, from the cursors. */
export function currentStage(built: number, dug: number): Stage {
  const s = structure(), e = excavations();
  const nextBlock = s[built];
  if (!nextBlock) return 'done';
  void e;
  // `dug` is a cursor: chunks before it are done (the tests drive this with an index)
  if (!gateOpenFor(nextBlock, (_c, i) => i < dug)) return GATE[nextBlock.stage] ?? 'basement-dig';
  return nextBlock.stage;
}

function markStage(stage: Stage) {
  if (!boot.stageDone[stage]) { boot.stageDone[stage] = Date.now(); note(`stage ${stage} complete at +${elapsed()}`); }
}
function elapsed(): string {
  if (!boot.startedAt) return '0s';
  const s = Math.round(((boot.finishedAt ?? Date.now()) - boot.startedAt) / 1000);
  return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`;
}


/** Cobblestone StorageMan can hand out, from its own index (the spoils chest is on its wire). */
// ONE STOCK READ PER FEW SECONDS, NOT ONE PER QUESTION. A tick asks "how many X" for every bay and
// every missing item; each ask was a full StorageMan index scan (12.7 game-s over 128 chests), and
// the module was terminated by ComputerCraft for running over (2026-09-08). The snapshot is shared.
let stockSnap: { at: number; st: any } | null = null;
async function stockSnapshot(): Promise<any> {
  if (stockSnap && Date.now() - stockSnap.at < 5000) return stockSnap.st;
  const st: any = await tool('storage.stock', {});
  stockSnap = { at: Date.now(), st };
  return st;
}
async function stockCount(item: string): Promise<number> {
  try {
    const st: any = await stockSnapshot();
    const detail: any[] = luaList<any>(field(st, 'detail')) ?? st?.detail ?? [];
    let n = 0;
    for (const it of detail) if (String(it?.name ?? it?.item) === item) n += Number(it?.count ?? it?.n ?? 0);
    return n;
  } catch { return 0; }   // silent: allow (no storage reads as none of it)
}
async function cobbleInStorage(): Promise<number> { return stockCount(COBBLE); }
async function storageFreeSlots(): Promise<number> {
  try { const st: any = await stockSnapshot(); return Number(st?.free ?? 9999); } catch { return 9999; }   // silent: allow (no answer must not stop the digging)
}
const QUARRY_MIN_FREE = 60;

/**
 * Indices of blocks the scout can lay: the target cell is KNOWN AIR and the standing cell above it is
 * not known solid. "Not known solid" alone handed the scout 185 floor cells of grass it could not
 * clear, and it walked every one to skip it (2026-09-08). Unknown is not air.
 */
async function openCells(blocks: Block[]): Promise<Set<number>> {
  const b = settlement.base;
  const targets = blocks.map((k) => ({ x: b.x + k.dx, y: b.y + k.dy, z: b.z + k.dz }));
  const above = blocks.map((k) => ({ x: b.x + k.dx, y: b.y + k.dy + 1, z: b.z + k.dz }));
  const air = new Set<number>(), solidAbove = new Set<number>();
  for (let start = 0; start < targets.length; start += 300) {
    // silent: allow (no answer means nothing is known air, so the scout is offered nothing this tick)
    const ra: any = await bridge.call('MapServer', 'KnownAir', { positions: targets.slice(start, start + 300) }, { timeoutMs: 15000 }).catch(() => null);
    for (const idx of luaList<number>(field(ra, 'air')) ?? []) if (typeof idx === 'number') air.add(start + idx - 1);
    // silent: allow (no answer means the standing cell is taken as open; the builder skips a blocked square itself)
    const rs: any = await bridge.call('MapServer', 'BlocksSolid', { positions: above.slice(start, start + 300) }, { timeoutMs: 15000 }).catch(() => null);
    for (const idx of luaList<number>(field(rs, 'solid')) ?? []) if (typeof idx === 'number') solidAbove.add(start + idx - 1);
  }
  const open = new Set<number>();
  for (let i = 0; i < blocks.length; i++) if (air.has(i) && !solidAbove.has(i)) open.add(i);
  return open;
}

/**
 * ONE COURSE PER BATCH. The builder marks every block of its batch solid in the shared map before it
 * starts, so the fleet routes around walls that do not exist yet -- and a batch spanning two courses
 * therefore marked the very cells the drone has to stand on (the course above) as solid: the planner
 * answered "goal is solid" for every square and both drones circled the wall line looking for a way
 * in (2026-09-08). A batch stays within one stage and one dy.
 */
const sameCourse = (a: StagedBlock, b: StagedBlock) => a.stage === b.stage && a.dy === b.dy;

/** Does the shared map hold no solid cell in this chunk? (Sampled: every cell of every box.) */
async function chunkIsOpen(chunk: DigChunk): Promise<boolean> {
  const positions: Array<{ x: number; y: number; z: number }> = [];
  for (const bx of chunk.boxes)
    for (let x = bx.min.x; x <= bx.max.x; x++) for (let y = bx.min.y; y <= bx.max.y; y++) for (let z = bx.min.z; z <= bx.max.z; z++)
      positions.push({ x, y, z });
  // POSITIVE knowledge only: every cell must be KNOWN air. "Not known solid" let seven unsurveyed
  // basement levels (y -34 and below) be skipped as open and marked dug in one tick (2026-09-08).
  for (let start = 0; start < positions.length; start += 300) {
    const slice = positions.slice(start, start + 300);
    let r: any = null;
    try { r = await bridge.call('MapServer', 'KnownAir', { positions: slice }, { timeoutMs: 15000 }); }
    catch (e) { note(`dig ${chunk.name}: map did not answer (${String(e).slice(0, 60)}) -- digging it`); return false; }
    if ((luaList<number>(field(r, 'air')) ?? []).length < slice.length) return false;
  }
  return true;
}

/** Indices of blocks for which a MapServer index endpoint (KnownAir -> 'air', BlocksSolid -> 'solid') lists the cell. */
async function mapIndexSet(blocks: Block[], endpoint: 'KnownAir' | 'BlocksSolid', key: 'air' | 'solid'): Promise<Set<number>> {
  const b = settlement.base;
  const positions = blocks.map((k) => ({ x: b.x + k.dx, y: b.y + k.dy, z: b.z + k.dz }));
  const out = new Set<number>();
  for (let start = 0; start < positions.length; start += 300) {
    // silent: allow (an unanswered map query lists nothing; every caller treats "not listed" as unknown)
    const r: any = await bridge.call('MapServer', endpoint, { positions: positions.slice(start, start + 300) }, { timeoutMs: 15000 }).catch(() => null);
    for (const idx of luaList<number>(field(r, key)) ?? []) if (typeof idx === 'number') out.add(start + idx - 1);
  }
  return out;
}
/** Indices of blocks whose own cell the shared map already holds solid. */
const solidCells = (blocks: Block[]) => mapIndexSet(blocks, 'BlocksSolid', 'solid');

/** The boxes (rows) not already KNOWN to be all air; unknown terrain counts as terrain and is dug. */
async function solidBoxes(boxes: Box[]): Promise<Box[]> {
  const out: Box[] = [];
  for (const bx of boxes) {
    const positions: Array<{ x: number; y: number; z: number }> = [];
    for (let x = bx.min.x; x <= bx.max.x; x++) for (let y = bx.min.y; y <= bx.max.y; y++) for (let z = bx.min.z; z <= bx.max.z; z++) positions.push({ x, y, z });
    // silent: allow (no answer means unknown, and an unknown row is dug rather than skipped)
    const r: any = await bridge.call('MapServer', 'KnownAir', { positions }, { timeoutMs: 15000 }).catch(() => null);
    const air = (luaList<number>(field(r, 'air')) ?? []).length;
    if (r == null || air < positions.length) out.push(bx);
  }
  return out;
}

/**
 * THE REPAIR PASS. Squares a batch skipped -- no route, short of cobble, unreachable for the scout --
 * were never revisited once the cursor had moved on, so the walls filled with holes (2026-09-08).
 * Every REPAIR_EVERY_MS, the finished part of the structure is compared with the shared map and the
 * missing squares of the lowest unfinished course are queued as an ordinary batch.
 */
const REPAIR_EVERY_MS = 30_000;
// Three courses at once: with one slot, six known wall holes waited an hour behind 30-40-square slab
// repairs while eight miners laid bays (2026-09-08). Each repair is one course; the claims keep them apart.
const REPAIRS_MAX = 3;
/**
 * THE REPAIR IS A SWEEP, NOT A MAP QUERY. Repairing only the squares the map had seen as air left the
 * roof full of leaves and the walls full of holes nobody had looked at ("they aren't repairing shit,
 * they just pretend to" -- the user, 2026-09-08). A hand-driven turtle that simply flew the roof plane
 * and fixed whatever was not cobblestone did 1,264 squares in 150 s: 262 filled, 50 leaves cleared.
 * So a repair pass is one whole finished course, handed to a miner as a sweep: slabs and the roof from
 * above, wall courses from the open side at their own height (each block carries its standing cell).
 * Courses take turns; a course the map knows to have holes goes first.
 */
async function repairBatch(): Promise<Block[] | null> {
  const s = structure();
  const done = s.slice(0, boot.built);
  if (done.length === 0) return null;
  // Only cells the fleet has SEEN wrong: observed air, or a name other than the wanted item. The
  // scout's inspection sweeps are what fill this in; a miner is never sent to look for itself.
  const air = await airCells(done); const wrong = await wrongMaterial(done);
  const cells = new Set(s.map((b) => `${b.dx}:${b.dy}:${b.dz}`));
  const coveredByStructure = (b: StagedBlock) => isFlat(b) && cells.has(`${b.dx}:${b.dy + 1}:${b.dz}`);
  const candidates = done.filter((b, i) => (air.has(i) || wrong.has(i)) && unclaimed(b) && !coveredByStructure(b));
  if (candidates.length === 0) return null;
  // ...AND ONLY WHERE A DRONE CAN STAND. The standing cell (above a slab square, beside a wall square)
  // must be open per the map: 43 floor squares under the station computers and monitors were "known
  // wrong" and unreachable, and three miners in turn burned 245 fuel each to skip all 43 (2026-09-08).
  // EITHER SIDE COUNTS. The scout saw 152 wall squares from OUTSIDE while the inside standing cell was
  // still stale-solid in the map, and the pass left every one ("none with an open standing cell",
  // 2026-09-08). A square is reachable if any of its standing cells is open: inside, outside, above.
  const open = await reachableStands(candidates);
  const missing = candidates.filter((_, i) => open.has(i));
  if (missing.length === 0) { note(`repair: ${candidates.length} wrong square(s) known, none with an open standing cell -- left`); return null; }
  // the course with the most trouble, whole, as one sweep
  const byCourse = new Map<string, StagedBlock[]>();
  for (const b of missing) { const k = `${b.stage}:${b.dy}`; if (!byCourse.has(k)) byCourse.set(k, []); byCourse.get(k)!.push(b); }
  // Walls first, then the course with the most trouble: six known wall holes waited two hours behind
  // 10-17-square slab courses ("genuinely tho pls fix the walls" -- the user, 2026-09-08).
  const wallish = (c: StagedBlock[]) => (c[0]!.stage === 'walls' ? 1 : 0);
  const pick = [...byCourse.values()].sort((a, b) => (wallish(b) - wallish(a)) || (b.length - a.length))[0]!;
  if (pick.length < 4 && Date.now() - (boot.lastRepairDone ?? 0) < 300_000) return null;
  boot.lastRepairDone = Date.now();
  return pick.slice(0, MAX_BUILD_BATCH).map((b) => withStand(b));
}

let activationChain: Promise<unknown> = Promise.resolve();
/**
 * ACTIVATE A BUILT BAY. For each modem the drones placed: flip its peripheral state over RCON (the one
 * act a turtle cannot perform), read StorageMan's chest list, and register the chest above the modem
 * by the network name that just appeared. One modem at a time, so name and position pair up.
 */
/** Open cells of a bay by item, from the shared map: the plan's cells the map does not show solid. */
async function bayMissing(bay: { level: number; sector: number; role: string }): Promise<Record<string, number>> {
  const sp = specForLevel(bay.level);
  const interior = bay.role === 'factory' ? factoryBayInterior(sp, bay.sector) : storageBayInterior(sp, bay.sector);
  const blocks: Block[] = interior.blocks.map((k) => ({ ...k, dy: k.dy + bay.level * sp.floorHeight } as Block));
  const solid = await solidCells(blocks);
  const out: Record<string, number> = {};
  blocks.forEach((b, i) => { if (!solid.has(i)) out[b.item] = (out[b.item] ?? 0) + 1; });
  return out;
}

async function activateBay(bay: { level: number; sector: number; role: string }): Promise<{ registered: number; unnamed: number }> {
  // Geometry from the plan, not from the order's record: the same cells whatever built them.
  const sp = specForLevel(bay.level);
  const origin = { x: settlement.base.x, y: settlement.base.y + bay.level * sp.floorHeight, z: settlement.base.z };
  const interior = bay.role === 'factory' ? factoryBayInterior(sp, bay.sector) : storageBayInterior(sp, bay.sector);
  const names = async (): Promise<Set<string>> => {
    let last: unknown = null;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        // Names only: `storage.stock` rebuilt StorageMan's whole index behind every toggle and timed out
        // ("activation failed: no response from StorageMan.stock", 2026-09-08).
        const r: any = await bridge.call('StorageMan', 'chestNames', {}, { timeoutMs: 15000 });
        return new Set((luaList<any>(field(r, 'names')) ?? []).map((c: any) => String(c)));
      } catch (e) { last = e; await new Promise((r) => setTimeout(r, 2000)); }
    }
    throw last instanceof Error ? last : new Error(String(last));
  };
  const pause = () => new Promise((r) => setTimeout(r, 3000));   // StorageMan rescans on the next question; 1.2 s missed names that 3 s catches (measured 2026-09-08)
  let registered = 0, unnamed = 0;
  for (const ch of interior.chests) {
    const m = { x: origin.x + ch.dx, y: origin.y + ch.dy - 1, z: origin.z + ch.dz };   // the modem under the chest
    const cpos = { x: origin.x + ch.dx, y: origin.y + ch.dy, z: origin.z + ch.dz };
    // DETACH, THEN ATTACH: the name that is missing while detached and back when attached belongs to
    // THIS chest. Measured 2026-09-08: flipping peripheral=false alone detaches nothing (28 -> 28
    // chests); replacing the block does (28 -> 27); flipping it on again attaches (-> 28). A one-way
    // flip paired names with the wrong cells when several came up at once.
    await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:cable`);
    await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:wired_modem_full[modem=true,peripheral=false]`);
    await pause();
    const off = await names();
    await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:wired_modem_full[modem=true,peripheral=true]`);
    await pause();
    const on = await names();
    // Only a chest counts: a drone hovering over a bay modem attaches as `turtle_N` and was registered
    // as a chest at that position four times (2026-09-08).
    const fresh = [...on].filter((n) => !off.has(n) && /chest|barrel/.test(n));
    if (fresh.length === 1) {
      await tool('storage.forgetDeposit', { x: cpos.x, y: cpos.y, z: cpos.z }).catch(() => null);   // silent: allow (nothing to forget is the normal case)
      await tool('storage.deposit', { ...cpos, peripheral: fresh[0] });
      registered++;
    } else unnamed++;
  }
  // MACHINES TOO. A factory bay's furnaces sit on modems of their own; without peripheral=true they
  // are not on the wire and StorageMan's furnace service never sees them. No name to register: the
  // furnace service finds them by type. Same replace-then-flip, for the same reason as above.
  for (const mc of interior.machines) {
    // both faces: the modem under the machine (fuel + output) and the one over it (input)
    for (const dy of [-1, 1]) {
      const m = { x: origin.x + mc.dx, y: origin.y + mc.dy + dy, z: origin.z + mc.dz };
      await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:cable`);
      await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:wired_modem_full[modem=true,peripheral=false]`);
      await rcon(`setblock ${m.x} ${m.y} ${m.z} computercraft:wired_modem_full[modem=true,peripheral=true]`);
    }
  }
  if (interior.machines.length) { await pause(); note(`${interior.machines.length} machine modem(s) exposed`); }
  return { registered, unnamed };
}
registry.register({
  name: 'bay.activate',
  summary: 'Bind a built bay: for each chest, toggle its modem off and on over RCON and register the chest by the network name that comes back.',
  description: 'RCON state flips only -- the drones placed everything. Re-runnable.',
  params: z.object({ level: z.number().int(), sector: z.number().int().min(0), role: z.enum(['storage', 'factory']).default('storage') }).strict(),
  returns: 'registered and unnamed counts.',
  danger: 'mutate',
  // verify-at-effect: registers each chest only when StorageMan's chest list actually lost and regained exactly one name across the flip
  handler: async (a) => {
    const r = await activateBay({ level: a.level, sector: a.sector, role: a.role });
    const rec = boot.bays?.[`bay-L${a.level}-s${a.sector}`];
    // A bay whose build is still running keeps its state: flipping it to 'built' here made the loop order a second copy of the live task.
    if (rec && rec.state !== 'building') { rec.state = r.unnamed === 0 ? 'active' : 'built'; rec.missing = undefined; save(); }
    return r;
  },
});

/** The finished courses of the structure, in build order. */
function finishedCourses(): Array<{ key: string; blocks: StagedBlock[] }> {
  const done = structure().slice(0, boot.built);
  const courses: Array<{ key: string; blocks: StagedBlock[] }> = [];
  for (const b of done) {
    const key = `${b.stage}:${b.dy}`;
    const c = courses.find((x) => x.key === key);
    if (c) c.blocks.push(b); else courses.push({ key, blocks: [b] });
  }
  return courses;
}

const courseCache = new Map<number, Set<string>>();
function courseCells(dy: number): Set<string> {
  let c = courseCache.get(dy);
  if (!c) { c = new Set(structure().filter((x) => x.dy === dy).map((x) => `${x.dx}:${x.dz}`)); courseCache.set(dy, c); }
  return c;
}
/** A wall block gets its standing cell: the open neighbour at its own height nearest the centre. */
export function withStand(b: StagedBlock): Block & { sx?: number; sz?: number; sx2?: number; sz2?: number } {
  const out: Block & { sx?: number; sz?: number; sx2?: number; sz2?: number } = { dx: b.dx, dy: b.dy, dz: b.dz, item: b.item };
  // A wall course AT slab height has the slab beside it, not air: given "stand inside" cells D3 dug
  // floor squares to stand in and re-laid them, over and over (2026-09-08). Those courses, like the
  // slabs, are reached from above; only the courses with the open room beside them are laid sideways.
  // Wall squares at slab height are laid sideways too: the neighbours that are structure (the floor
  // slab beside the inner skin) are excluded below, so only open cells (the hollow cavity beside the
  // outer ring) can become standing cells. 55 holes at the foot of the outer ring waited on this.
  if (isFlat(b)) return out;
  const course = courseCells(b.dy);
  const n = [[1, 0], [-1, 0], [0, 1], [0, -1]]
    .map(([ax, az]) => ({ dx: b.dx + ax!, dz: b.dz + az! }))
    .filter((c) => !course.has(`${c.dx}:${c.dz}`))
    .sort((p, q) => Math.hypot(p.dx, p.dz) - Math.hypot(q.dx, q.dz));
  const inward = n.find((c) => Math.hypot(c.dx, c.dz) < Math.hypot(b.dx, b.dz)) ?? n[0];
  if (inward) { out.sx = inward.dx; out.sz = inward.dz; }
  // ...and the OUTSIDE as the second choice: the outer ring's outward neighbour is open sky, so a
  // square the scout cannot reach from the room (a chest, a wall of the notch, another drone) is
  // seen and laid from outside instead of being written off (2026-09-08).
  const outward = n.find((c) => Math.hypot(c.dx, c.dz) > Math.hypot(b.dx, b.dz) && c !== inward);
  if (outward) { out.sx2 = outward.dx; out.sz2 = outward.dz; }
  return out;
}

/** Indices of blocks whose own cell the shared map has OBSERVED as air. Unknown is not air. */
const airCells = (blocks: Block[]) => mapIndexSet(blocks, 'KnownAir', 'air');

const cellKey = (b: Block) => `${b.dx}:${b.dy}:${b.dz}`;
/** Drop the claims of a finished batch. */
function unclaim(taskName: string) {
  const c = boot.claimed ?? {};
  for (const k of Object.keys(c)) if (c[k] === taskName) delete c[k];
  boot.claimed = c;
}
function claim(taskName: string, blocks: Block[]) {
  boot.claimed = boot.claimed ?? {};
  for (const b of blocks) boot.claimed[cellKey(b)] = taskName;
}
const unclaimed = (b: Block) => !(boot.claimed ?? {})[cellKey(b)];

/** Indices of blocks whose cell the map knows by NAME as something other than the wanted item (a log in a wall cell). */
/** The map's block NAME per index, for the cells it knows by name. */
async function namesAt(blocks: Block[]): Promise<Map<number, string>> {
  const b = settlement.base;
  const positions = blocks.map((k) => ({ x: b.x + k.dx, y: b.y + k.dy, z: b.z + k.dz }));
  const out = new Map<number, string>();
  for (let start = 0; start < positions.length; start += 300) {
    // silent: allow (no answer means no names known, so nothing is called wrong this pass)
    const r: any = await bridge.call('MapServer', 'NamesAt', { positions: positions.slice(start, start + 300) }, { timeoutMs: 15000 }).catch(() => null);
    const names = field(r, 'names') ?? {};
    for (const [k, v] of Object.entries(names as Record<string, string>)) out.set(start + Number(k) - 1, v);
  }
  return out;
}

/**
 * Indices of blocks a sweep can get at: EITHER standing cell (inside/outside for a wall square, above/
 * below for a slab square) is not map-solid -- or is vegetation, which the sweep digs on its last three
 * steps (two wall cells sat under a canopy for hours as "no open standing cell", 2026-09-08).
 */
async function reachableStands(blocks: StagedBlock[]): Promise<Set<number>> {
  const stands1 = blocks.map((b) => { const w = withStand(b); return w.sx !== undefined ? { dx: w.sx, dy: b.dy, dz: w.sz!, item: b.item } : { dx: b.dx, dy: b.dy + 1, dz: b.dz, item: b.item }; });
  const stands2 = blocks.map((b) => { const w = withStand(b); return w.sx2 !== undefined ? { dx: w.sx2, dy: b.dy, dz: w.sz2!, item: b.item } : { dx: b.dx, dy: b.dy - 1, dz: b.dz, item: b.item }; });
  const [solid1, solid2, veg1, veg2] = await Promise.all([solidCells(stands1), solidCells(stands2), vegetationCells(stands1), vegetationCells(stands2)]);
  const out = new Set<number>();
  blocks.forEach((_, i) => { if (!solid1.has(i) || !solid2.has(i) || veg1.has(i) || veg2.has(i)) out.add(i); });
  return out;
}

/** Indices whose map-known name satisfies the predicate. */
async function namedCells(blocks: Block[], pred: (name: string, block: Block) => boolean): Promise<Set<number>> {
  const out = new Set<number>();
  for (const [i, v] of await namesAt(blocks)) if (blocks[i] && pred(v, blocks[i]!)) out.add(i);
  return out;
}
/** Cells the map knows by NAME as something other than the wanted item. Infrastructure the settlement
 * placed into a structure cell (a bay modem in the slab layer, a chest, a furnace, a computer) is not
 * a wrong block; a repair would only bounce off it. */
const wrongMaterial = (blocks: Block[]) => namedCells(blocks, (v, b) => v !== b.item && !INFRA.test(v));
/** Stand cells a sweep digs its way into: vegetation the map knows by name (a tree grown into the wall, 2026-09-08). */
const vegetationCells = (blocks: Block[]) => namedCells(blocks, (v) => /leaves|_log$|vine|grass|fern|flower|sapling/.test(v));
const INFRA = /^(computercraft:|minecraft:(chest|furnace|barrel|trapped_chest|hopper)$)/;

/** Every map-known-solid cell inside the given boxes, as single-cell boxes (a clearing target list). */
async function solidTargets(boxes: Box[]): Promise<Box[]> {
  const positions: Array<{ x: number; y: number; z: number }> = [];
  for (const bx of boxes) for (let x = bx.min.x; x <= bx.max.x; x++) for (let y = bx.min.y; y <= bx.max.y; y++) for (let z = bx.min.z; z <= bx.max.z; z++) positions.push({ x, y, z });
  const out: Box[] = [];
  for (let start = 0; start < positions.length; start += 300) {
    const slice = positions.slice(start, start + 300);
    // silent: allow (no answer means no known solids in this slice this pass; the scout's scans fill the map and the next pass finds them)
    const r: any = await bridge.call('MapServer', 'BlocksSolid', { positions: slice }, { timeoutMs: 15000 }).catch(() => null);
    for (const idx of luaList<number>(field(r, 'solid')) ?? []) { const p = slice[idx - 1]; if (p) out.push({ min: { ...p }, max: { ...p } }); }
  }
  return out;
}

/** Indices of blocks whose cell the map knows BY NAME to hold exactly the wanted item. */
const builtCells = (blocks: Block[]) => namedCells(blocks, (v, b) => v === b.item);

/** A slab-like stage: built as a sweep over the plane, not square by square. */
const isFlat = (b: StagedBlock) => b.stage === 'roof' || b.stage === 'floor' || (b.stage === 'basement' && b.dy % FLOOR_H() === 0);

// ONE TICK AT A TIME. A tick awaits several map queries and can outlast the 5 s interval; two ticks
// overlapping issued the same quarry chunk twice one second apart (tasks 367 and 368, 2026-09-08).
let ticking = false;
export async function runBootstrapTick(): Promise<{ acted: boolean; reason: string }> {
  if (ticking) return { acted: false, reason: 'tick in progress' };
  ticking = true;
  try {
    const r = await tickBody();
    boot.lastReason = r.reason;
    return r;
  } finally { ticking = false; }
}
/** The level's cable trunk, ordered once before its first bay (see trunkCells). A sweep: cells already laid are skipped. */
async function orderTrunk(L: number, sp: ReturnType<typeof specForLevel>) {
  boot.trunks = boot.trunks ?? {};
  if (boot.trunks[String(L)] != null) return;
  const blocks = trunkBlocks(sp).map((b) => ({ ...b, dy: b.dy + L * sp.floorHeight }));
  // every ring but the storage level's climbs to its neighbour nearer level -1, where StorageMan sits
  const nb = L < -1 ? L + 1 : L - 1;
  if (L !== -1) blocks.push(...riserBlocks(sp, specForLevel(nb), L * sp.floorHeight, nb * sp.floorHeight));
  const r: any = await tool('order.blocks', { name: `infra:trunk-L${L}`, origin: { x: settlement.base.x, y: settlement.base.y, z: settlement.base.z }, blocks, sweep: true, priority: 1 });
  if (r?.task != null) { boot.trunks[String(L)] = r.task; note(`trunk L${L}: ${blocks.length} cable cell(s) ordered (task ${r.task})`); save(); }
}

/** Order a level's trunk again -- unless the last order is still in the queue: two island bays
 *  activating a minute apart ordered the same 97 cells twice (tasks 3993 and 3999, 2026-09-08). */
async function reorderTrunk(L: number) {
  let live = 0;
  try { const c: any = await tool('task.countNamed', { prefix: `infra:trunk-L${L}` }); live = c?.live ?? 0; }
  catch (e) { note(`trunk L${L}: could not count live trunk tasks (${String(e).slice(0, 80)}) -- ordering anyway`); }
  if (live > 0) return;
  delete (boot.trunks ?? {})[String(L)];
  await orderTrunk(L, specForLevel(L));
}

/** Repairs that left the queue: say how, drop their claims, free the slot. */
function pruneRepairs(q: Awaited<ReturnType<typeof queueNames>>) {
  boot.repairs = boot.repairs ?? (boot.repairInflight ? [boot.repairInflight.name] : []); boot.repairInflight = null;
  for (const name of [...boot.repairs]) {
    if (named(q.live, name)) continue;
    note(`${name} ${named(q.done, name) ? 'finished' : 'gone without finishing'}`);
    unclaim(name);
    boot.repairs = boot.repairs.filter((n) => n !== name); save();
  }
}

/** One more repair course when a slot is free (the first always, more only with idle miners). Returns the task name. */
async function tryIssueRepair(carried: number, idleMiners: number): Promise<string | null> {
  const n = (boot.repairs ?? []).length;
  if (!(n === 0 || (n < REPAIRS_MAX && idleMiners > 1))) return null;
  if (carried < MIN_BUILD_BATCH / 2 || Date.now() - (boot.lastRepair ?? 0) <= REPAIR_EVERY_MS) return null;
  boot.lastRepair = Date.now();
  const blocks = await repairBatch();
  if (!blocks || !blocks.length) return null;
  const name = unique(`${PREFIX}repair-${blocks[0]!.dy}`);
  const r: any = await tool('order.blocks', { name, origin: settlement.base, blocks, priority: 1, sweep: true });
  if (r?.task == null) return null;
  claim(name, blocks);
  boot.repairs = [...(boot.repairs ?? []), name];   // a repair moves no cursor
  note(`repair ${name}: ${blocks.length} square(s) the map knows wrong`);
  save();
  return name;
}

/** Once a minute while no bay is building: the next bay whose level is lined and whose bill storage covers. */
async function orderNextBay(q: Awaited<ReturnType<typeof queueNames>>) {
  boot.bays = boot.bays ?? {};
  if (!Object.values(boot.bays).some((b) => b.state === 'building') && Date.now() - (boot.lastBayTry ?? 0) > 60_000) {
    boot.lastBayTry = Date.now();
    const s = structure();
    const levelDone = (L: number) => { const last = s.map((b, i) => [b, i] as const).filter(([b]) => Math.floor(b.dy / FLOOR_H()) === L).pop(); return last !== undefined && boot.built > last[1]; };
    const levels = [-1, -2, -3, ...Array.from({ length: Math.max(0, deepestBasement() - 3) }, (_, i) => -(i + 4)), 1, 2, 3, 4, 5, 6];
    outer: for (const L of levels) {
      if (!levelDone(L)) continue;
      const sp = specForLevel(L);
      for (let sec = 0; sec < sp.sectors; sec++) {
        const name = `bay-L${L}-s${sec}`;
        if (boot.bays[name] || named(q.live, name) || named(q.done, name)) continue;
        if (bayIsFlightPath(sp, sec)) continue;
        // Every basement below -1 is storage ("storage in the basement"); -3 keeps its shaft role.
        const role = (L === -1 && sec === 10) ? 'factory' : (L <= -2 && L !== -3) ? 'storage' : outfitBay(sp, L, sec).role;
        if (role !== 'storage' && role !== 'factory') continue;
        const interior = role === 'factory' ? factoryBayInterior(sp, sec) : storageBayInterior(sp, sec);
        const need: Record<string, number> = {};
        for (const b of interior.blocks) need[b.item] = (need[b.item] ?? 0) + 1;
        let short = '';
        for (const [item, n] of Object.entries(need)) { const have = await stockCount(item); if (have < n) short += `${item.replace(/^.*:/, '')} ${have}/${n} `; }
        // NEXT BAY, NOT NEXT TICK: the smeltery's furnace wait stood in front of six storage bays on
        // levels 1-6 that chests and modems in stock could have built (2026-09-08).
        if (short) { if (boot.lastBayShort !== short) { note(`bay ${name} waits for ${short}`); boot.lastBayShort = short; } continue; }
        await orderTrunk(L, sp);
        const r: any = await tool('order.bay', { level: L, sector: sec, role });
        const b0 = r?.bays?.[0];
        boot.bays[name] = { level: L, sector: sec, role, task: b0?.task ?? null, state: 'building', design: BAY_DESIGN, modems: b0?.modems ?? [], chests: b0?.chests ?? [] };
        note(`bay ${name} (${role}): ordered, ${interior.blocks.length} block(s)`);
        save();
        break outer;
      }
    }
  }
}

/** Each ordered bay: finished task -> check the map -> activate or re-order (see the comment above the loop). */
const activationsStarted = new Set<string>();   // bays whose activation THIS process began
const BAY_DESIGN = 3;   // 3: levels below -1 gained a riser; their bays were "activated" as islands   // bump when the bay interiors change shape; built bays are re-checked against the map
function recheckOldDesigns() {
  for (const bay of Object.values(boot.bays ?? {})) {
    // Only the roles whose interior changed shape are re-checked (design 2: a top modem per furnace).
    // Re-checking every bay re-activated eight storage bays for nothing (2026-09-08).
    if ((bay.design ?? 1) < BAY_DESIGN) {
      const island = bay.level < -1 && (bay.design ?? 1) < 3;
      if ((bay.role === 'factory' || island) && bay.state === 'active') { bay.state = 'built'; bay.tries = 0; bay.missing = undefined; bay.retryAt = 0; bay.lastUnnamed = undefined; }
      bay.design = BAY_DESIGN; save();
    }
  }
}
function clearStaleActivations() {
  for (const [name, bay] of Object.entries(boot.bays ?? {})) if (bay.activating && !activationsStarted.has(name)) { bay.activating = false; save(); }
}
async function tickBays(q: Awaited<ReturnType<typeof queueNames>>) {
  // A flag from a previous HQ process: the chain that would clear it died with that process, and
  // sector 4 sat "activating" for ever after a rebuild (2026-09-08).
  clearStaleActivations();
  recheckOldDesigns();
  boot.bays = boot.bays ?? {};
  for (const [name, bay] of Object.entries(boot.bays)) {
    if (bay.state === 'building' && !named(q.live, name)) {
      // BUILT MEANS THE MAP SHOWS EVERY CELL SOLID, not that the task left the queue. Sector 9 was
      // called "built: 20 chest(s)" from the plan while the world held 4 of them: the build had
      // skipped 15 squares "short of chest" and activation bound nothing (2026-09-08).
      const missing = await bayMissing(bay);
      const total = Object.values(missing).reduce((a, b) => a + b, 0);
      if (total === 0) {
        bay.state = 'built'; bay.activating = true; activationsStarted.add(name); note(`${name} built: ${bay.chests.length} chest(s), ${bay.modems.length} modem(s) -- activating`); save();
        // OFF THE TICK. Binding 20 chests is 20 detach/attach cycles with settle pauses -- minutes -- and
        // while it ran inside the tick nothing else was issued: the queue drained to 8 tasks and ten of
        // fourteen drones went idle (2026-09-08). The tick moves on; the result lands when it lands.
        // ONE AT A TIME: two bays activating together read each other's detach/attach into their name
        // diffs and both bound nothing (2026-09-08).
        activationChain = activationChain.then(() => activateBay(bay)).then((r) => {
          note(`${name} activated: ${r.registered} chest(s) registered, ${r.unnamed} modem(s) brought up nothing new`);
          bay.tries = (bay.tries ?? 0) + 1;
          // Active only when EVERY chest bound (or the retries are spent): unbound chests with every
          // cell in place mean the mesh is an island (no trunk to StorageMan's network). The SAME
          // unnamed count twice running is that island: toggling twenty modems again changes nothing
          // and each pass rescans StorageMan (2026-09-08).
          const same = bay.lastUnnamed === r.unnamed; bay.lastUnnamed = r.unnamed;
          // ...unless NOTHING bound: that is a bay nobody has wired up yet, and calling it active hides
          // it for good (level -2 ran two "active" bays with zero chests, 2026-09-08). Wait for the trunk.
          const island = (r.registered ?? 0) === 0 && r.unnamed > 0;
          if (island) { bay.tries = 0; bay.retryAt = Date.now() + 8 * 60_000; }   // a riser takes a while; no point toggling sooner
          else if (r.unnamed === 0 || (bay.tries ?? 0) >= 3 || same) bay.state = 'active' as any;
          // Chests that stay nameless with every cell laid are off StorageMan's network: the level's
          // trunk is the usual gap (a sweep short of cable leaves it in pieces). Order it again.
          if (r.unnamed > 0) void reorderTrunk(bay.level);
        }).catch((e) => { note(`${name} activation failed: ${String(e).slice(0, 120)}`); bay.tries = (bay.tries ?? 0) + 1; bay.retryAt = Date.now(); })   // back off: a failing activation every tick hammered StorageMan
          .finally(() => { bay.activating = false; activationsStarted.delete(name); save(); });
      } else {
        bay.state = 'built'; bay.missing = missing; bay.retryAt = Date.now();
        note(`${name}: task finished with ${total} cell(s) still open (${Object.entries(missing).map(([k, v]) => `${k.replace(/^.*:/, '')} ${v}`).join(', ')}) -- re-ordering when storage holds them`);
        save();
      }
    }
    // A BUILT BAY WITH OPEN CELLS IS NOT FINISHED. The build skipped what storage could not hand over
    // (21 cable cells short, sector 0; 15 chests short, sector 9; 2026-09-08). Order it again as soon as
    // storage holds any of what is missing: the builder skips the cells already right and lays the rest.
    // An island mesh (all cells right, chests unbound) gets three activations, then a person reads it.
    if (bay.state === 'built' && !bay.activating && Date.now() - (bay.retryAt ?? 0) > 120_000) {
      const missing = bay.missing ?? await bayMissing(bay);
      const open = Object.values(missing).reduce((a, b) => a + b, 0);
      if (open === 0) {
        if ((bay.tries ?? 0) >= 3) { bay.state = 'active' as any; note(`${name}: complete but ${bay.tries} activations bound nothing -- left for a person`); save(); continue; }
        bay.state = 'building'; bay.missing = undefined; save();   // through the built check again -> activation
        continue;
      }
      let have = 0;
      for (const item of Object.keys(missing)) have += await stockCount(item);
      if (have === 0) { bay.retryAt = Date.now(); continue; }   // nothing to lay yet; the economy has to make it
      const r: any = await tool('order.bay', { level: bay.level, sector: bay.sector, role: bay.role });
      const b0 = r?.bays?.[0];
      if (b0?.task != null) { bay.task = b0.task; bay.state = 'building'; bay.missing = undefined; bay.retryAt = Date.now(); note(`${name}: re-ordered for ${open} open cell(s)`); save(); }
      else bay.retryAt = Date.now();
    }
  }
}

async function tickBody(): Promise<{ acted: boolean; reason: string }> {
  boot.lastTick = Date.now();
  if (!boot.active) return { acted: false, reason: 'inactive' };
  if (!bridge.connected) return { acted: false, reason: 'bridge offline' };

  const fleet: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 5000 });
  const drones = luaList<any>(field(fleet, 'drones')) ?? [];
  const miners = drones.filter((d: any) => (d.role ?? 'miner') === 'miner' && !d.offline);
  const miner = miners[0];
  const scout = drones.find((d: any) => d.role === 'scout');
  if (!miner) return { acted: false, reason: 'no miner registered' };
  sizeQueues(miners.length);
  let idleMiners = miners.filter((d: any) => d.status === 'idle').length;
  const q = await queueNames();

  // Retire finished digs and advance the cursor past every completed chunk. A dig gone WITHOUT
  // finishing is re-issued (its chunk stays at the cursor); three such failures in a row stop the loop.
  boot.digs = boot.digs ?? [];
  if (boot.inflight) { boot.digs.push({ name: boot.inflight.name, from: boot.inflight.from, to: boot.inflight.to }); boot.inflight = null; }
  for (const f of [...boot.digs]) {
    if (named(q.live, f.name)) continue;
    boot.digs = boot.digs.filter((x) => x !== f);
    if (named(q.done, f.name)) {
      boot.attempts = 0;
      boot.dugSet = boot.dugSet ?? [];
      const ch = excavations().find((c) => c.name === (f.chunk ?? excavations()[f.from]?.name));
      // A clearing layer is done when the map holds no solid cell in it any more; otherwise it is
      // issued again with what the scout has found since.
      if (ch && ch.stage === 'floor-dig' && (await solidTargets(ch.boxes)).length > 0) {
        note(`dig ${f.name} finished but the map still shows solids in ${ch.name} -- another pass`);
        boot.digs = boot.digs.filter((x) => x !== f); save(); continue;
      }
      boot.dugSet.push(f.chunk ?? excavations()[f.from]?.name ?? String(f.from));
      note(`dig ${f.name} finished (dug ${boot.dugSet.length}/${excavations().length})`);
    } else {
      boot.attempts = (boot.attempts ?? 0) + 1;
      note(`dig ${f.name} is gone from the queue WITHOUT finishing (attempt ${boot.attempts}/${MAX_ATTEMPTS}) -- re-issuing`);
      // A chunk that keeps failing is SET ASIDE, not the reason to stop the whole fleet: three misses
      // parked three drones for good over one basement row (2026-09-08). It goes to the back of the
      // list and is retried after everything else.
      if (boot.attempts >= MAX_ATTEMPTS) {
        boot.deferred = boot.deferred ?? [];
        boot.deferCount = boot.deferCount ?? {};
        const key = f.chunk ?? f.name;
        boot.deferCount[key] = (boot.deferCount[key] ?? 0) + 1;
        boot.attempts = 0;
        if (boot.deferCount[key] >= 2) {
          // TWICE DEFERRED IS DONE ENOUGH. A row blocked by something permanent (a drone's dock, an
          // infrastructure block, a lava pocket) failed three times, was retried last, failed three
          // more, and level -4's lining waited on it for ever with every miner idle (2026-09-08). The
          // lining sweep digs what still stands in its own squares.
          boot.dugSet = boot.dugSet ?? []; if (f.chunk && !boot.dugSet.includes(f.chunk)) boot.dugSet.push(f.chunk);
          boot.deferred = boot.deferred.filter((c) => c !== f.chunk);
          note(`${key}: deferred twice -- counted as dug so the lining above it can proceed`);
        } else {
          if (f.chunk && !boot.deferred.includes(f.chunk)) boot.deferred.push(f.chunk);
          note(`deferring ${key}: it failed three times; the rest of the excavation continues and it is retried last`);
        }
      }
    }
    // The cursor is the first chunk neither done nor in flight.
    while (boot.dug < excavations().length && (boot.dugSet ?? []).includes(excavations()[boot.dug]!.name)) boot.dug += 1;
    for (const st of ['shaft', 'floor-dig', 'basement-dig'] as Stage[])
      if (!excavations().some((c) => c.stage === st && !(boot.dugSet ?? []).includes(c.name))) markStage(st);
    save();
  }
  boot.builds = boot.builds ?? [];
  if (boot.buildInflight) { boot.builds.push({ ...boot.buildInflight, dy: structure()[boot.buildInflight.from]?.dy ?? 0 }); boot.buildInflight = null; }
  for (const f of [...boot.builds]) {
    if (named(q.live, f.name)) continue;
    boot.builds = boot.builds.filter((x) => x !== f);
    unclaim(f.name);
    if (named(q.done, f.name)) { boot.built = Math.max(boot.built, f.to); note(`build ${f.name} finished (built ${boot.built}/${structure().length})`); }
    else note(`build ${f.name} is gone from the queue WITHOUT finishing -- its blocks stay in the plan`);
    for (const st of ['walls', 'roof', 'floor', 'basement'] as Stage[])
      if (!structure().some((b, i) => b.stage === st && i >= boot.built)) markStage(st);
    save();
  }
  // CLAIMS DIE WITH THEIR TASK. Build batches claimed their cells and nothing ever released them, so
  // every square a batch had once covered was "claimed" for good and the repair pass could never
  // touch it -- inspections found 67 and 99 wrong squares per course while repairs went out for 8
  // (2026-09-08). A claim lives exactly as long as its task is in the queue.
  if (boot.claimed) {
    const liveSet = new Set(q.live);
    for (const [cell, owner] of Object.entries(boot.claimed)) if (!liveSet.has(owner)) delete boot.claimed[cell];
  }
  // ── FUEL FLOOR (AUTHORIZED CHEAT). The user allowed fuel to be cheated in while the coal economy is
  // built; hand top-ups happened fifteen times tonight. Any drone under FUEL_FLOOR with a known position
  // is topped up over RCON once a minute, and every top-up is logged so the cheat stays visible.
  if (Date.now() - (boot.lastFuelPass ?? 0) > 60_000) {
    boot.lastFuelPass = Date.now();
    for (const d of drones) {
      const fuel = Number(d.fuel ?? NaN);
      const p = d.pos;
      if (!(fuel < FUEL_FLOOR) || !p || typeof p.x !== 'number') continue;
      try {
        const out = await rcon(`data merge block ${p.x} ${p.y} ${p.z} {Fuel:${FUEL_TOPUP}}`);
        if (/Modified/.test(out)) note(`CHEAT fuel: ${d.name} topped up to ${FUEL_TOPUP} at ${p.x},${p.y},${p.z} (had ${fuel})`);
      } catch (e) { note(`fuel top-up failed for ${d.name}: ${String(e).slice(0, 80)}`); }
    }
  }

  // ── BAYS FOLLOW THE STRUCTURE. When a level's lining is complete its bays are ordered one at a time
  // as materials allow: sorted storage on the basement levels (a checkerboard of single chests on
  // modems, cable between), the smeltery beside them in sector 10 until the smelt floor exists, the
  // floors above per LEVELS ("storage in the basement, more advanced factories as we move up" -- the
  // user, 2026-09-08). Chests, modems, furnaces and cable come from storage: cheated in today, crafted
  // by the economy loop tomorrow. Activation (modem peripheral state) is still an rcon step; a built
  // bay is reported in status until it is done.
  boot.bays = boot.bays ?? {};
  await tickBays(q);
  await orderNextBay(q);

  pruneRepairs(q);
  if (boot.scoutInflight && !named(q.live, boot.scoutInflight)) { boot.scoutInflight = null; save(); }
  // Inspections outstanding, one per scout: pruned as they leave the queue.
  // An inspection that left the queue stamps its course as seen; scouts always go to the course seen
  // longest ago ("move towards the oldest indexed blocks so it always rotates" -- the user, 2026-09-08).
  boot.courseSeen = boot.courseSeen ?? {}; boot.inspectingKeys = boot.inspectingKeys ?? {};
  for (const n of boot.inspecting ?? []) if (!named(q.live, n)) { const k = boot.inspectingKeys[n]; if (k) boot.courseSeen[k] = Date.now(); delete boot.inspectingKeys[n]; }
  boot.inspecting = (boot.inspecting ?? []).filter((n) => named(q.live, n));
  const scouts = drones.filter((d: any) => d.role === 'scout' && !d.offline);
  const idleScouts = scouts.filter((d: any) => d.status === 'idle').length;

  // The scout shadows the excavation: a survey box around the chunk being dug, re-queued whenever it
  // is idle, so the ore in the shaft walls enters the map while the miner is still beside it.
  // THE SCOUT IS THE FLEET'S EYES ON THE STRUCTURE. Each finished course in turn is swept by the
  // scout, looking only: what every cell holds goes to the shared map, and the repair pass sends a
  // miner for exactly the cells that are wrong. Miners do not sweep blind ("why would D3 know wall
  // damage it can't see -- D2 can scan", the user, 2026-09-08).
  // PATROLS: every idle scout gets the next course ("spawn 3 scouts which patrol the floors" -- the
  // user, 2026-09-08); at most one outstanding inspection per scout.
  if (idleScouts > 0 && boot.inspecting.length < scouts.length && !boot.scoutBuild && boot.built > 0
      && Date.now() - (boot.lastInspect ?? 0) > 5_000) {
    // Wall courses from the roof down first -- the course under the roof is where the interior
    // clearing once cut into the wall -- then the rest in build order.
    // Least recently seen first (never seen = oldest); among equals, wall courses under the roof first.
    // A never-inspected course counts as "seen 30 minutes ago": the finished ground-floor walls are
    // what the user looks at, and a dozen fresh basement courses must not push them out for an hour.
    const seenAt = (k: string) => boot.courseSeen![k] ?? (Date.now() - 30 * 60_000);
    const inFlight = new Set(Object.values(boot.inspectingKeys));
    const courses = finishedCourses().filter((c) => !inFlight.has(c.key)).sort((a, b) => {
      if (seenAt(a.key) !== seenAt(b.key)) return seenAt(a.key) - seenAt(b.key);
      const wa = a.key.startsWith('walls') ? 0 : 1, wb = b.key.startsWith('walls') ? 0 : 1;
      if (wa !== wb) return wa - wb;
      // lowest course first: the ground floor is what the user looks at; with the whole tower up,
      // "under the roof first" sent every scout to level 7 (2026-09-08)
      return wa === 0 ? Number(a.key.split(':')[1]) - Number(b.key.split(':')[1]) : 0;
    });
    if (courses.length) {
      const c = courses[0]!;
      // Only squares a scout can stand at: a slab square under a bay chest or a wall has no standing
      // cell, and a 1,163-square basement inspection skipped 63 of its first 81 and took a planner
      // leg for each (2026-09-08).
      const all = c.blocks.map((b) => withStand(b));
      const open = await reachableStands(c.blocks);
      const blocks = all.filter((_, i) => open.has(i));
      // Fewer than 8 reachable squares is not worth a trip: a one-square inspection cost 1,161 moves
      // and 1,257 fuel (2026-09-08). Stamp the course seen and move on.
      if (blocks.length < 8) { boot.courseSeen![c.key] = Date.now(); return { acted: false, reason: `inspect ${c.key}: ${blocks.length} reachable square(s), not worth a trip` }; }
      const name = unique(`${PREFIX}inspect-${c.key.replace(':', '-')}`);
      const r: any = await tool('order.blocks', { name, origin: settlement.base, blocks, priority: 3, sweep: true, inspect: true });
      if (r?.task != null) { boot.inspecting.push(name); boot.inspectingKeys[name] = c.key; boot.lastInspect = Date.now(); note(`inspect ${name}: a scout looks over ${blocks.length} square(s) (last seen ${seenAt(c.key) ? Math.round((Date.now() - seenAt(c.key)) / 60000) + ' min ago' : 'never'})`); save(); return { acted: true, reason: name }; }
    }
  }
  if (scout && scout.status === 'idle' && !boot.scoutInflight && !boot.scoutBuild && boot.built === 0) {
    const chunk = excavations()[Math.min(boot.dug, excavations().length - 1)];
    if (chunk) {
      const ys = chunk.boxes.map((x) => x.min.y), ye = chunk.boxes.map((x) => x.max.y);
      const cmin = { y: Math.min(...ys) }, cmax = { y: Math.max(...ye) };
      const name = unique(`${PREFIX}survey-${boot.dug}`);
      // TaskMan starts a survey at (min.x + radius, min.z + radius), so this box puts the scan START
      // on the tower's centre column -- open air above the shaft mouth, two blocks from the scout's
      // berth. A box centred on the chunk itself started the scout inside the north hillside, where
      // it had no route and flew into the rock until the jitter watch stopped it (2026-09-08).
      // The whole footprint, one scan cell at a time: a 3x3 grid of 16-block scans over the radius-21
      // disc, cycled, at surface height only (a box reaching the chunk's depth once sent the scout
      // down the shaft beyond GPS range). The map then knows what stands in every structure cell --
      // the logs and leaves inside walls and roof that a repair pass must replace (2026-09-08).
      void cmin; void cmax;
      const R = 8, b = settlement.base, GRID = [-14, 0, 14];
      const gi = (boot.surveyIdx ?? 0) % 9;
      boot.surveyIdx = gi + 1;
      const cx = b.x + GRID[Math.floor(gi / 3)]!, cz = b.z + GRID[gi % 3]!;
      const res: any = await tool('order.issue', { kind: 'explore', priority: 3, note: name,
        bounds: { min: { x: cx - R, y: b.y - 2, z: cz - R },
                  max: { x: cx + R, y: b.y + 10, z: cz + R } } });
      if (res?.dispatched) { boot.scoutInflight = `${res.id}:explore`; save(); }
    }
  }

  // THE SCOUT LAYS WALL TOO. It has no pickaxe but placing needs none, and the spoils chest is on
  // StorageMan's wire, so a build handed to it draws cobble from there (SecureBuildMaterials asks
  // storage for the shortfall). One drone digging while the other builds is the whole point of two.
  if (scout && scout.status === 'idle' && !boot.scoutBuild) {
    const s = structure();
    const nextBlock = s[boot.built];
    // NO PICKAXE, NO FLOOR. A slab replaces grass and dirt; the scout can only lay into air, and
    // handed 185 floor squares it walked every one to report "unreachable without a pickaxe" and the
    // batch was given up (2026-09-08, the user: "it has no pickaxe so it can't, why even bother").
    const buildable = nextBlock && (nextBlock.stage === 'walls' || nextBlock.stage === 'roof');
    if (buildable && !boot.buildInflight) {
      const inStore = await cobbleInStorage();
      if (inStore >= MIN_BUILD_BATCH / 2) {
        // THE SCOUT HAS NO PICKAXE. It can only lay a block whose cell and standing cell are open, so
        // it looks ahead through the rest of the current course and takes the open cells, as many as
        // the cobble in storage allows; buried ones stay for the miner, whose batches skip anything
        // already solid. Handed a buried stretch whole it jittered against dirt (2026-09-08).
        let to = boot.built;
        while (to < s.length && sameCourse(s[to]!, nextBlock!)) to++;
        const stretch = s.slice(boot.built, to);
        const open = await openCells(stretch);
        const blocks = stretch.filter((b, i) => open.has(i) && unclaimed(b)).slice(0, Math.min(inStore, MAX_BUILD_BATCH))
          .map(({ dx, dy, dz, item }) => ({ dx, dy, dz, item }));
        if (blocks.length >= MIN_BUILD_BATCH / 2) {          // a `return` here once skipped the miners' turn every tick (2026-09-08)
        const name = unique(`${PREFIX}${nextBlock!.stage}-${boot.built}-${to}`);
        try {
          const r: any = await tool('order.blocks', { name, origin: settlement.base, blocks, priority: 1 });
          if (r?.task != null) {
            claim(name, blocks);
            boot.scoutBuild = { name, from: boot.built, to, full: blocks.length === stretch.length };   // full only when the whole course was open
            note(`build ${name} for the scout: ${blocks.length} blocks from ${inStore} cobble in storage`);
            save();
            return { acted: true, reason: name };
          }
        } catch (e) { note(`scout build refused: ${String(e).slice(0, 120)}`); }
        }
      }
    }
  }
  if (boot.scoutBuild && !named(q.live, boot.scoutBuild.name)) {
    const f = boot.scoutBuild;
    if (named(q.done, f.name)) {
      if (f.full) boot.built = Math.max(boot.built, f.to);
      note(`build ${f.name} (scout) finished${f.full ? '' : ' (partial stretch: the miner fills the rest)'} (built ${boot.built}/${structure().length})`);
    }
    else note(`build ${f.name} (scout) gone without finishing -- its blocks stay in the plan`);
    unclaim(f.name);
    boot.scoutBuild = null; save();
  }


  const s = structure(), e = excavations();
  const stage = currentStage(boot.built, boot.dug);
  if (stage === 'done' && !boot.finishedAt) {
    // The clock stops here; the loop does not. Un-builds, the atrium, the quarry, inspections and
    // repairs carry on ("continuous automated development and expansion" -- the user, 2026-09-08).
    boot.finishedAt = Date.now(); note(`BENCHMARK COMPLETE in ${elapsed()}`); save();
  }
  // EVERYTHING BUILT AND DUG, NOTHING IN FLIGHT: the plan grows by one basement level (growPlan).
  if (planComplete(s, e) && growPlan()) return { acted: true, reason: 'plan grown' };

  // Material the miner can build with: what it carries plus what storage will hand it (the build
  // job fetches the shortfall from the wired spoils chests). Counting only the cargo sent the miner
  // digging for cobble while two hundred sat in the chest beside the shaft (2026-09-08).
  const aboard = miners.filter((d: any) => d.status === 'idle')
    .reduce((n: number, d: any) => n + Number(d.carrying?.[COBBLE] ?? d.inv?.[COBBLE] ?? 0), 0);
  const carried = aboard + await cobbleInStorage();
  const storageFree = await storageFreeSlots();
  const nextBlock = s[boot.built];
  const buildable = nextBlock && gateOpenFor(nextBlock, doneByName(boot.dugSet ?? []));
  const digsLeft = e.some((c) => c.stage !== 'quarry' && !(boot.dugSet ?? []).includes(c.name));

  // Build when there is enough aboard to be worth the trip, or when nothing is left to dig.
  let acted: string | null = null;
  const rep = await tryIssueRepair(carried, idleMiners);
  if (rep) { acted = rep; idleMiners = Math.max(0, idleMiners - 1); }
  const queuedEnd = Math.max(boot.built, ...(boot.builds ?? []).map((b) => b.to));
  const queuedDy = (boot.builds ?? [])[0]?.dy;
  const nextQueued = s[queuedEnd];
  // One slab course at a time (a slab batch pre-marks its cells solid and the next slab course would
  // stand on them); a WALL course is laid sideways from the room and may run alongside anything.
  if ((boot.builds ?? []).length < QUEUED_BUILDS && nextQueued && (queuedDy === undefined || (nextQueued.dy === queuedDy && nextQueued.stage === nextBlock!.stage) || !isFlat(nextQueued))
      && buildable && carried > 0 && (carried >= MIN_BUILD_BATCH || !digsLeft) && !boot.scoutBuild) {
    // One stage AND one course per batch (see sameCourse); further batches of the same course may
    // run alongside, from where the last queued one ends.
    const from = queuedEnd;
    let to = from;
    while (to < s.length && to - from < Math.min(carried, MAX_BUILD_BATCH) && sameCourse(s[to]!, s[from]!)) to++;
    // Only cells the map does not already hold solid: the scout's partial batches and earlier
    // courses fill squares the miner would otherwise walk to and skip ("walking along the walls
    // without placing", 2026-09-08).
    const stretch = s.slice(from, to);
    // Skip only cells that already HOLD the wanted material. "Skip solid" skipped the grass and dirt
    // the floor slab exists to replace, and floor batches shrank to one or two blocks (2026-09-08).
    const built = await builtCells(stretch);
    const blocks = stretch.filter((b, i) => !built.has(i) && unclaimed(b)).map(({ dx, dy, dz, item }) => ({ dx, dy, dz, item }));
    if (blocks.length === 0) {
      if ((boot.builds ?? []).length === 0) { boot.built = to; note(`walls ${from}-${to}: already solid per the map -- skipped`); save(); return { acted: true, reason: 'stretch already built' }; }
      boot.builds!.push({ name: `${PREFIX}noop`, from, to, dy: s[from]!.dy });   // retired next tick as "done" by absence? no: mark done now
      boot.builds = boot.builds!.filter((b) => b.name !== `${PREFIX}noop`); boot.built = Math.max(boot.built, to); save();
      return { acted: true, reason: 'stretch already built' };
    }
    const name = unique(`${PREFIX}${s[from]!.stage}-${from}-${to}`);
    // Every batch is a sweep: slabs from above, wall courses from the open side at their own height
    // (the room beside a wall is dug before its lining is ordered). The square-by-square builder laid
    // basement walls at 0.25 blocks/s; the sweep is one step per square (2026-09-08).
    const swept = blocks.map((b) => withStand({ ...b, stage: s[from]!.stage } as StagedBlock));
    const r: any = await tool('order.blocks', { name, origin: settlement.base, blocks: swept, priority: 1, sweep: true });
    if (r?.task == null) return { acted: false, reason: `order.blocks refused ${name}` };
    claim(name, blocks);
    boot.builds!.push({ name, from, to, dy: s[from]!.dy });
    note(`build ${name}: ${blocks.length} blocks (${aboard} cobble aboard, ${carried - aboard} in storage)`);
    save();
    idleMiners = Math.max(0, idleMiners - 1);
    acted = name;
  }

  const inFlightNames = new Set((boot.digs ?? []).map((d) => d.chunk ?? e[d.from]?.name));
  const doneNames = new Set(boot.dugSet ?? []);
  let issuedDig: string | null = null;
  // Keep the QUEUE full, not just the idle hands: TaskMan hands the next chunk to whichever miner
  // frees up, so a miner is never idle for want of a task (the user, 2026-09-08: "none should be
  // idle"). Up to QUEUED_DIGS chunks outstanding; the shaft column stays one at a time.
  // Scan the WHOLE list: the cursor is a hint, and it ran past the end while six chunks were still
  // unrecorded after the list was re-cut, leaving three drones idle at the floor stage (2026-09-08).
  for (let k = 0; k < e.length && (boot.digs ?? []).length < QUEUED_DIGS; k++) {
    const chunk = e[k]!;
    if (doneNames.has(chunk.name) || inFlightNames.has(chunk.name)) continue;
    // The quarry is dug for cobble only, and only while building work remains.
    // The quarry is gated on STORAGE ROOM only: every dug row is spoil into the shelf, and at 32 free
    // slots the next deposits would fail and the digs abort (2026-09-08). Below QUARRY_MIN_FREE the
    // miners build and repair instead; the bays coming online restore the room.
    void QUARRY_BELOW;
    if (chunk.stage === 'quarry' && storageFree < QUARRY_MIN_FREE) continue;
    // Deferred chunks wait until nothing else is left.
    if ((boot.deferred ?? []).includes(chunk.name) && e.some((c) => !doneNames.has(c.name) && !inFlightNames.has(c.name) && !(boot.deferred ?? []).includes(c.name))) continue;
    // One column, one miner: a shaft chunk waits for any dig in flight, and blocks the next.
    if (chunk.stage === 'shaft' && (boot.digs ?? []).length > 0) break;
    // The interior is cleared as soon as the shaft is done -- "the base is full of dirt and trees"
    // (the user, 2026-09-08); the basement follows in list order.
    if (await chunkIsOpen(chunk)) {
      boot.dugSet = boot.dugSet ?? []; boot.dugSet.push(chunk.name);
      while (boot.dug < e.length && (boot.dugSet ?? []).includes(e[boot.dug]!.name)) boot.dug += 1;
      note(`dig ${chunk.name}: already open per the map -- skipped`);
      save();
      continue;
    }
    // The interior clearing is a TARGET LIST: the cells of this layer the map knows to be solid, each
    // its own 1x1x1 box, visited nearest-first by the drone. Rows swept open air for a few dirt blocks.
    // order.dig takes at most 256 boxes: a target list is issued in slices, and the chunk is re-issued
    // with what the map still shows solid until nothing is left (the done check below).
    // An un-build goes by ROWS: the map never recorded most of the laid cavity slab as solid (one cell of
    // 237 came back), so a target list would leave the slab standing. The dig visits every cell.
    const boxes = chunk.stage === 'floor-dig' ? (await solidTargets(chunk.boxes)).slice(0, 256) : chunk.boxes;
    if (boxes.length === 0) {
      boot.dugSet = boot.dugSet ?? []; boot.dugSet.push(chunk.name);
      while (boot.dug < e.length && (boot.dugSet ?? []).includes(e[boot.dug]!.name)) boot.dug += 1;
      note(`dig ${chunk.name}: nothing solid in it per the map -- skipped`); save(); continue;
    }
    const name = unique(`${PREFIX}${chunk.name}`);
    // Rock is the filler, so it ranks LAST: with all but two miners on digs at priority 1, the level -2
    // trunk (default 2) waited 40 minutes for hands (2026-09-08 18:38).
    const r: any = await tool('order.dig', { name, priority: 3, boxes, unbuild: chunk.stage === 'unbuild' });
    if (r?.task == null) { note(`order.dig refused ${name}`); break; }
    boot.digs!.push({ name, from: k, to: k + 1, chunk: chunk.name });
    note(`dig ${name}: ${chunk.boxes.length} row(s), ${chunk.cells} blocks, task ${r.task}; ${carried} cobble available`);
    idleMiners = Math.max(0, idleMiners - 1);
    issuedDig = name;
    save();
    if (chunk.stage === 'shaft') break;
  }
  if (issuedDig) return { acted: true, reason: acted ? `${acted} + ${issuedDig}` : issuedDig };
  if (acted) return { acted: true, reason: acted };
  if ((boot.digs ?? []).length || (boot.builds ?? []).length || (boot.repairs ?? []).length) return { acted: false, reason: 'work in flight' };
  return { acted: false, reason: `stuck: stage ${stage}, ${carried} cobble available, nothing left to dig` };
}

export function startBootstrapLoop(intervalMs = 5_000) {
  setInterval(() => { runBootstrapTick().catch((e) => note(`tick failed: ${String(e).slice(0, 160)}`)); }, intervalMs).unref();
}

// ── tools ─────────────────────────────────────────────────────────────────────
registry.register({
  name: 'world.cell',
  summary: 'What the shared map holds for one cell: known air, known solid, or unknown, and its name if any.',
  description: 'Diagnostic: MapServer KnownAir + BlocksSolid + NamesAt for a single position.',
  params: z.object({ x: z.number().int(), y: z.number().int(), z: z.number().int() }).strict(),
  returns: '{ air, solid, name }',
  danger: 'read',
  handler: async (a) => {
    const positions = [{ x: a.x, y: a.y, z: a.z }];
    const air: any = await bridge.call('MapServer', 'KnownAir', { positions }, { timeoutMs: 10000 });
    const solid: any = await bridge.call('MapServer', 'BlocksSolid', { positions }, { timeoutMs: 10000 });
    const names: any = await bridge.call('MapServer', 'NamesAt', { positions }, { timeoutMs: 10000 });
    // silent: allow (an older MapServer without CellValues answers nothing; the other three fields still tell the story)
    const raw: any = await bridge.call('MapServer', 'CellValues', { positions }, { timeoutMs: 10000 }).catch(() => null);
    return { raw: (field(raw, 'cells') as any)?.['1'] ?? null, air: (luaList<number>(field(air, 'air')) ?? []).length > 0, solid: (luaList<number>(field(solid, 'solid')) ?? []).length > 0, name: (field(names, 'names') as any)?.['1'] ?? null };
  },
});
registry.register({
  name: 'bootstrap.reinspect',
  summary: 'Forget when courses were last inspected so the scouts take them next (course keys like "walls:1", or a prefix like "walls:").',
  description: 'Sets the courses\' last-seen stamp to never; the inspection rotation picks the oldest first.',
  params: z.object({ course: z.string() }).strict(),
  returns: 'The courses reset.',
  danger: 'mutate',
  // verify-at-effect: returns the keys actually removed from courseSeen
  handler: async (a) => {
    const hit: string[] = [];
    for (const k of Object.keys(boot.courseSeen ?? {})) if (k === a.course || k.startsWith(a.course)) { delete boot.courseSeen![k]; hit.push(k); }
    save();
    return { reset: hit };
  },
});
registry.register({
  name: 'bootstrap.repairdebug',
  summary: 'Why a course is or is not being repaired: known-air, wrong-name, claimed, covered, standing-cell-solid counts.',
  description: 'Diagnostic for the repair pass, per course key (e.g. "walls:1").',
  params: z.object({ course: z.string() }).strict(),
  returns: 'Counts per filter stage and a sample of the wrong squares.',
  danger: 'read',
  handler: async (a) => {
    const s = structure();
    const done = s.slice(0, boot.built);
    const idx = done.map((b, i) => [b, i] as const).filter(([b]) => `${b.stage}:${b.dy}` === a.course);
    const blocks = idx.map(([b]) => b);
    const air = await airCells(blocks); const wrong = await wrongMaterial(blocks);
    const cells = new Set(s.map((b) => `${b.dx}:${b.dy}:${b.dz}`));
    const bad = blocks.map((b, i) => ({ b, i })).filter(({ i }) => air.has(i) || wrong.has(i));
    const claimed = bad.filter(({ b }) => !unclaimed(b)).length;
    const covered = bad.filter(({ b }) => isFlat(b) && cells.has(`${b.dx}:${b.dy + 1}:${b.dz}`)).length;
    const stands = bad.map(({ b }) => { const w = withStand(b); return w.sx !== undefined ? { dx: w.sx, dy: b.dy, dz: w.sz!, item: b.item } : { dx: b.dx, dy: b.dy + 1, dz: b.dz, item: b.item }; });
    const standSolid = await solidCells(stands);
    return { course: a.course, squares: blocks.length, knownAir: air.size, wrongName: wrong.size, bad: bad.length, claimed, covered, standSolid: standSolid.size,
      sample: bad.slice(0, 5).map(({ b, i }) => ({ dx: b.dx, dy: b.dy, dz: b.dz, air: air.has(i), wrong: wrong.has(i) })) };
  },
});
registry.register({
  name: 'bootstrap.status',
  summary: 'The bootstrap benchmark: stage, progress, elapsed time, recent decisions.',
  description: 'One miner, one scout, no chests: shaft -> walls -> roof -> floor -> basement, timed end to end.',
  params: z.object({}).strict(),
  returns: 'active, stage, built/total, dug/total, elapsed, stage completion times, log tail.',
  danger: 'read',
  handler: async () => ({
    active: boot.active, stage: currentStage(boot.built, boot.dug),
    built: `${boot.built}/${structure().length}`, dug: `${(boot.dugSet ?? []).length}/${excavations().length}`,
    elapsed: elapsed(), startedAt: boot.startedAt, finishedAt: boot.finishedAt,
    stageDone: Object.fromEntries(Object.entries(boot.stageDone).map(([k, v]) =>
      [k, boot.startedAt ? `+${Math.round((v - boot.startedAt) / 1000)}s` : v])),
    inflight: boot.inflight, digs: boot.digs, builds: boot.builds, repair: boot.repairs, buildInflight: boot.buildInflight, scoutBuild: boot.scoutBuild, scoutInflight: boot.scoutInflight, inspecting: boot.inspecting, courseSeen: boot.courseSeen, bays: boot.bays, lastTick: boot.lastTick, lastReason: boot.lastReason,
    log: boot.log.slice(-15),
  }),
});

registry.register({
  name: 'bootstrap.start',
  summary: 'Start (or resume) the bootstrap benchmark loop.',
  description: 'reset:true starts the clock and cursors from zero; otherwise resumes where it stopped.',
  params: z.object({ reset: z.boolean().default(false), built: z.number().int().min(0).optional().describe('Set the build cursor (after the plan itself changed shape).'), inspectFrom: z.number().int().min(0).optional().describe('Restart the scouts\' inspection rotation at this course index (0 = the wall course under the roof).'), markDug: z.array(z.string()).optional().describe('Excavation chunk names to count as dug (rows verified open in the world that keep failing on a passing drone).') }).strict(),
  returns: 'The status.',
  danger: 'destructive',
  handler: async (a) => {
    if (a.built !== undefined) { note(`build cursor set ${boot.built} -> ${a.built} by hand`); boot.built = a.built; }
    if (a.inspectFrom !== undefined) { boot.inspectCourse = a.inspectFrom; note(`inspection rotation restarted at course ${a.inspectFrom}`); }
    if (a.markDug) { boot.dugSet = boot.dugSet ?? []; for (const c of a.markDug) if (!boot.dugSet.includes(c)) boot.dugSet.push(c); boot.deferred = (boot.deferred ?? []).filter((c) => !a.markDug!.includes(c)); note(`marked dug by hand: ${a.markDug.join(', ')}`); }
    if (a.reset) {
      // Our leftovers in TaskMan go first: a stale twin with the same name would be matched by prefix
      // as the new step and the loop would wait on a task no drone is running (2026-09-08).
      try { await tool('task.stopNamed', { prefix: PREFIX }); } catch { /* silent: allow (no queue to clear is the normal case on a first start) */ }
      boot.built = 0; boot.dug = 0; boot.inflight = null; boot.digs = []; boot.dugSet = []; boot.buildInflight = null; boot.builds = []; boot.repairInflight = null; boot.repairs = []; boot.scoutInflight = null; boot.scoutBuild = null; boot.stageDone = {}; boot.attempts = 0;
      boot.lastSurveyDug = -1;
      boot.startedAt = Date.now(); boot.finishedAt = null; boot.log = [];
    }
    if (!boot.startedAt) boot.startedAt = Date.now();
    boot.active = true; note(a.reset ? 'benchmark started' : 'benchmark resumed'); save();
    return tool('bootstrap.status', {});
  },
});

registry.register({
  name: 'bootstrap.stop',
  summary: 'Pause the bootstrap loop; in-flight tasks keep running.',
  description: 'Stops issuing new work. bootstrap.start resumes from the same cursors.',
  params: z.object({}).strict(),
  returns: 'The status.',
  danger: 'mutate',
  handler: async () => { boot.active = false; note('benchmark paused'); save(); return tool('bootstrap.status', {}); },
});
