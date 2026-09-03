import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { endpointsOf, readsOf } from '../scripts/wiring.mjs';

const FILES = ['TaskMan', 'DroneMan', 'DockingMan', 'StorageMan', 'MapServer', 'MainFrame']
  .map((m) => join(__dirname, `../../lua/${m}.lua`));
const baseline = JSON.parse(readFileSync(join(__dirname, '../wiring-baseline.json'), 'utf8'));

/**
 * A FIELD THE HANDLER READS BUT THE ENDPOINT DOES NOT DECLARE NEVER ARRIVES.
 *
 * PowNet passes the payload through untouched when an endpoint declares no `params` block at all --
 * MapServer.UpdatePath has none and carries the whole world index. The trap is the HALF-declared
 * endpoint: once a spec exists, anything missing from it is dropped, silently, and the call still
 * returns success.
 *
 * That is not theoretical. order.build passed `dependsOn` to TaskMan.Add from the day it was
 * written; TaskMan never declared it; so no build ever waited for its materials, for months, while
 * every call reported fine. It was found only by adding a temporary probe that printed the keys
 * that actually arrived.
 *
 * This is the "written but never wired" failure in its cheapest-to-catch form: four layers declare
 * a capability -- HQ tool, endpoint spec, handler, caller -- each reports success independently, so
 * a half-wired feature is indistinguishable from a working one until you check the world.
 */
describe('endpoints declare every field their handler reads', () => {
  const found: string[] = [];
  for (const f of FILES) {
    const { text, endpoints } = endpointsOf(f);
    for (const e of endpoints) {
      if (!e.filtered) continue;              // no spec: nothing is filtered, nothing can be lost
      const reads = readsOf(text, e.handler);
      if (!reads) continue;
      const undeclared = reads.filter((r) => !e.declared.includes(r));
      if (undeclared.length) {
        found.push(`${f.split('/').pop()}:${e.endpoint}:${undeclared.sort().join('+')}`);
      }
    }
  }
  found.sort();

  it('no NEW endpoint reads a field it never declared', () => {
    const known = new Set(baseline.halfWired);
    expect(found.filter((x) => !known.has(x)),
      'This field will be silently dropped by PowNet and the call will still succeed.\n' +
      'Declare it in the endpoint\'s `params`, or stop reading it.').toEqual([]);
  });

  /** May fall, may not rise -- the same ratchet the complexity budget uses. */
  it('the debt only shrinks', () => {
    expect(found.length).toBeLessThanOrEqual(baseline.halfWired.length);
  });
});
