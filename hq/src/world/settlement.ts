/**
 * WHERE THE SETTLEMENT IS. ONE DEFINITION, AND EVERYTHING ELSE DERIVES FROM IT.
 *
 * Re-founding the settlement 400 blocks away broke four separate things, and each failed silently
 * because every component was individually behaving correctly against a location nobody had told it
 * had changed:
 *
 *   supply.ts BASE      surveys aimed at ground the fleet could not reach
 *   city.ts ORIGIN      a mine planned at -35,81,-90, in a world that no longer exists
 *   MapServer bounds    every drone read as "outside coverage: unloaded chunk" and refused to move
 *   MapServer gpsHosts  22 phantom hosts, so coverage looked healthy and was imaginary
 *
 * None of those raised a fault. A plan was made, a drone accepted it, the dispatch succeeded, and
 * the destination was fiction. The only symptom was a fleet that would not move and a planner
 * reporting problems: ["none"].
 *
 * So the location is stated once, here, and pushed to the in-world modules on connect rather than
 * duplicated into them. The Lua side keeps a bootstrap default because it has to come up before
 * anything can tell it anything -- but that default is overwritten by the push, so the two cannot
 * stay out of step for longer than one connection.
 */

export interface Settlement {
  /** The tower's centre column, at ground level. */
  base: { x: number; y: number; z: number };
  /** How far from base the fleet may operate. Must stay inside the force-loaded chunks. */
  reach: number;
  /** The rednet repeater and how far it is heard: the fleet's radio horizon. */
  radio: Array<{ x: number; y: number; z: number; range: number }>;
  /** GPS hosts, as placed by bootstrap/gps.sh. */
  gpsHosts: Array<{ x: number; y: number; z: number }>;
}

export const settlement: Settlement = (() => {
  // ONE SOURCE OF TRUTH: the tower centre. Everything else is COMPUTED from it, so relocating the
  // settlement is a three-number change and never a hunt through hardcoded coordinate lists again
  // (the -480 world baked its 16 GPS hosts, its base and its bounds as literals in five places).
  const base = {
    x: Number(process.env.HIVE_BASE_X ?? 64),
    y: Number(process.env.HIVE_BASE_Y ?? 66),
    z: Number(process.env.HIVE_BASE_Z ?? 32),
  };
  // GPS: FOUR hosts in a plus on the tower roof, and nothing else. Two at the roof height, two four
  // blocks lower, so the four are never coplanar (an all-same-y set leaves altitude undetermined).
  // The roof is the cap level's ceiling: ground + (levels 0..7) * floorHeight. Hosts stay clear of
  // the centre column, which is the docking / shaft axis. A 22-host ring was the previous answer and
  // was pure overreach: two drones and one tower need four hosts within earshot, not twenty-two.
  const FLOORS_ABOVE_GROUND = 8, FLOOR_HEIGHT = 6, ARM = 2, DROP = 4;
  const roof = base.y + FLOORS_ABOVE_GROUND * FLOOR_HEIGHT;
  const gpsHosts = [
    { x: base.x,           y: roof,        z: base.z - ARM     },
    { x: base.x,           y: roof,        z: base.z + ARM + 1 },
    { x: base.x - ARM,     y: roof - DROP, z: base.z           },
    { x: base.x + ARM + 1, y: roof - DROP, z: base.z           },
    // Basement ring (#23-26, y61/63) -- near-coplanar, so alone it never fixed a drone underground.
    { x: base.x,      y: base.y - 3,  z: base.z + 16 },
    { x: base.x + 16, y: base.y - 5,  z: base.z      },
    { x: base.x - 16, y: base.y - 5,  z: base.z      },
    { x: base.x,      y: base.y - 3,  z: base.z - 16 },
    // Deep hosts (#37-39, y26) placed 2026-09-08 after D1 ran two hours without a fix and ended 25
    // blocks off its dead-reckoned pose. With these the basement geometry is three-dimensional.
    { x: base.x + 15, y: base.y - 40, z: base.z + 8  },
    { x: base.x - 15, y: base.y - 40, z: base.z - 8  },
    { x: base.x,      y: base.y - 40, z: base.z + 18 },
    { x: base.x,      y: base.y - 40, z: base.z - 18 },   // #41, 2026-09-09: below y0 only three deep hosts were in range
  ];
  // The rednet repeater on the GPS mast (bootstrap/repeater.sh): modem range grows with altitude
  // and CC:T uses the larger of the two ranges, so this is the one radio every drone must stay
  // within. ~93 blocks at y=116; 88 leaves a margin for the drone's own step. Without it, drones at
  // the 72-block reach were 79 blocks from MapServer and deaf (2026-09-08).
  // Two stations: the mast repeater (heard ~93 blocks at y=116) and the module row itself (64 at
  // ground level), which is what a drone at the bottom of the basement actually talks to.
  const radio = [
    { x: base.x, y: base.y + 50, z: base.z, range: Number(process.env.HIVE_RADIO_RANGE ?? 88) },
    { x: base.x, y: base.y + 2, z: base.z - 4, range: 60 },
    // Basement repeater (computer #35) outside the level -7 wall: MapServer's own modem reaches
    // ~y10 straight down and the deep basements' diggers went deaf below it (2026-09-08 18:33).
    { x: base.x + 13, y: base.y - 40, z: base.z, range: 60 },
  ];
  return { base, reach: Number(process.env.HIVE_REACH ?? 56), gpsHosts, radio };
})();

