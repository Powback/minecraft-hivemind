#!/usr/bin/env node
/**
 * DUPLICATED LOGIC, COUNTED -- because "there is a lot of copy-paste in here" was true for months
 * and nothing could say WHERE, or whether it was getting better.
 *
 * The duplication in this repo is not the kind a plain text diff finds. Every copy had drifted:
 * different local names (`s_Parsed` vs the typo'd `s_Mesage`), different literals (1..16 vs 1..12),
 * a guard present in one and missing in the other. So this normalises before hashing:
 *
 *   - strings -> "S", numbers -> N, so a copy that changed a bound still matches
 *   - identifiers -> $1, $2, ... in order of first appearance INSIDE the window, so an
 *     alpha-renamed copy still matches while genuinely different code does not
 *
 * That is what actually found them. The straight text scan reported 80 blocks and almost all of it
 * was `end` runs and endpoint tables; this normalisation is what surfaced the five-copy sixteen-slot
 * inventory walk, the three direction ladders in pgps and the duplicated handler preambles.
 *
 * TWO SHAPES, because the expensive duplication came in two and a block scanner only sees one:
 *
 *   BLOCKS  -- WINDOW consecutive statements repeated somewhere. The classic copy-paste.
 *   IDIOMS  -- a SINGLE line with real work in it, repeated many times over. This is the one that
 *              hides: `math.abs(a-x) + math.abs(b-y) + math.abs(c-z)` appeared twenty-three times
 *              in DroneLogic and no block scanner would ever flag it, because each copy is one
 *              line. It was the single most duplicated piece of logic in the codebase -- and it is
 *              the fuel budget. Same shape as the thirteen hand-written `os.queueEvent(x)
 *              os.pullEvent(x)` yields, forgetting one of which kills the storage server.
 *
 * Usage:
 *   node scripts/duplication.mjs            # the report
 *   node scripts/duplication.mjs --json     # machine-readable, used by test/duplication.test.ts
 *   node scripts/duplication.mjs --update   # rewrite the baseline (ONLY ever to record a FALL)
 */
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HQ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO = path.resolve(HQ, '..');
export const BASELINE = path.join(HQ, 'duplication-baseline.json');
export const WINDOW = 5;

/**
 * Boilerplate by design, and excluded on purpose.
 *
 * These are module skeletons -- a new module is MEANT to start as a copy of one. Counting them
 * would bury the real findings under noise nobody may act on, which is how a rule gets
 * exemption-stamped into uselessness.
 *
 * POWNETREMOTE WAS ON THIS LIST AND SHOULD NEVER HAVE BEEN. The justification read "PowNetRemote is
 * a vendored installer". It is not vendored: SPEC.md lists it as "Keep -- human override path", it
 * is the pocket-computer client for the callable registry, and its params handling IS the fleet's
 * tool schema. So the one file with more duplication than any other -- 11 surplus blocks -- was the
 * one file the duplication check could not see, for a reason that was simply untrue.
 *
 * That is worse than an uncounted file: an exemption whose stated reason is false is a check that
 * CANNOT FAIL, and this repo has now been bitten four separate times by guards that went quiet
 * rather than red. An exemption has to be re-justified, not inherited.
 */
const SKIP_FILES = new Set(['ModuleTemplate.lua', 'TankStation.lua', 'Template.lua']);

const LUA_KW = new Set(('and break do else elseif end false for function goto if in local nil not or ' +
  'repeat return then true until while').split(' '));

/**
 * Lines that carry no logic: structure, and DECLARATIONS.
 *
 * The first cut of this reported 150 "duplicated blocks" and the top forty were `registry.register({
 * name: ..., summary: ..., returns: ... })` -- the tool catalogue -- plus PowNet endpoint tables.
 * Those are DATA. They repeat because they are a list, there is nothing to extract, and burying the
 * five real findings under them is how a rule gets exemption-stamped into uselessness. So anything
 * shaped like a property in an object/table literal is not logic and does not count.
 */
