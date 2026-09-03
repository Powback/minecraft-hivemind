// Which mutating tools confirm their own effect, and which merely report success.
//
// See CLAUDE.md: "Verify at the effect, never at the call". A tool that returns ok:true without
// re-reading the world is not reporting an outcome, it is reporting that a message was sent -- and
// every hour lost in this project to a "fix" that had not shipped, a task that never stopped or a
// block that was never placed traces back to trusting one of those.
//
// A tool counts as verified when its definition carries a `// verify-at-effect:` note saying what
// it re-reads afterwards. The note is the point: it makes the author answer the question.
import { readFileSync } from 'node:fs';

export function scan(src) {
  const text = readFileSync(src, 'utf8');
  const marks = [...text.matchAll(/name: '([a-z.]+)'/g)];
  const out = { verified: [], unverified: [] };
  for (let i = 0; i < marks.length; i++) {
    const start = marks[i].index;
    const end = i + 1 < marks.length ? marks[i + 1].index : text.length;
    const body = text.slice(start, end);
    if (!body.includes("danger: 'mutate'")) continue;
    (body.includes('verify-at-effect:') ? out.verified : out.unverified).push(marks[i][1]);
  }
  out.unverified.sort();
  out.verified.sort();
  return out;
}
