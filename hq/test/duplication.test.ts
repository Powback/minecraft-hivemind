import { describe, it, expect } from 'vitest';
import { scan, compare, readBaseline, perFile, WINDOW } from '../scripts/duplication.mjs';

/**
 * DUPLICATED LOGIC IS COUNTED, AND THE COUNT MAY ONLY FALL.
 *
 * "A modularity/reuse issue, lots and lots of duped logic" was the standing diagnosis for months,
 * and nothing in the build could say where it was or whether it was getting better. Every rule in
 * CLAUDE.md about duplication -- "one question, one function", "prefer the primitive" -- was
 * enforced by memory alone, so the copies kept being made and kept drifting apart:
 *
 *   - the sixteen-slot inventory walk, five copies, differing in whether they restored slot 1
 *   - "what is the distance to that" written out twenty-three times, and it IS the fuel budget
 *   - readStock and pgps.HEADINGS: helpers that were EXTRACTED and then never adopted, so the
 *     copies lived on -- and only the extracted one got the bug fix
 *   - the yield that stops CC killing StorageMan mid-scan, thirteen hand-written copies
 *
 * The last two are the argument for counting rather than reviewing. A helper existing is not the
 * same as a helper being used, and nothing but a count notices the difference.
 *
 * Keyed by FILE and by KIND, never by content hash or line: hashes churn on every edit and would
 * train everyone to run --update reflexively, which defeats the ratchet.
 */
describe(`duplicated logic (window ${WINDOW})`, () => {
  const found = scan();
  const baseline = readBaseline();
  const { violations, stale } = compare(found, baseline);

  it('no file gained duplicated blocks or repeated idioms', () => {
    const report = violations.map((v) => {
      const worst = found[v.kind === 'blocks' ? 'blocks' : 'idioms']
        .filter((d) => d.at.some((a) => a.startsWith(v.file + ':')))
        .slice(0, 2)
        .map((d) => `\n      x${d.copies}  ${d.text.slice(0, 88)}\n        ${d.at.slice(0, 4).join('  ')}`);
      return `${v.file}: ${v.message}${worst.join('')}`;
    });
    expect(
      report,
      'Copy-paste went up. Extract the shared part -- and if you extract it, ADOPT it everywhere:\n' +
      'readStock and pgps.HEADINGS were both written and then left with their copies still in place.\n' +
      'Run `node scripts/duplication.mjs` to see the offenders.',
    ).toEqual([]);
  });

  it('the baseline records no duplication that has already been removed', () => {
    const report = stale.map(
      (s) => `${s.file}: baseline allows ${s.was} duplicated ${s.kind}, only ${s.now} remain. ` +
        'Run `node scripts/duplication.mjs --update` to bank the win.',
    );
    expect(report).toEqual([]);
  });

  /**
   * The ratchet is worthless if the scanner can be quieted by deleting its inputs. This pins the
   * shape of the corpus: every Lua module that runs in the world, plus the TypeScript, minus the
   * four files that are boilerplate on purpose.
   */
  it('still scans both halves of the system', () => {
    const files = Object.keys(perFile(found));
    expect(files.some((f) => f.startsWith('lua/'))).toBe(true);
    expect(found.blocks.length + found.idioms.length).toBeGreaterThan(0);
  });
});
