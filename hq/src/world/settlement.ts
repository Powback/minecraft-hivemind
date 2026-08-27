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
  /** GPS hosts, as placed by bootstrap/gps.sh. */
  gpsHosts: Array<{ x: number; y: number; z: number }>;
}

export const settlement: Settlement = {
  base: {
    x: Number(process.env.HIVE_BASE_X ?? -480),
    y: Number(process.env.HIVE_BASE_Y ?? 63),
    z: Number(process.env.HIVE_BASE_Z ?? 64),
  },
  // MEASURED, NOT CHOSEN. The bounds were 96 while four-host GPS coverage was 32 -- so the fleet was
  // authorised to work in an area NINE TIMES larger than it could navigate in, and every drone sent
  // to the edge stranded with "outside coverage: no gps coverage" while nothing had actually failed.
  // Two limits, and the tighter one wins. GPS coverage allows 68. RADIO does not: every module sits
  // in the tower, a drone must reach the mast repeater to be heard at all, and 56 is the radius at
  // which both a ground drone and one cruising at y=110 stay inside modem range of it. A drone
  // beyond that is not lost -- it is working perfectly and cannot tell anyone, which reads as lost
  // and is worse.
  reach: Number(process.env.HIVE_REACH ?? 56),
  gpsHosts: [
    { x: -546, y: 70, z: -2 },
    { x: -546, y: 83, z: 42 },
    { x: -546, y: 96, z: 86 },
    { x: -546, y: 78, z: 130 },
    { x: -502, y: 91, z: -2 },
    { x: -502, y: 73, z: 42 },
    { x: -502, y: 86, z: 86 },
    { x: -502, y: 99, z: 130 },
    { x: -458, y: 81, z: -2 },
    { x: -458, y: 94, z: 42 },
    { x: -458, y: 76, z: 86 },
    { x: -458, y: 89, z: 130 },
    { x: -414, y: 71, z: -2 },
    { x: -414, y: 84, z: 42 },
    { x: -414, y: 97, z: 86 },
    { x: -414, y: 79, z: 130 },
  ],
};

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
): Promise<{ bounds: boolean; hosts: number; expected: number; failed: string[] }> {
  let ok = false;
  try {
    // Send the RADIUS as well as the box. The box bounds the force-loaded chunks; the radius bounds
    // what a drone can still call home from. A square region of reach 56 has edges ~60 blocks from
    // the mast and corners ~82 -- past the 64-block modem range -- so its corners were places a
    // drone could legally walk into and then never be heard from again. Two drones died in them.
    await call('MapServer', 'bounds',
      { ...bounds(), reach: settlement.reach,
        cx: settlement.base.x, cy: settlement.base.y, cz: settlement.base.z },
      { timeoutMs: 8000 });
    ok = true;
  } catch { /* reported by the caller; a failed push must not take HQ down */ }

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
  return { bounds: ok, hosts, expected: settlement.gpsHosts.length, failed };
}
