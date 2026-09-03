import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

/**
 * TESTS THAT RUN THE LUA.
 *
 * Until now every "Lua test" in this directory grepped the source for a line. That breaks on every
 * rename while the behaviour stands, and passes when the behaviour is wrong -- a comment with a CI
 * bill. hq/test/lua/run.lua loads the real modules under a stub ComputerCraft world (cc_stubs.lua)
 * and calls them: "a drone with 400 fuel is not offered a 588-fuel job, and the reason says so".
 *
 * Lua 5.4 rather than 5.5: CC: Tweaked's runtime is closest to 5.2, and 5.5's `<const>` semantics
 * already broke one tool tonight. One vitest case per Lua test, so a failure names the behaviour.
 */
const LUA = ['/opt/homebrew/opt/lua@5.4/bin/lua5.4', '/usr/local/opt/lua@5.4/bin/lua5.4', 'lua5.4', 'lua']
  .find((c) => { try { execFileSync(c, ['-v'], { stdio: 'pipe' }); return true; } catch { return false; } });

type Result = { name: string; ok: boolean; msg: string };

function runLua(): Result[] {
  const script = join(__dirname, 'lua', 'run.lua');
  let out = '';
  try {
    out = execFileSync(LUA!, [script], { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
  } catch (err: any) {
    // Non-zero exit means at least one failure; the results are still on stdout. No stdout at all
    // means the runner itself died -- surface that as the one result.
    out = String(err.stdout ?? '');
    if (!out.trim()) return [{ name: 'run.lua', ok: false, msg: String(err.stderr ?? err.message).slice(0, 2000) }];
  }
  return out.split('\n').filter((l) => l.trim().startsWith('{')).map((l) => JSON.parse(l));
}

describe('the Lua, executed', () => {
  it('a Lua 5.4 interpreter is installed', () => {
    expect(LUA, 'brew install lua@5.4 -- the behavioural Lua tests cannot run').toBeTruthy();
    expect(existsSync(join(__dirname, 'lua', 'run.lua'))).toBe(true);
  });

  const results = LUA ? runLua() : [];
  if (!results.length && LUA) {
    it('run.lua produced results', () => { expect(results.length).toBeGreaterThan(0); });
  }
  for (const r of results) {
    it(r.name, () => { expect(r.ok, r.msg).toBe(true); });
  }
});
