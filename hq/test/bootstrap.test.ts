/**
 * The bootstrap benchmark's geometry and gating. Structure and excavations derive from tower.ts and
 * the settlement, so this pins the RULES -- the design's walls and slabs in cobble, digs as rows of
 * the disc that never leave the circle, chunks a turtle can carry, stages gated on their excavation.
 */
import { describe, it, expect } from 'vitest';
import { RING, MARK, structure, excavations, currentStage, rowsOf, inCavity } from '../src/agent/bootstrap.js';
import { settlement } from '../src/world/settlement.js';
import { towerFloor, specForLevel, discCells } from '../src/world/tower.js';

const pal = MARK;
const sp = specForLevel(0);
const f0 = towerFloor(sp, 0, pal);
const H = sp.floorHeight;

describe('bootstrap structure (the design, in cobble)', () => {
  const s = structure();
  it('walls are exactly the design\'s wall and slit cells of level 0, as cobblestone', () => {
    const walls = s.filter((b) => b.stage === 'walls' && b.dy < H);   // level 0; the growth plan appends the storeys above
    const design = f0.filter((b) => b.item === pal.wall || b.item === pal.window);
    expect(walls.length).toBe(design.length);
    expect(walls.every((b) => b.item === 'minecraft:cobblestone')).toBe(true);
    const key = (b: any) => `${b.dx}:${b.dy}:${b.dz}`;
    expect(new Set(walls.map(key))).toEqual(new Set(design.map(key)));
  });
  it('the roof is level 1\'s slab one storey up, atrium left open', () => {
    const roof = s.filter((b) => b.stage === 'roof' && b.dy === H);   // level 1's slab; higher roofs follow in the growth plan
    const slab = towerFloor(specForLevel(1), 1, pal).filter((b) => b.item === pal.slab && b.dy === 0 && !inCavity(b));
    expect(roof.length).toBe(slab.length);
    expect(roof.every((b) => b.dy === H)).toBe(true);
    expect(roof.some((b) => b.dx === 0 && b.dz === 0)).toBe(false);
  });
  it('the floor is level 0\'s slab and parapet; stairs and the barrel are left for a crafter', () => {
    const floor = s.filter((b) => b.stage === 'floor');
    // slab squares a wall stands on are not part of the plan: under cobble for good, unreachable
    const underWall = new Set(f0.filter((b) => b.dy === 1 && b.item === pal.wall).map((b) => `${b.dx}:${b.dz}`));
    expect(floor.length).toBe(f0.filter((b) => (b.item === pal.slab && b.dy === 0 && !underWall.has(`${b.dx}:${b.dz}`) && !inCavity(b)) || b.item === pal.shaft).length);
    expect(s.some((b) => b.item === pal.stair || b.item === pal.barrel)).toBe(false);
  });
  it('the basement is level -1 one storey down, slab before walls', () => {
    const base = s.filter((b) => b.stage === 'basement');
    expect(base[0]!.dy).toBe(-H);
    const firstWall = base.findIndex((b) => b.dy > -H);
    expect(base.slice(0, firstWall).every((b) => b.dy === -H)).toBe(true);
    expect(Math.max(...base.map((b) => b.dy))).toBe(-1);
  });
  it('stages are contiguous and in build order', () => {
    expect([...new Set(s.map((b) => b.stage))]).toEqual(['walls', 'roof', 'floor', 'basement']);
  });
});

describe('bootstrap excavations (rows of the disc)', () => {
  const e = excavations();
  const b = settlement.base;
  const cellsOf = (chunks: typeof e) => {
    const set = new Set<string>();
    for (const c of chunks) for (const box of c.boxes)
      for (let x = box.min.x; x <= box.max.x; x++) for (let z = box.min.z; z <= box.max.z; z++) set.add(`${x - b.x}:${z - b.z}`);
    return set;
  };
  it('rowsOf splits a ring row into its two runs', () => {
    expect(rowsOf([{ dx: -3, dz: 0 }, { dx: -2, dz: 0 }, { dx: 2, dz: 0 }, { dx: 3, dz: 0 }]))
      .toEqual([{ dz: 0, x0: -3, x1: -2 }, { dz: 0, x0: 2, x1: 3 }]);
  });
  it('the shaft runs from the surface to the cobble limit, 3x3', () => {
    const shaft = e.filter((c) => c.stage === 'shaft');
    expect(shaft[0]!.boxes[0]!.max.y).toBe(b.y - 1);
    expect(shaft[shaft.length - 1]!.boxes[0]!.min.y).toBe(RING.shaftBottom);
    expect(shaft.every((c) => c.boxes[0]!.max.x - c.boxes[0]!.min.x === 2 * RING.shaftHalf)).toBe(true);
  });
  it('interior rows never include a structure cell (the inner skin stands inside the disc)', () => {
    const walls = new Set(f0.filter((x) => x.item === pal.wall || x.item === pal.window).map((x) => `${x.dx}:${x.dy}:${x.dz}`));
    for (const c of e.filter((x) => x.stage === 'floor-dig')) for (const box of c.boxes)
      for (let x = box.min.x; x <= box.max.x; x++) for (let z = box.min.z; z <= box.max.z; z++)
        expect(walls.has(`${x - b.x}:${box.min.y - b.y}:${z - b.z}`)).toBe(false);
  });
  it('the basement dig is the whole footprint one storey down', () => {
    const base = e.filter((c) => c.stage === 'basement-dig');
    expect(cellsOf(base)).toEqual(new Set(discCells(sp.radius).map((c) => `${c.dx}:${c.dz}`)));
    expect(Math.min(...base.flatMap((c) => c.boxes.map((x) => x.min.y)))).toBe(b.y - H);
  });
  it('no chunk exceeds what a turtle carries without unloading', () => {
    for (const c of e) expect(c.cells).toBeLessThanOrEqual(RING.chunkCells);
    for (const c of e) {
      let v = 0;
      for (const x of c.boxes) v += (x.max.x - x.min.x + 1) * (x.max.y - x.min.y + 1) * (x.max.z - x.min.z + 1);
      expect(v).toBe(c.cells);
    }
  });
  it('are ordered shaft, interior (issued only once the roof is on), basement -- no wall trench', () => {
    expect([...new Set(e.map((c) => c.stage))]).toEqual(['shaft', 'floor-dig', 'unbuild', 'basement-dig', 'quarry']);
  });
});

describe('stage gating', () => {
  const s = structure(), e = excavations();
  const upTo = (stage: string) => e.filter((c, i) => i <= e.map((x) => x.stage).lastIndexOf(stage as any)).length;
  it('walls need no excavation finished', () => expect(currentStage(0, 0)).toBe('walls'));
  it('the floor waits for the interior to be cleared', () => {
    const firstFloor = s.findIndex((b) => b.stage === 'floor');
    expect(currentStage(firstFloor, upTo('shaft'))).toBe('floor-dig');
    expect(currentStage(firstFloor, upTo('floor-dig'))).toBe('floor');
  });
  it('the basement lining waits for the basement dig', () => {
    const firstBase = s.findIndex((b) => b.stage === 'basement');
    expect(currentStage(firstBase, upTo('shaft'))).toBe('basement-dig');
    expect(currentStage(firstBase, e.length)).toBe('basement');
  });
  it('is done when every block is built', () => expect(currentStage(s.length, e.length)).toBe('done'));
});
