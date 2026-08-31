/**
 * ONE QUESTION, ONE FUNCTION.
 *
 * Every bug in this codebase's worst sessions has had the same shape: a question the whole file
 * cares about, answered independently in two or three places, and the copies disagreeing. Not hard
 * problems -- duplicated concepts. A partial list, all real, all paid for:
 *
 *   "what counts as fuel"      three copies in TaskMan (the emergency filter, the queue ordering,
 *                              the preempt guard) plus producesFuel in supply.ts. Two of them knew
 *                              only about coal, so gather:oak_log -- the settlement's ONLY
 *                              renewable fuel -- was banned during fuel emergencies, sorted below
 *                              coal, and preempted mid-run for rescue duty. Three bugs, one concept.
 *
 *   "what can be smelted"      isSmeltable said a log was not smeltable; smeltRank ranked logs
 *                              FIRST as the only fuel-positive smelt. The ranking was dead code for
 *                              the case it was written for, and the settlement burned its ore while
 *                              255 logs sat in storage.
 *
 *   "which way is north"       six copies of the compass constants, one with East and South
 *                              swapped -- documented in CLAUDE.md, one reference away from turning
 *                              every dock approach ninety degrees.
 *
 * So: if a domain term is used to MAKE A DECISION in more than one function in the same file, that
 * is a duplicated concept until proven otherwise. Extract the shared classifier and call it twice.
 *
 * Only matching contexts count -- string.find/match, `:find`/`:match`, and table-key lookups. A
 * term in a comment, a log line or an error message is prose and is ignored, because explaining a
 * decision is not making one.
 *
 * Exemptions are `-- one-concept: allow (<why>)` on the function or just above it, same convention
 * as lua-hygiene. Two functions genuinely asking different questions about the same word is
 * possible; it just has to be argued in writing rather than assumed.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';

const LUA_DIR = path.resolve(__dirname, '../../lua');

/**
 * Terms that classify a KIND OF THING the fleet reasons about. Deliberately narrow: this is the
 * vocabulary that has actually caused disagreements, not every string in the codebase.
 */
const DOMAIN_TERMS = [
  'coal', 'charcoal', '_log', '_wood', '_ore', 'raw_', 'cobble', 'sand', 'plank', 'sapling',
];

/** A matching context -- somewhere a string is used to DECIDE something, not to describe it. */
const MATCH_SITES = [
  /string\.find\([^,]+,\s*"([^"]+)"/g,
  /string\.match\([^,]+,\s*"([^"]+)"/g,
  /:find\(\s*"([^"]+)"/g,
  /:match\(\s*"([^"]+)"/g,
  // A LOOKUP, not a table-constructor key. `SMELTABLE = { ["minecraft:cobblestone"] = true }`
  // DEFINES the vocabulary; it does not make a decision with it, and counting it attributed the
  // whole table to whichever function happened to precede it in the file.
  /\[\s*"([^"]+)"\s*\](?!\s*=)/g,
];

interface Fn { name: string; body: string; exempt: boolean }

/** Split a Lua source into top-level functions, with comments stripped from their bodies. */
function functionsOf(src: string): Fn[] {
  const lines = src.split('\n');
  const code = lines.map((l) => l.replace(/--.*$/, '')).join('\n');
  const heads = [...code.matchAll(/(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(/g)];
  const out: Fn[] = [];
  for (let i = 0; i < heads.length; i++) {
    const start = heads[i].index!;
    const end = i + 1 < heads.length ? heads[i + 1].index! : code.length;
    // The exemption is read from the ORIGINAL text, which still has its comments.
    const upto = code.slice(0, start).split('\n').length;
    const window = lines.slice(Math.max(0, upto - 6), upto + 4).join('\n');
    out.push({
      name: heads[i][1],
      body: code.slice(start, end),
      exempt: /one-concept: allow/.test(window),
    });
  }
  return out;
}

/** Domain terms this function uses to make a decision. */
function decidingTerms(body: string): Set<string> {
  const found = new Set<string>();
  for (const re of MATCH_SITES) {
    for (const m of body.matchAll(re)) {
      for (const t of DOMAIN_TERMS) if (m[1].includes(t)) found.add(t);
    }
  }
  return found;
}

const files = readdirSync(LUA_DIR).filter((f) => f.endsWith('.lua'));

describe('one question, one function', () => {
  for (const file of files) {
    it(`${file} does not decide the same thing in two places`, () => {
      const fns = functionsOf(readFileSync(path.join(LUA_DIR, file), 'utf8'));
      const byTerm = new Map<string, string[]>();
      for (const fn of fns) {
        if (fn.exempt) continue;
        for (const t of decidingTerms(fn.body)) {
          byTerm.set(t, [...(byTerm.get(t) ?? []), fn.name]);
        }
      }
      const dupes = [...byTerm.entries()]
        .filter(([, names]) => new Set(names).size > 1)
        .map(([t, names]) => `"${t}" is decided in ${new Set(names).size} functions: ${[...new Set(names)].join(', ')}`);

      expect(dupes, [
        `${file}: the same domain term decides things in more than one function.`,
        'That is the shape of nearly every outage this codebase has had: the copies drift and',
        'then disagree, and the disagreement is silent. Extract one classifier and call it twice.',
        'If they genuinely ask different questions, add: -- one-concept: allow (<why>)',
      ].join('\n')).toEqual([]);
    });
  }
});
