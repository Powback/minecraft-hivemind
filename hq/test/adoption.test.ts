import { describe, it, expect } from 'vitest';
import { scan, compare, readBaseline, perFile, RUN } from '../scripts/adoption.mjs';

/**
 * A HELPER THAT EXISTS BUT IS NOT USED EVERYWHERE IS WORSE THAN NO HELPER AT ALL.
 *
 * This is the defect that kept coming back for ten days, and it is not a bug -- it is a shape:
 *
 *   somebody extracts a helper, writes a good comment about why, converts ONE call site,
 *   and stops. The comment now reads as if the job is done. Months later a bug is found and
 *   fixed in whichever copy the reporter was standing in, and the others keep it.
 *
 * It is invisible to every other check here. The tests pass, the extraction looks complete, and
 * the copies fail somewhere else, later, as what looks like a brand-new bug. Measured, in this
 * repo, by this check:
 *
 *   readStock          extracted with a comment saying the eight lines "were written out three
 *                      times" -- ONE of four call sites adopted it. The three survivors never got
 *                      luaList(), so an object-shaped stock list threw inside their own catch and
 *                      the planner silently concluded the settlement owned nothing.
 *   pgps.HEADINGS      "so callers stop writing their own copy of the mapping" -- three if/elseif
 *                      ladders still answered it, in the module where a wrong heading strands drones.
 *   abortAssigned      "One function because this exact pcall was written out SEVEN times" -- and
 *                      four call sites went on doing it by hand.
 *
 * Each of those was written by someone who had just finished deduplicating and believed it.
 * Nothing but a machine notices the difference between extracted and adopted.
 */
describe(`helpers must be adopted, not just extracted (run ${RUN})`, () => {
  const found = scan();
  const baseline = readBaseline();
  const { violations, stale } = compare(found, baseline);

  it('no file gained a re-implementation of a helper that already exists', () => {
    const report = violations.map((v) => {
      const worst = found
        .filter((f) => f.copies.some((c) => c.startsWith(v.file + ':')))
        .slice(0, 3)
        .map((f) => `\n      ${f.helper}() at ${f.at} is re-implemented at ${f.copies.join(', ')}`);
      return `${v.file}: ${v.message}${worst.join('')}`;
    });
    expect(
      report,
      'Something re-implements a function that already exists. Call it instead.\n' +
      'This is the shape that keeps coming back: the helper gets written, one call site adopts it,\n' +
      'the rest drift, and the next bug fix lands in only one of them.\n' +
      'Run `node scripts/adoption.mjs` to see both locations.',
    ).toEqual([]);
  });

  it('the baseline records no copy that has already been adopted', () => {
    const report = stale.map(
      (s) => `${s.file}: baseline allows ${s.was} unadopted copies, only ${s.now} remain. ` +
        'Run `node scripts/adoption.mjs --update` to bank the win.',
    );
    expect(report).toEqual([]);
  });

  /**
   * A CHECK THAT CANNOT FAIL IS NOT A CHECK, AND THIS EXACT ROT HAPPENED THREE TIMES IN ONE DAY.
   *
   * Folding duplicated loops into helpers made `lua-hygiene`'s "bulk chest write must call
   * ReportChest" rule and `lua-traps`' peripheral-yield rule stop matching anything -- because both
   * scanned for a literal call (`PutDown(`, `peripheral.wrap`) that had just been moved behind a
   * new name. The rules did not fail. They went quiet, which is far worse: the wrap one guards the
   * storage server against being killed mid-scan, and it would have been silently switched off.
   *
   * So this check proves it is still alive against a planted duplicate, the same way `hive.plan` is
   * trusted over a tool's own `ok: true`. Verify at the effect, never at the call -- including for
   * the verifier.
   */
  const body = [
    '    local s_A = turtle.getItemCount(p_Slot)',
    '    if s_A == 0 then return nil end',
    '    turtle.select(p_Slot)',
    '    local s_B = turtle.getItemDetail(p_Slot)',
    '    return s_B and s_B.name or nil',
  ];

  it('detects a planted re-implementation (proves the check is not a no-op)', () => {
    const planted = [
      'local function plantedHelper(p_Slot)', ...body, 'end', '',
      // The same logic, renamed -- which is exactly how every real copy here had drifted.
      'local function somebodyElsesCopy(p_Where)',
      ...body.map((l) => l.replace(/p_Slot/g, 'p_Where').replace(/s_A/g, 's_N').replace(/s_B/g, 's_D')),
      'end',
    ].join('\n');

    const hit = scan({ files: ['lua/planted.lua'], read: () => planted });
    expect(hit.map((h) => h.helper)).toContain('plantedHelper');
  });

  it('does not flag two functions that merely look similar', () => {
    const different = [
      'local function plantedHelper(p_Slot)', ...body, 'end', '',
      'local function unrelated(p_X)',
      '    local s_Sum = 0',
      '    for i = 1, p_X do s_Sum = s_Sum + i end',
      '    if s_Sum > 100 then return "big" end',
      '    return s_Sum',
      'end',
    ].join('\n');

    expect(scan({ files: ['lua/planted.lua'], read: () => different })).toEqual([]);
  });
});
