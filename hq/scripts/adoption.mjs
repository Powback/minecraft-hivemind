#!/usr/bin/env node
/**
 * EXTRACTING A HELPER IS NOT THE SAME AS ADOPTING IT, AND THAT GAP IS THE TEN-DAY BUG.
 *
 * This repo does not have a duplication problem so much as an ADOPTION problem, and the difference
 * is why the same defect kept coming back. The pattern, every time:
 *
 *   1. The same logic gets written in four places.
 *   2. Somebody notices, extracts a helper, and writes an excellent comment explaining why.
 *   3. ONE call site is converted. The other three are left exactly as they were.
 *   4. The comment now reads as if the problem is solved, so nobody looks again.
 *   5. A bug is found and fixed -- in whichever copy the reporter happened to be standing in.
 *   6. The other copies keep the bug, and now they disagree with the helper as well.
 *
 * The comments in this codebase are confessions of steps 1-4, written by people who had just done
 * step 2 and believed they were finished:
 *
 *   pgps.lua      "Exported name -> number, so callers stop writing their own copy of the mapping."
 *                 -> three if/elseif ladders still answered it, months later.
 *   core.ts       "The same eight lines were written out three times ... So the caller decides."
 *                 -> readStock was written, ONE of four call sites adopted it, and the three
 *                    survivors never got luaList() -- so an object-shaped stock list threw inside
 *                    their own catch and the planner concluded the settlement owned nothing.
 *   DroneLogic    "'unload here' is the same six lines in three places"
 *                 -> a fourth copy sat in CollectFuel, without the ContainerBelow() guard.
 *
 * Step 5 is the expensive one and it is invisible: the fix looks complete, the tests pass, and the
 * copies fail later somewhere else. No amount of care prevents it, because the person fixing the
 * bug has no way to know the other copies exist.
 *
 * So this asks one question that has no judgement in it: DOES A NAMED FUNCTION'S BODY ALSO APPEAR
 * SOMEWHERE ELSE? If it does, the extraction was never finished. The fix is never ambiguous -- call
 * the thing that already exists -- which is what makes this worth failing a build over.
 *
 * Usage:
 *   node scripts/adoption.mjs           # the report
 *   node scripts/adoption.mjs --json
 *   node scripts/adoption.mjs --update  # rewrite the baseline (ONLY ever to record a FALL)
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sources, isNoise, normalise } from './duplication.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const BASELINE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'adoption-baseline.json');

/**
 * How many consecutive statements of a helper must reappear before it counts.
 *
 * Four, not two: at two, `local x = f()` followed by `if x then` matches half the codebase and the
 * rule drowns. At four, every hit found so far has been a genuine unadopted copy.
 */
export const RUN = 4;

/** A same-name reimplementation is the finding, not an excuse -- but a wrapper is not a copy. */
const TRIVIAL = /^(return|local [\w, ]+ = [\w.]+\(.*\)|end)$/;