/** Inside the repeater's radio range in three dimensions -- the reach circle is horizontal only,
 *  and an ore seam fifty blocks down at the edge of it is out of earshot. */
export function withinRadio(p: { x: number; y: number; z: number }): boolean {
  return settlement.radio.some((r) => {
    const dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z;
    return dx * dx + dy * dy + dz * dz <= r.range * r.range;
  });
}

/** The stations as one scalar for the bounds push: MapServer's param validator rejects nested tables. */
export function radioParam(): string {
  return settlement.radio.map((r) => `${r.x},${r.y},${r.z},${r.range}`).join(';');
}

/**
 * Is this position inside the circle the fleet may work in?
 *
 * The BOX bounds the force-loaded chunks; the CIRCLE bounds what a drone can still call home from,
 * because modem range is a sphere and the box's corners sit half again as far out as its edges.
 * Work targets have to respect the circle -- the block index still holds positions surveyed when
 * the region was a square, so seeding a job straight from it sends drones to places they cannot be
 * heard from. D3 was recovered from -496,53,126, sixty-four blocks out, having been dispatched
 * there by an ordinary gather.
 */
export function withinReach(p: { x: number; z: number }): boolean {
  const { base, reach } = settlement;
  const dx = p.x - base.x, dz = p.z - base.z;
  return dx * dx + dz * dz <= reach * reach;
}

/** The box drones may move in. Derived, so it cannot disagree with base. */
export function bounds() {
  const { base, reach } = settlement;
  return {
    minx: base.x - reach, maxx: base.x + reach,
    miny: -64, maxy: 200,
    minz: base.z - reach, maxz: base.z + reach,
  };
}

/**
 * Tell MapServer where it is.
 *
 * Called on every bridge connect, not once at boot: MapServer restarts independently of HQ, and a
 * module that comes back holding a stale idea of the world paralyses every drone that asks it. The
 * call is idempotent and cheap, so doing it too often costs nothing and doing it too rarely costs
 * the fleet.
 */
