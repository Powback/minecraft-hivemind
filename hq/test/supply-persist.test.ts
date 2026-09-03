import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const supply = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');

/**
 * A FIELD THE STATE CLAIMS TO KEEP MUST ACTUALLY BE WRITTEN.
 *
 * saveSupply persisted a hand-picked `{ enabled, rules, dispatched }`, so every field added to
 * SupplyState afterwards existed in the type and nowhere on disk. `frontier` carries the comment
 * "Persisted -- see frontier()" and never was. `towerLevel` and `towerBatch` meant each HQ restart
 * reset the tower to the ground floor and forgot which floor it was measuring -- so the level could
 * never advance across a redeploy, while the code that advances it worked perfectly. Nothing
 * reported a thing: the write succeeded, it just wrote less than it claimed.
 *
 * A whitelist that must be edited whenever state is added is a silent drop waiting to happen, so
 * the rule is inverted: persist everything, and name what is deliberately excluded.
 */
describe('supply state persists what it says it persists', () => {
  const fn = (() => {
    const i = supply.indexOf('export function saveSupply');
    if (i < 0) throw new Error('saveSupply is gone -- move this assertion, do not delete it');
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  })();

  it('writes the whole state rather than a hand-picked subset', () => {
    expect(fn).toMatch(/\.\.\.persisted/);
    expect(fn).not.toMatch(/\{ enabled: supply\.enabled, rules: supply\.rules/);
  });

  it('excludes only what is meaningless after a restart, by name', () => {
    expect(fn).toMatch(/log: _log/);          // rolling display buffer
    expect(fn).toMatch(/cooldowns: _cooldowns/); // wall-clock timers
  });

  /**
   * The fields whose loss actually stalled the tower. Asserted against CODE ONLY: the comment
   * above saveSupply names them as the motivating failure, and matching raw text would fail on a
   * correct file -- the same trap that made an earlier guard match `turtle.placeDown()` inside its
   * own comment.
   */
  it('keeps the towers place across a restart', () => {
    const code = fn.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    expect(code).not.toMatch(/towerLevel|towerBatch/);  // not excluded => included by the spread
  });
});

/**
 * A ROUND TRIP HAS TWO HALVES, AND CHECKING ONE OF THEM PROVED NOTHING.
 *
 * Everything above was true and the tower still reset to the ground floor on every redeploy, because
 * loadSupply read five fields by name. `towerLevel` was written to disk perfectly and thrown away on
 * the way back in -- measured directly: supply.json holding `towerLevel: 2` while the running loop
 * reported 0. Fixing the save side moved the drop one step later rather than removing it, and this
 * suite went on passing throughout, which is what made it survive.
 *
 * So the rule is asserted in BOTH directions, and the test that only watched one half is the reason.
 */
describe('supply state survives the trip back in', () => {
  const load = (() => {
    const i = supply.indexOf('function loadSupply');
    if (i < 0) throw new Error('loadSupply is gone -- move this assertion, do not delete it');
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  })();
  const code = load.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');

  it('reads the whole file rather than a hand-picked subset', () => {
    expect(code).toMatch(/\.\.\.carried/);
  });

  it('excludes only what is rebuilt or re-derived, by name', () => {
    expect(code).toMatch(/log: _log/);
    expect(code).toMatch(/cooldowns: _cooldowns/);
  });

  /** The two fields whose loss restarted the tower. Not named as exclusions => carried by the spread. */
  it('carries the towers place back in', () => {
    expect(code).not.toMatch(/towerLevel|towerBatch/);
  });

  /** Wiping the settlement's policy and progress is not something that may happen quietly. */
  it('says so when the state file exists but cannot be read', () => {
    expect(code).toMatch(/ENOENT/);          // a first run is not a failure...
    expect(code).toMatch(/console\.warn/);   // ...anything else is, and it is reported
  });
});