/** Named functions, at column 0 so the end is unambiguous. */
function helpers(file, raw) {
  const out = [];
  const lua = file.endsWith('.lua');
  const open = lua
    ? /^(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(/
    : /^(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*[(<]/;
  const close = lua ? /^end\b/ : /^\}/;
  for (let i = 0; i < raw.length; i++) {
    const m = raw[i].match(open);
    if (!m) continue;
    for (let j = i + 1; j < raw.length; j++) {
      if (close.test(raw[j])) { out.push({ name: m[1], from: i + 1, to: j + 1 }); break; }
    }
  }
  return out;
}

/**
 * `files`/`read` are injectable so the canary in test/adoption.test.ts can run this against a
 * PLANTED duplicate and prove the detector still fires. A check nobody has seen fail is not a
 * check -- and this repo has already had two guards go silently quiet when the code they watched
 * was moved behind a new name.
 */
export function scan({ files = null, read = null } = {}) {
  // One pass to build the corpus of real statements, keyed by file.
  const corpus = new Map();
  const defs = [];
  for (const f of files ?? sources()) {
    const raw = (read ? read(f) : readFileSync(path.join(REPO, f), 'utf8')).split('\n');
    const keep = [];
    raw.forEach((l, i) => {
      const t = l.replace(/--.*$/, '').replace(/\/\/.*$/, '').trim();
      if (isNoise(t)) return;
      keep.push([i + 1, t]);
    });
    corpus.set(f, keep);
    for (const h of helpers(f, raw)) defs.push({ file: f, ...h });
  }

  // Every RUN-length window in the whole codebase, by normalised shape.
  const index = new Map();
  for (const [f, keep] of corpus) {
    for (let i = 0; i + RUN <= keep.length; i++) {
      const win = keep.slice(i, i + RUN);
      const key = normalise(win.map((x) => x[1])).join(' ; ');
      if (!index.has(key)) index.set(key, []);
      index.get(key).push({ file: f, line: win[0][0] });
    }
  }

  const found = [];
  for (const d of defs) {
    const keep = corpus.get(d.file) ?? [];
    const body = keep.filter(([ln]) => ln > d.from && ln < d.to);
    if (body.length < RUN) continue;
    if (body.every(([, t]) => TRIVIAL.test(t))) continue;

    const copies = new Map();
    for (let i = 0; i + RUN <= body.length; i++) {
      const win = body.slice(i, i + RUN);
      const key = normalise(win.map((x) => x[1])).join(' ; ');
      for (const hit of index.get(key) ?? []) {
        // Inside the helper itself is not a copy.
        if (hit.file === d.file && hit.line >= d.from && hit.line <= d.to) continue;
        // Nor is a hit inside a DIFFERENT window of the same helper's own body.
        const k = `${hit.file}:${hit.line}`;
        if (!copies.has(k)) copies.set(k, { at: k, statements: win.map((x) => x[1]) });
      }
    }
    if (copies.size === 0) continue;
    // ONE COPY IS ONE COPY, not one per overlapping window. A re-implementation N statements long
    // matches at N-RUN+1 consecutive offsets; counting each would make the number move by an
    // amount nobody can predict when it is fixed, which is not something you can ratchet against.
    const at = [...copies.values()].map((c) => c.at)
      .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    const merged = [];
    for (const a of at) {
      const [file, line] = [a.slice(0, a.lastIndexOf(':')), +a.slice(a.lastIndexOf(':') + 1)];
      const last = merged[merged.length - 1];
      if (last && last.file === file && line - last.line <= RUN) { last.line = line; continue; }
      merged.push({ file, line, head: a });
    }
    found.push({
      helper: d.name,
      at: `${d.file}:${d.from}`,
      copies: merged.map((m) => m.head),
      sample: [...copies.values()][0].statements,
    });
  }
  return found.sort((a, b) => b.copies.length - a.copies.length);
}

/** Charged to the file holding the UNADOPTED COPY -- that is where the work is. */
export function perFile(found) {
  const by = {};
  for (const f of found) for (const c of f.copies) {
    const file = c.split(':')[0];
    by[file] = (by[file] ?? 0) + 1;
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
    const n = now[file] ?? 0;
    const b = baseline[file] ?? 0;
    if (n > b) violations.push({ file, message: `${n} unadopted copies of an existing helper, baseline allows ${b}` });
    else if (n < b) stale.push({ file, was: b, now: n });
  }
  return { violations, stale };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const found = scan();
  if (process.argv.includes('--update')) {
    writeFileSync(BASELINE, JSON.stringify({
      note: 'Helpers that exist but were never adopted everywhere. May only ever SHRINK -- see test/adoption.test.ts.',
      run: RUN,
      total: found.reduce((n, f) => n + f.copies.length, 0),
      files: perFile(found),
    }, null, 2) + '\n');
    console.log(`baseline updated: ${found.length} helper(s) with unadopted copies`);
  } else if (process.argv.includes('--json')) {
    console.log(JSON.stringify(found, null, 2));
  } else {
    for (const f of found) {
      console.log(`\n${f.helper}()  ${f.at}`);
      console.log(`  is re-implemented at: ${f.copies.join('  ')}`);
      for (const s of f.sample) console.log(`      ${s.slice(0, 96)}`);
    }
    console.log(`\n${found.length} helper(s) with a copy of their body living elsewhere`);
  }
}
