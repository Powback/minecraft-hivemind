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
  // 68 is the radius at which all four nearest hosts of the 16-host constellation are still audible,
  // less a margin so a drone stops before losing its fix rather than after.
  reach: Number(process.env.HIVE_REACH ?? 68),
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
): Promise<{ bounds: boolean; hosts: number }> {
  let ok = false;
  try {
    await call('MapServer', 'bounds', bounds(), { timeoutMs: 8000 });
    ok = true;
  } catch { /* reported by the caller; a failed push must not take HQ down */ }

  let hosts = 0;
  for (const h of settlement.gpsHosts) {
    try {
      await call('MapServer', 'gpshost', { pos: [h.x, h.y, h.z] }, { timeoutMs: 8000 });
      hosts++;
    } catch { /* one host failing is not a reason to skip the rest */ }
  }
  return { bounds: ok, hosts };
}
