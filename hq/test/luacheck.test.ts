import { describe, it, expect } from 'vitest';
import { scan, summarise, loadBaseline, luacheckBinary } from '../scripts/luacheck.mjs';

/**
 * STATIC ANALYSIS FOR THE ONE BUG THIS CODEBASE KEEPS WRITING.
 *
 * A `local` declared below the function that reads it is a nil global at that point -- silently.
 * CLAUDE.md counts nine outages from that shape, and the regex "guards" written over the months
 * caught none of them, because a regex sees text and this is scope. luacheck resolves scope. The
 * first time it ran over lua/ it reported 29 undefined reads that were not ComputerCraft globals:
 * the GPS relay's own position in nine places, the crash marker every heartbeat carries, a fly
 * budget computed and then read out of scope, and a bare `dig` that would throw the moment a
 * multi-miner dig was placed.
 *
 * W113 is therefore zero tolerance. Everything else ratchets: the per-file count in
 * luacheck-baseline.json may fall and may not rise, and `node scripts/luacheck.mjs --update`
 * banks a win. Unused variables and whitespace are ignored in .luacheckrc for now -- they are
 * noise until the signal is clean.
 */
const MISSING = 'luacheck is not installed (brew install luacheck) -- the undefined-variable gate cannot run';

describe('luacheck', () => {
  const bin = luacheckBinary();
  const findings = bin ? scan() : null;
  const s = findings ? summarise(findings) : null;

  it('is installed', () => {
    expect(bin, MISSING).not.toBeNull();
  });

  it('finds no undefined-variable reads (W113)', () => {
    if (!s) return;
    const lines = s.undefinedReads.map((f) => `${f.file}:${f.line} ${f.message}`);
    expect(lines, 'a name read before its `local` is declared is nil at that point. Declare it above, '
      + 'or add a genuine runtime global to read_globals in .luacheckrc -- do not add locals here.')
      .toEqual([]);
  });

  it('no file gained warnings', () => {
    if (!s) return;
    const base = loadBaseline();
    const regressions: string[] = [];
    for (const [file, n] of Object.entries(s.byFile)) {
      const allowed = base.files?.[file] ?? 0;
      if (n > allowed) regressions.push(`${file}: ${n} warning(s), baseline allows ${allowed}`);
    }
    expect(regressions, 'run `node scripts/luacheck.mjs` to see them').toEqual([]);
  });

  it('the baseline records no debt that has already been paid', () => {
    if (!s) return;
    const base = loadBaseline();
    const paid: string[] = [];
    for (const [file, allowed] of Object.entries(base.files ?? {})) {
      const n = s.byFile[file] ?? 0;
      if (n < (allowed as number)) paid.push(`${file}: baseline allows ${allowed}, only ${n} remain. Run \`node scripts/luacheck.mjs --update\`.`);
    }
    expect(paid).toEqual([]);
  });
});