export async function pushSettlement(
  call: (module: string, method: string, args: unknown, opts?: unknown) => Promise<unknown>,
): Promise<{ bounds: boolean; boundsError: string | null; hosts: number; expected: number; failed: string[] }> {
  let ok = false;
  let boundsError: string | null = null;
  try {
    // Send the RADIUS as well as the box. The box bounds the force-loaded chunks; the radius bounds
    // what a drone can still call home from. A square region of reach 56 has edges ~60 blocks from
    // the mast and corners ~82 -- past the 64-block modem range -- so its corners were places a
    // drone could legally walk into and then never be heard from again. Two drones died in them.
    await call('MapServer', 'bounds',
      { ...bounds(), reach: settlement.reach,
        cx: settlement.base.x, cy: settlement.base.y, cz: settlement.base.z,
        radio: radioParam() },
      { timeoutMs: 8000 });
    ok = true;
  } catch (err) {
    // A failed push must not take HQ down -- but `bounds: false` on its own is not a report, it is
    // a flag, and the host loop below already sets the standard for this file by NAMING what is
    // still missing rather than shrinking a count. A bounds push that never landed means MapServer
    // is holding a stale region while drones ask it whether they may step, so the reason it failed
    // is the difference between "retry in a moment" and "the module is wedged".
    boundsError = (err as Error)?.message ?? String(err);
  }

  // ONE HOST FAILING IS NOT A REASON TO SKIP THE REST -- BUT IT IS NOT A REASON TO FORGET IT EITHER.
  //
  // This used to swallow the error and return only a success count, and exactly one host went
  // missing every time: the FIRST, which lands while MapServer is still busy writing the bounds
  // change pushed a line earlier, and times out. The push then reported "gpsHosts=15" with nothing
  // to compare 15 against, so a constellation permanently one host short looked like a clean push.
  //
  // A single retry after the write settles fixes the actual cause; naming what is still missing
  // makes the residue visible instead of quietly shrinking the constellation.
  const pending: typeof settlement.gpsHosts = [];
  let hosts = 0;
  for (const h of settlement.gpsHosts) {
    try {
      await call('MapServer', 'gpshost', { pos: [h.x, h.y, h.z] }, { timeoutMs: 8000 });
      hosts++;
    } catch { pending.push(h); }
  }
  const failed: string[] = [];
  for (const h of pending) {
    try {
      await call('MapServer', 'gpshost', { pos: [h.x, h.y, h.z] }, { timeoutMs: 8000 });
      hosts++;
    } catch { failed.push(`${h.x},${h.y},${h.z}`); }
  }
  return { bounds: ok, boundsError, hosts, expected: settlement.gpsHosts.length, failed };
}

/**
 * THE MODULE STATIONS, derived from the base exactly as bootstrap placed them (scratchpad
 * stations.sh, 2026-09-08): a square ring of radius 7 around the centre at ground level, each
 * station a 3-wide x 4-tall advanced monitor (y base+1..base+4) with its computer beside it at
 * base+2 and a wireless modem on top. "Left" is as seen by someone in the room facing the wall.
 * `origin` is the monitor block at the panel's top-left as seen from the front (monitor-space
 * xIndex 0 / yIndex 0), which is what a renderer needs to lay text on it.
 */
export interface Station {
  label: string;
  facing: 'north' | 'south' | 'east' | 'west';
  computer: { x: number; y: number; z: number };
  origin: { x: number; y: number; z: number };
  width: number;
  height: number;
}
export function stations(): Station[] {
  const b = settlement.base, R = 7, top = b.y + 4, cy = b.y + 2;
  const N = b.z - R, E = b.x + R, W = b.x - R;
  const st = (label: string, facing: Station['facing'], cx: number, cz: number, ox: number, oz: number): Station =>
    ({ label, facing, computer: { x: cx, y: cy, z: cz }, origin: { x: ox, y: top, z: oz }, width: 3, height: 4 });
  return [
    // North wall faces south: viewer-left is west, so the panel's left edge is its lowest x.
    st('MainFrame', 'south', b.x + 1, N, b.x - 2, N),
    st('DroneMan',  'south', b.x - 3, N, b.x - 6, N),
    st('TaskMan',   'south', b.x + 5, N, b.x + 2, N),
    // East wall faces west: viewer-left is north, the panel's left edge is its lowest z.
    st('MapServer',  'west', E, b.z - 2, E, b.z - 5),
    st('DockingMan', 'west', E, b.z + 4, E, b.z + 1),
    // West wall faces east: viewer-left is south, the panel's left edge is its HIGHEST z.
    st('StorageMan', 'east', W, b.z - 5, W, b.z - 2),
    st('Bridge',     'east', W, b.z + 1, W, b.z + 4),
  ];
}
