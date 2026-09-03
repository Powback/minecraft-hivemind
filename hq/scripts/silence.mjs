// WHERE DOES A FAILURE GO QUIET?
//
// The single most expensive design pattern in this project, by a distance. Not one bug -- a shape,
// repeated everywhere, and every instance turns a loud dependency failure into confident wrong
// output somewhere far away:
//
//   .catch(() => null)   in order.tower  -- MapServer timed out under load, the catch swallowed it,
//                                           every position it would have reported came back "not
//                                           built", and the tool queued 235 patches instead of 185.
//                                           A slow dependency became wrong output, silently.
//   readStock('empty')   in three planners -- an unreadable stock read as "the settlement owns
//                                           nothing", so it queued gathering for material already
//                                           on the shelf, and every downstream decision inherited
//                                           the false premise.
//   pcall(...) discarded -- the Lua half of the same thing: the call cannot throw, so the caller
//                                           cannot know, so the drone carries on as if it worked.
//
// The rule is not "never catch". It is "never catch WITHOUT SAYING SO". A caught error that is
// logged, counted, or turned into a returned reason is fine. One that evaporates is not.
//
// Exempt a genuine best-effort site by writing the justification on the line or the line above:
//   -- silent: allow (telemetry only; losing it costs a number, not a decision)
//   // silent: allow (...)
import { readFileSync } from 'node:fs';

const EXEMPT = /(silent:\s*allow)/;

/** `.catch(() => null)` and friends: the failure becomes a value nobody can distinguish from data. */
const TS_SWALLOW = /\.catch\(\s*\(\s*\)\s*=>\s*(null|undefined|\{\}|\[\]|false|0)\s*\)/;
/** `catch {}` / `catch (e) {}` with nothing but whitespace or a comment inside. */
const TS_EMPTY = /catch\s*(\([^)]*\))?\s*\{\s*(\/\/[^\n]*|\/\*[^*]*\*\/)?\s*\}/;
/** A pcall whose result nobody looks at: the statement starts with it. */
const LUA_BARE_PCALL = /^\s*pcall\s*\(/;

export function scan(files) {
  const found = [];
  for (const f of files) {
    const lines = readFileSync(f, 'utf8').split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const context = `${line}\n${lines[i - 1] ?? ''}`;
      if (EXEMPT.test(context)) continue;
      const isLua = f.endsWith('.lua');
      let kind = null;
      if (isLua && LUA_BARE_PCALL.test(line)) kind = 'discarded-pcall';
      else if (!isLua && TS_SWALLOW.test(line)) kind = 'swallowing-catch';
      else if (!isLua && TS_EMPTY.test(line)) kind = 'empty-catch';
      if (kind) found.push(`${f.replace(/^.*\/(?=lua\/|hq\/)/, '')}:${kind}`);
    }
  }
  return found.sort();
}
