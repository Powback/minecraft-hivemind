// luacheck over lua/, parsed into something a test can assert on.
//
// The gate (test/luacheck.test.ts): W113 "accessing undefined variable" is ZERO tolerance --
// that is the local-declared-below-its-use bug that CLAUDE.md counts nine outages for, and the
// day luacheck first ran it found 29 of them, including the GPS relay's own position. Every other
// warning code ratchets against luacheck-baseline.json: the per-file count may fall and may not
// rise. `node scripts/luacheck.mjs --update` banks a win.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HQ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const ROOT = path.dirname(HQ);
export const BASELINE = path.join(HQ, 'luacheck-baseline.json');

/** The Homebrew binary first: the luarocks one on PATH is built against Lua 5.5 and cannot load itself. */
export function luacheckBinary() {
  for (const c of ['/opt/homebrew/opt/luacheck/bin/luacheck', '/usr/local/opt/luacheck/bin/luacheck', 'luacheck']) {
    try {
      execFileSync(c, ['--version'], { stdio: 'pipe' });
      return c;
    } catch { /* try the next */ }
  }
  return null;
}

export function scan() {
  const bin = luacheckBinary();
  if (!bin) return null;
  let out = '';
  try {
    out = execFileSync(bin, ['lua', '--config', '.luacheckrc', '--codes', '--no-color', '--formatter', 'plain'],
      { cwd: ROOT, stdio: 'pipe', encoding: 'utf8' });
  } catch (err) {
    // luacheck exits non-zero when it has warnings; the report is still on stdout.
    out = String(err.stdout ?? '');
    if (!out) throw err;
  }
  const findings = [];
  for (const line of out.split('\n')) {
    const m = /^(.*?):(\d+):(\d+): \((W\d+)\) (.*)$/.exec(line.trim());
    if (m) findings.push({ file: m[1], line: Number(m[2]), code: m[4], message: m[5] });
  }
  return findings;
}

export function summarise(findings) {
  const undefinedReads = findings.filter((f) => f.code === 'W113');
  const byFile = {};
  for (const f of findings) {
    if (f.code === 'W113') continue;
    byFile[f.file] = (byFile[f.file] ?? 0) + 1;
  }
  return { undefinedReads, byFile, total: findings.length - undefinedReads.length };
}

export function loadBaseline() {
  return existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : { files: {}, total: 0 };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const findings = scan();
  if (!findings) { console.error('luacheck not found'); process.exit(2); }
  const s = summarise(findings);
  if (process.argv.includes('--update')) {
    writeFileSync(BASELINE, JSON.stringify({
      note: 'luacheck warnings other than W113, per file. May only ever SHRINK -- see test/luacheck.test.ts. W113 is zero tolerance and is not recorded here.',
      total: s.total, files: s.byFile,
    }, null, 2) + '\n');
    console.log(`baseline updated: ${s.total} warning(s) across ${Object.keys(s.byFile).length} file(s)`);
  } else {
    console.log(`== ${s.undefinedReads.length} undefined-variable read(s) (W113, zero tolerance)`);
    for (const f of s.undefinedReads) console.log(`  ${f.file}:${f.line} ${f.message}`);
    console.log(`== ${s.total} other warning(s)`);
    for (const [file, n] of Object.entries(s.byFile).sort((a, b) => b[1] - a[1])) console.log(`  ${n}\t${file}`);
  }
}