export function isNoise(t) {
  if (!t || t.startsWith('--') || t.startsWith('//') || t.startsWith('*')) return true;
  if (/^(end|end\)|end,|end\)\)|\}|\},|\)|\),|\);|\]|\],|else|do|then|\{|\}\)|\}\),|\}\);|\}\]|\)\.\w+\(\)|return)$/.test(t)) return true;
  // TS object property: `name: 'hive.brief',` / `params: z.object({}).strict(),` / `handler: async`
  if (/^[A-Za-z_$][\w$]*\s*:/.test(t)) return true;
  // Lua table entry: `Foo = { func = OnFoo },` / `name = {` / `x = 1,` / `KEY = "s",`
  if (/^\[?["']?[A-Za-z_][\w.]*["']?\]?\s*=\s*/.test(t) && /,$/.test(t)) return true;
  if (/^[A-Za-z_][\w.]*\s*=\s*\{[^}]*\}\s*,?$/.test(t)) return true;
  if (/^[A-Za-z_][\w.]*\s*=\s*\{?,?$/.test(t)) return true;
  if (/^(local\s+)?[A-Za-z_][\w.]*\s*=\s*(true|false|nil|-?\d+(\.\d+)?|"[^"]*"|'[^']*'|\{\s*\})\s*,?$/.test(t)) return true;
  // A bare string / string continuation: prose in a description or a multi-line message.
  if (/^["'].*["']\s*[,)+]?\s*[,)]?$/.test(t)) return true;
  // AN IMPORT BLOCK IS NOT COPY-PASTE.
  //
  // normalise() renumbers identifiers per window, so five consecutive imports collide with any
  // other five whose named-import counts happen to run in the same order -- `2,2,1,1,2` matched
  // `2,2,1,1,2` twelve lines down. Adding ONE import to supply.ts failed this check with a finding
  // whose only possible remedy was reordering import lines, which fixes nothing and teaches nothing.
  // A false finding is not a harmless one: it trains people to satisfy the detector instead of
  // reading it, and this repo relies on these checks being believed.
  if (/^(import|export .* from |const .* = require\()/.test(t)) return true;
  return false;
}

/**
 * A line that only reports is not a line that does something.
 *
 * `trace(("%s: %s"):format(a, b))` normalises to the same shape as every other trace in the fleet,
 * so with string literals blanked these swamped the idiom list eighteen deep -- and merging two log
 * lines is worth nothing. Logging is excluded, and idioms keep their string literals EXACT, so
 * `os.queueEvent("scan") os.pullEvent("scan")` matches its true siblings and nothing else.
 */
const LOGGING = /^(trace|log|print|Say|Doing|ptrace|Log|console\.\w+)\s*\(/;

/** Alpha-rename within the window: the whole point -- see the header. */
export function normalise(lines, keepLiterals = false) {
  const ren = new Map();
  let c = 0;
  return lines.map((t) => (keepLiterals ? t : t
    .replace(/"[^"]*"|'[^']*'/g, '"S"')
    .replace(/\b\d+(\.\d+)?\b/g, 'N'))
    .replace(/[A-Za-z_][A-Za-z0-9_]*/g, (w) => {
      if (LUA_KW.has(w)) return w;
      if (!ren.has(w)) ren.set(w, '$' + ++c);
      return ren.get(w);
    })
    .replace(/\s+/g, ' ')
    .trim());
}

export function sources() {
  const out = [];
  for (const f of readdirSync(path.join(REPO, 'lua'))) {
    if (f.endsWith('.lua') && !SKIP_FILES.has(f)) out.push(path.join('lua', f));
  }
  const walk = (d) => {
    for (const e of readdirSync(path.join(REPO, d), { withFileTypes: true })) {
      const rel = path.join(d, e.name);
      if (e.isDirectory()) walk(rel);
      else if (/\.ts$/.test(e.name) && !/\.test\.ts$/.test(e.name)) out.push(rel);
    }
  };
  walk(path.join('hq', 'src'));
  return out;
}

/**
 * AN EXEMPTION IS A JUSTIFICATION, NOT A MUTE BUTTON.
 *
 * Same mechanism every other check here uses. It exists for one real case: the in-world modules
 * cannot share code without `os.loadAPI` of a new file, which is a DEPLOYMENT change -- a new file
 * that has to reach every computer -- so a two-line watchdog yield genuinely does have to be
 * written once per module. Marking that is honest; deleting the rule because of it would not be.
 */
const ALLOW = /(--|\/\/)\s*dup:\s*allow\s*\(/;

export function scan() {
  const blocks = new Map();
  const idioms = new Map();

  for (const f of sources()) {
    const raw = readFileSync(path.join(REPO, f), 'utf8').split('\n');
    const keep = [];
    raw.forEach((l, i) => {
      const t = l.replace(/--.*$/, '').replace(/\/\/.*$/, '').trim();
      if (isNoise(t)) return;
      // An exemption on the line, or in the short comment block above it -- the justification is
      // usually several lines, so match the span the other checks use rather than one line.
      if (raw.slice(Math.max(0, i - 4), i + 1).some((x) => ALLOW.test(x))) return;
      keep.push([i + 1, t]);
    });

    // BLOCKS
    for (let i = 0; i + WINDOW <= keep.length; i++) {
      const win = keep.slice(i, i + WINDOW);
      const key = normalise(win.map((x) => x[1])).join(' ; ');
      if (!blocks.has(key)) blocks.set(key, []);
      blocks.get(key).push({ file: f, line: win[0][0], text: win[0][1] });
    }

    // IDIOMS: one line, at least two calls in it -- enough work to be worth a name. Literals are
    // kept EXACT here (see LOGGING): the finds in this class are arithmetic and API sequences, and
    // blanking their strings only merges unrelated log lines.
    for (const [line, t] of keep) {
      if (LOGGING.test(t)) continue;
      if ((t.match(/[A-Za-z_][\w.]*\s*\(/g) ?? []).length < 2) continue;
      if (t.length < 30) continue;
      const key = normalise([t], true)[0];
      if (!idioms.has(key)) idioms.set(key, []);
      idioms.get(key).push({ file: f, line, text: t });
    }
  }

  /**
   * ONE DUPLICATED REGION IS ONE FINDING, NOT WINDOW OF THEM.
   *
   * A 9-line copied region contains five overlapping 5-line windows, and every one of them hashes
   * as a duplicate -- so the three-module Render() showed up five times over, each line of it its
   * own "finding". A count that inflates with the SIZE of a duplicate cannot be ratcheted: fixing
   * one region moves the number by an amount nobody can predict. So a group whose hits are all
   * exactly one line further on than another group's is the same region, shifted, and is dropped.
   */
  const collapse = (m, min) => {
    const groups = [];
    for (const [key, hits] of m) {
      if (hits.length < min) continue;
      const seen = new Set();
      const uniq = hits.filter((h) => {
        const bucket = `${h.file}:${h.line}`;
        if (seen.has(bucket)) return false;
        seen.add(bucket);
        return true;
      });
      if (uniq.length < min) continue;
      groups.push({ key, hits: uniq, copies: uniq.length, text: uniq[0].text });
    }
    const sig = (hits) => hits.map((h) => `${h.file}:${h.line}`).sort().join('|');
    const starts = new Set(groups.map((g) => sig(g.hits)));
    const kept = groups.filter((g) => !starts.has(sig(g.hits.map((h) => ({ file: h.file, line: h.line - 1 })))));
    return kept
      .map((g) => ({ key: g.key, copies: g.copies, text: g.text, at: g.hits.map((h) => `${h.file}:${h.line}`) }))
      .sort((a, b) => b.copies - a.copies);
  };

  return { blocks: collapse(blocks, 2), idioms: collapse(idioms, 3) };
}

/** The debt, per file: how many surplus copies exist beyond the one that should. */
export function perFile(found) {
  const by = {};
  for (const kind of ['blocks', 'idioms']) {
    for (const d of found[kind]) {
      for (const at of d.at.slice(1)) {
        const file = at.split(':')[0];
        by[file] ??= { blocks: 0, idioms: 0 };
        by[file][kind]++;
      }
    }
  }
  return by;
}

export function readBaseline() {
  return existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')).files : {};
}

export function compare(found, baseline) {
  const now = perFile(found);
  const violations = [];
  const stale = [];
  for (const file of new Set([...Object.keys(now), ...Object.keys(baseline)])) {
    const n = now[file] ?? { blocks: 0, idioms: 0 };
    const b = baseline[file] ?? { blocks: 0, idioms: 0 };
    for (const kind of ['blocks', 'idioms']) {
      if (n[kind] > b[kind]) {
        violations.push({ file, kind, message: `${n[kind]} duplicated ${kind}, baseline allows ${b[kind]}` });
      } else if (n[kind] < b[kind]) {
        stale.push({ file, kind, was: b[kind], now: n[kind] });
      }
    }
  }
  return { violations, stale };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const found = scan();
  if (process.argv.includes('--update')) {
    writeFileSync(BASELINE, JSON.stringify({
      note: 'Duplicated logic. This file may only ever SHRINK -- see test/duplication.test.ts.',
      window: WINDOW,
      totals: {
        blocks: found.blocks.reduce((n, d) => n + d.copies - 1, 0),
        idioms: found.idioms.reduce((n, d) => n + d.copies - 1, 0),
      },
      files: perFile(found),
    }, null, 2) + '\n');
    console.log(`baseline updated: ${found.blocks.length} duplicated block(s), ${found.idioms.length} repeated idiom(s)`);
  } else if (process.argv.includes('--json')) {
    console.log(JSON.stringify(found, null, 2));
  } else {
    console.log(`== ${found.idioms.length} repeated idiom(s) (one line, >=3 copies)`);
    for (const d of found.idioms.slice(0, 25)) {
      console.log(`  x${d.copies}  ${d.text.slice(0, 96)}`);
      console.log(`        ${d.at.slice(0, 6).join('  ')}${d.at.length > 6 ? '  ...' : ''}`);
    }
    console.log(`\n== ${found.blocks.length} duplicated block(s) (>=${WINDOW} statements)`);
    for (const d of found.blocks.slice(0, 25)) {
      console.log(`  x${d.copies}  ${d.text.slice(0, 96)}`);
      console.log(`        ${d.at.slice(0, 6).join('  ')}${d.at.length > 6 ? '  ...' : ''}`);
    }
  }
}
