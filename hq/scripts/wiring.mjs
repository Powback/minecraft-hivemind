// IS THIS ENDPOINT ACTUALLY WIRED END TO END?
//
// A capability in this system is declared in four places: an HQ tool, a PowNet endpoint entry with
// its `params` spec, the Lua handler, and something that calls it. Every layer reports success
// independently, so a half-wired feature is indistinguishable from a working one until you check
// the world -- which is why so much here was written and never actually ran.
//
// This checks the seam that fails silently and costs the most: PowNet DROPS any field the endpoint
// does not declare, and the call still returns success. `dependsOn` was passed by order.build from
// the day it was written, was never declared on TaskMan.Add, and so no build ever waited for its
// materials -- for months, with every call reporting fine.
import { readFileSync } from 'node:fs';

/** Endpoint entries: `NAME = { ... params = { ... } ... func = OnX }` */
export function endpointsOf(src) {
  const text = readFileSync(src, 'utf8');
  const out = [];
  const re = /^\s{0,8}([A-Za-z_]\w*)\s*=\s*\{/gm;
  let m;
  while ((m = re.exec(text))) {
    // Take the balanced block for this entry.
    let i = text.indexOf('{', m.index), depth = 0, end = i;
    for (; end < text.length; end++) {
      if (text[end] === '{') depth++;
      else if (text[end] === '}') { depth--; if (depth === 0) break; }
    }
    const body = text.slice(i, end + 1);
    const fn = body.match(/func\s*=\s*([A-Za-z_]\w*)/);
    if (!fn) continue;
    const pm = body.match(/params\s*=\s*\{/);
    let declared = [];
    if (pm) {
      let j = i + pm.index + pm[0].length - 1, d = 0, pend = j;
      for (; pend < text.length; pend++) {
        if (text[pend] === '{') d++;
        else if (text[pend] === '}') { d--; if (d === 0) break; }
      }
      const pbody = text.slice(j, pend + 1);
      declared = [...pbody.matchAll(/([A-Za-z_]\w*)\s*=\s*[{"]/g)].map((x) => x[1]);
    }
    // ONLY ENDPOINTS THAT DECLARE A SPEC ARE FILTERED.
    //
    // PowNet passes the payload through untouched when an endpoint declares no `params` block at
    // all -- MapServer.UpdatePath has none and carries the whole world index every few seconds.
    // The trap is the HALF-declared endpoint: once a spec exists, anything missing from it is
    // dropped, silently, and the call still returns success. So a missing spec is fine and an
    // incomplete one is the bug.
    out.push({ endpoint: m[1], handler: fn[1], declared, filtered: Boolean(pm) });
  }
  return { text, endpoints: out };
}

/** Fields a handler reads off the wire. */
export function readsOf(text, handler) {
  const i = text.indexOf(`function ${handler}(`);
  if (i < 0) return null;                       // handler missing entirely — also a wiring fault
  let end = text.indexOf('\nend\n', i);
  const body = text.slice(i, end < 0 ? text.length : end);
  const fields = new Set();
  for (const m of body.matchAll(/p_Message\.data\.([A-Za-z_]\w*)/g)) fields.add(m[1]);
  // `local d = p_Message.data` then `d.field`
  const alias = body.match(/local\s+(\w+)\s*=\s*p_Message\.data\b/);
  if (alias) for (const m of body.matchAll(new RegExp(`\\b${alias[1]}\\.([A-Za-z_]\\w*)`, 'g'))) fields.add(m[1]);
  return [...fields];
}
