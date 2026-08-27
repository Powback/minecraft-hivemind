#!/usr/bin/env node
/**
 * Cyclomatic complexity across BOTH halves of the system: the TypeScript in hq/ (eslint) and the
 * Lua that runs on the in-world computers (luacheck W561). One threshold, one baseline, one report.
 *
 * Usage:
 *   node scripts/complexity.mjs              # print the report
 *   node scripts/complexity.mjs --json       # machine-readable, used by test/complexity.test.ts
 *   node scripts/complexity.mjs --update     # rewrite the baseline (ONLY ever to record a REDUCTION)
 */
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HQ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO = path.resolve(HQ, '..');
export const MAX_COMPLEXITY = 15;
export const BASELINE = path.join(HQ, 'complexity-baseline.json');

const run = (cmd, args, opts = {}) => {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...opts });
  } catch (e) {
    // Both linters exit non-zero precisely when they have findings, which is the normal case here.
    if (typeof e.stdout === 'string' && e.stdout.length) return e.stdout;
    throw e;
  }
};

/** TypeScript, via eslint's built-in `complexity` rule. */
function scanTs() {
  const out = run('npx', ['eslint', '.', '-f', 'json'], { cwd: HQ, stdio: ['ignore', 'pipe', 'ignore'] });
  const found = [];
  for (const file of JSON.parse(out)) {
    for (const m of file.messages ?? []) {
      if (m.ruleId !== 'complexity') continue;
      const cc = Number(/complexity of (\d+)/.exec(m.message)?.[1] ?? 0);
      const name = /'([^']+)'/.exec(m.message)?.[1] ?? '(anonymous)';
      found.push({ file: path.relative(REPO, file.filePath), name, line: m.line, cc });
    }
  }
  return found;
}

/**
 * Lua, via luacheck. luacheck is not an npm dependency, so it may be absent -- but a MISSING linter
 * must not read as a CLEAN one. This throws, and the test reports the install command, rather than
 * skipping and letting the Lua half go unchecked in silence.
 */
function scanLua() {
  const bin = ['luacheck', path.join(process.env.HOME ?? '', '.luarocks/bin/luacheck')].find(
    (b) => b === 'luacheck' || existsSync(b),
  );
  let out;
  try {
    out = run(bin, ['--max-cyclomatic-complexity', String(MAX_COMPLEXITY), '--no-color', '--codes',
      '--formatter', 'plain', ...['lua'].map(() => path.join(REPO, 'lua')), '--only', '561'],
      { cwd: REPO, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    throw new Error(
      'luacheck not found -- the Lua half of the fleet would go unchecked.\n' +
      '  brew install lua@5.4 luarocks\n' +
      '  luarocks --lua-version=5.4 --lua-dir=/opt/homebrew/opt/lua@5.4 install luacheck',
    );
  }
  const found = [];
  for (const line of out.split('\n')) {
    const m = /^(.*?):(\d+):\d+: \(W561\) cyclomatic complexity of function (?:'(.+?)' )?is too high \((\d+)/.exec(line);
    if (!m) continue;
    found.push({
      file: path.relative(REPO, path.resolve(REPO, m[1])),
      name: m[3] ?? '(anonymous)',
      line: Number(m[2]),
      cc: Number(m[4]),
    });
  }
  return found;
}

/** How far over the line a file is in total: the debt, in branches. */
const excessOf = (ccs) => ccs.reduce((n, cc) => n + Math.max(0, cc - MAX_COMPLEXITY), 0);

/**
 * The baseline is keyed by FILE and compared on TOTAL EXCESS and WORST FUNCTION -- deliberately not
 * on the number of functions over the line, and not on names or line numbers.
 *
 * Counting offenders was the first attempt and it was wrong in the one case that matters most:
 * splitting runSupplyTick (CC 169) into five ~25s took the file from 2 offenders to 5 and failed
 * the check, while the actual debt fell from 155 excess branches to 48. A rule that fails the
 * decomposition it exists to encourage is worse than no rule -- it teaches people to write the
 * monster instead.
 *
 * Excess falls whenever a branch genuinely goes away and cannot be gamed by moving branches into a
 * helper (the helper's own excess counts too). Pairing it with the per-file MAXIMUM stops the other
 * failure mode: trading one enormous function for a slightly-less-enormous one plus some noise.
 *
 * Names and lines are not keys because names are not unique here (several `probe`s, many anonymous
 * handlers) and lines shift on every edit -- either would produce phantom failures on unrelated
 * changes and train everyone to run --update reflexively, which defeats the point.
 */
export function compare(found, baseline) {
  const byFile = new Map();
  for (const f of found) {
    if (!byFile.has(f.file)) byFile.set(f.file, []);
    byFile.get(f.file).push(f);
  }
  const violations = [];
  for (const [file, items] of byFile) {
    const now = items.map((i) => i.cc);
    const was = baseline[file]?.cc ?? [];
    const worst = items.slice().sort((a, b) => b.cc - a.cc);
    if (excessOf(now) > excessOf(was)) {
      violations.push({
        file,
        kind: 'debt',
        message: `${excessOf(now)} excess branches over CC ${MAX_COMPLEXITY}, baseline allows ${excessOf(was)}`,
        worst: worst.slice(0, 3),
      });
      continue;
    }
    const maxNow = Math.max(0, ...now);
    const maxWas = Math.max(0, ...was);
    if (maxNow > maxWas) {
      violations.push({
        file,
        kind: 'worse',
        message: `worst function rose to CC ${maxNow}, baseline's worst was ${maxWas}`,
        worst: worst.slice(0, 1),
      });
    }
  }
  // Debt recorded but already paid must be REMOVED from the baseline, or the budget it frees stays
  // available for the next regression and the ratchet stops ratcheting.
  const stale = [];
  for (const [file, entry] of Object.entries(baseline)) {
    const now = (byFile.get(file) ?? []).map((i) => i.cc);
    if (excessOf(now) < excessOf(entry.cc ?? [])) {
      stale.push({ file, was: excessOf(entry.cc ?? []), now: excessOf(now) });
    }
  }
  return { violations, stale, byFile };
}

export function scan() {
  return [...scanTs(), ...scanLua()].sort((a, b) => b.cc - a.cc);
}

export function readBaseline() {
  return existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')).files : {};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const found = scan();
  if (process.argv.includes('--update')) {
    const files = {};
    for (const f of found) {
      files[f.file] ??= { cc: [], names: [] };
      files[f.file].cc.push(f.cc);
      files[f.file].names.push(f.name);
    }
    for (const v of Object.values(files)) v.cc.sort((a, b) => b - a);
    writeFileSync(BASELINE, JSON.stringify({
      note: 'Cyclomatic-complexity debt. This file may only ever SHRINK -- see test/complexity.test.ts.',
      max: MAX_COMPLEXITY,
      total: found.length,
      files,
    }, null, 2) + '\n');
    console.log(`baseline updated: ${found.length} function(s) over CC ${MAX_COMPLEXITY}`);
  } else if (process.argv.includes('--json')) {
    console.log(JSON.stringify(found, null, 2));
  } else {
    for (const f of found) console.log(`${String(f.cc).padStart(4)}  ${f.file}:${f.line} ${f.name}`);
    console.log(`\n${found.length} function(s) over CC ${MAX_COMPLEXITY}`);
  }
}
