/**
 * THE TWO TRAPS THAT COST THE MOST AND ARE THE EASIEST TO CHECK.
 *
 * Both are documented in CLAUDE.md as things that have repeatedly cost hours. Documentation did not
 * stop either of them recurring -- including on the night this file was written, when I introduced
 * a fresh instance of the first one and only caught it by reading the declaration line afterwards.
 * A rule that fails the build is the cheap part.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';

const LUA_DIR = path.resolve(__dirname, '../../lua');
const files = readdirSync(LUA_DIR).filter((f) => f.endsWith('.lua'));

/**
 * Source with string literals and comments blanked, so prose never counts as code.
 *
 * STRINGS FIRST, THEN COMMENTS -- the other order is wrong and this file shipped with it briefly.
 * This codebase's log messages are full of `--`:
 *
 *   trace("heartbeat: tower unreachable -- handed to the fleet, still counting as a miss")
 *
 * Strip comments first and that truncates mid-string, leaving an unterminated quote the string
 * blanker cannot match -- so every word in the message survives as apparent code. It reported
 * DroneLogic using `heartbeat` 6,800 lines before its declaration, which is a sentence, not a bug.
 */
function codeOnly(src: string): string[] {
  // Long comments too -- `--[[ ... ]]` spans lines, and Sync.lua keeps its usage text in one. Blank
  // them line-for-line so reported line numbers still point at the real source.
  const lines = src.split('\n');
  let inLong = false;
  return lines.map((l) => {
    let out = l;
    if (inLong) {
      const close = out.indexOf(']]');
      if (close === -1) return '';
      out = out.slice(close + 2);
      inLong = false;
    }
    const open = out.indexOf('--[[');
    if (open !== -1 && out.indexOf(']]', open) === -1) {
      inLong = true;
      out = out.slice(0, open);
    }
    return out.replace(/"[^"]*"/g, '""').replace(/'[^']*'/g, "''").replace(/--.*$/, '');
  });
}

const exemptNear = (raw: string[], line: number, tag: string, span = 5) =>
  raw.slice(Math.max(0, line - span), line + 1).some((l) => l.includes(tag));

/**
 * print() calls per file at the time this rule was written.
 *
 * Inherited debt, not approval: ~170 calls across a codebase whose diagnostics have to survive to
 * the host. The number may fall and may not rise, so the debt drains as files are touched instead
 * of blocking the build on day one -- the same shape as the complexity ratchet.
 */
const BASELINE: Record<string, number> = {
  'Bridge.lua': 1, 'Debugger.lua': 7, 'DockingMan.lua': 7, 'DroneBoot.lua': 3,
  'DroneLogic.lua': 13, 'DroneMan.lua': 16, 'DroneTankingBoot.lua': 2, 'MainFrame.lua': 7,
  'MapServer.lua': 10, 'ModuleTemplate.lua': 1, 'PowGPSServer.lua': 25, 'PowNetRemote.lua': 28,
  'StorageMan.lua': 2, 'Sync.lua': 1, 'TankStation.lua': 7, 'TaskMan.lua': 7,
  'Template.lua': 3, 'pgps.lua': 3, 'turtleLogic.lua': 14,
};

describe('a local used above its declaration is a nil global', () => {
  /**
   * "No error, no warning -- the branch is simply dead. This has caused nine separate outages."
   * -- CLAUDE.md. It caused a tenth while I was fixing something else: POSE_FILE was declared 1,300
   * lines below the function I made use it, which would have thrown inside the one code path that
   * only runs when a drone is already lost.
   *
   * Lua allows a forward declaration (`local f` early, assigned later); that is fine and is not
   * what this catches. What it catches is a NAME being read before the line that introduces it.
   */
  for (const file of files) {
    it(file, () => {
      const raw = readFileSync(path.join(LUA_DIR, file), 'utf8').split('\n');
      const code = codeOnly(raw.join('\n'));
      const declaredAt = new Map<string, number>();
      code.forEach((l, i) => {
        // COLUMN ZERO ONLY. A `local` indented inside a function belongs to that function's
        // scope and says nothing about a same-named local elsewhere -- matching those produced
        // pure noise ("reply", "name", "short"). The documented trap is the FILE-level one:
        // a module constant or helper used by a function defined above it.
        const m = /^local\s+(?:function\s+)?([A-Za-z_]\w*)/.exec(l);
        if (m && !declaredAt.has(m[1])) declaredAt.set(m[1], i);
      });

      const bad: string[] = [];
      for (const [name, decl] of declaredAt) {
        if (name.length < 4) continue;                 // loop counters, i/j/k, too noisy to be useful
        for (let i = 0; i < decl; i++) {
          if (!new RegExp(`\\b${name}\\b`).test(code[i])) continue;
          if (exemptNear(raw, i, 'lua-scope: allow')) continue;
          bad.push(`${file}:${i + 1} uses "${name}", declared at line ${decl + 1}`);
          break;
        }
      }
      expect(bad, [
        'A `local` read above its declaration is a nil GLOBAL in Lua -- silent, and the branch is',
        'simply dead. Move the declaration above its first use, or if this is deliberate add:',
        '-- lua-scope: allow (<why>)',
      ].join('\n')).toEqual([]);
    });
  }
});

describe('diagnostics must be readable from outside the game', () => {
  /**
   * A CC terminal cannot be read from the host. `print` writes there and nowhere else; `Log` also
   * writes the file that every external view depends on.
   *
   * This is not theoretical tidiness. TaskMan's whole placement pass runs inside a pcall whose
   * error handler used `print`, so when it threw, the fleet silently stopped being given work and
   * the one message explaining why went to a screen nobody can see. Same for "TaskMan cannot reach
   * DroneMan -- no fleet to assign work to", which is THE explanation for an idle fleet. Hours went
   * into re-deriving both from source.
   */
  for (const file of files) {
    it(file, () => {
      const raw = readFileSync(path.join(LUA_DIR, file), 'utf8').split('\n');
      const code = codeOnly(raw.join('\n'));
      let count = 0;
      code.forEach((l, i) => {
        if (!/(^|[^\w.])print\s*\(/.test(l)) return;
        if (exemptNear(raw, i, 'lua-visible: allow')) return;
        count++;
      });
      // A RATCHET, NOT A CLIFF. There are legitimate print()s -- installer prompts, the MainFrame
      // dashboard, boot breadcrumbs before Log exists -- and ~90 inherited ones besides. Failing
      // the build on all of them at once would get the rule deleted rather than heeded. So the
      // count may fall and may not rise: every new diagnostic has to be readable from the host,
      // and the debt drains as files are touched.
      const allowed = BASELINE[file] ?? 0;
      expect(count, [
        `${file} has ${count} print() call(s), baseline ${allowed}.`,
        'print() goes to the in-game terminal only, which the host cannot read. Use Log() so the',
        'message survives to a file -- the difference between a diagnosable fault and a silent one.',
        'TaskMan lost its entire placement pass to exactly this. For genuine terminal-only output',
        'add: -- lua-visible: allow (<why>)',
      ].join('\n')).toBeLessThanOrEqual(allowed);
    });
  }
});

describe('hot loops over peripherals must yield', () => {
  /**
   * CC:T terminates a coroutine that runs ~10s without yielding, and the kill is uncatchable: the
   * bootloader never reaches os.reboot(), so the computer ends up POWERED OFF while last-run.txt
   * still reads ok=true. That is the worst shape a failure can take here, because every external
   * view says the module exited cleanly.
   *
   * Measured: "Terminating computer #14 due to timeout (ran over by 22.328 seconds)" -- StorageMan
   * died inside BuildIndex, which wraps and lists every chest and furnace on the network with no
   * yield, on every tick and every query. Stock, smelting and every storage query in the settlement
   * went with it.
   *
   * Any loop that crosses into Java per iteration -- peripheral.wrap, .list, .size, pushItems,
   * pullItems -- needs a yield in it. queueEvent/pullEvent, which resumes in the same tick.
   */
  // THE HELPER COUNTS AS THE THING IT REPLACED, IN BOTH DIRECTIONS.
  //
  // StorageMan's thirteen hand-written yields became breathe() and its seven guarded wraps became
  // wrapped(). Matching only the literal calls would have broken this check twice over: every
  // deduplicated loop would read as "never yields" (noisy, and it did), and -- far worse -- as
  // "never crosses into Java", which is a SILENT false negative in the check whose whole job is to
  // stop the storage server being killed mid-scan. An extraction must not take the guard with it.
  const YIELDS = /os\.queueEvent|os\.pullEvent|os\.sleep|\bbreathe\s*\(/;
  const CROSSES = /peripheral\.wrap|\bwrapped\s*\(|\.pushItems|\.pullItems|peripheral\.call/;
  // ONLY LOOPS THAT GROW WITH THE NETWORK.
  //
  // A loop over one inventory's slots, or `for i = 1, 16`, is bounded and small however big the
  // settlement gets -- and its OUTER loop is the one that needs the yield. Flagging those too
  // produced eight false positives against four real ones, and a rule with that ratio gets
  // exemption-stamped into uselessness. These are the collections that scale: every peripheral on
  // the wired network, every chest, every furnace, every route, the whole item index.
  const UNBOUNDED = /peripheral\.getNames\(\)|\bm_Chests\b|\bm_Furnaces\b|\bm_Index\b|\bs_Routes\b|\bs_Names\b|\bs_Chests\b/;

  for (const file of files) {
    it(file, () => {
      const raw = readFileSync(path.join(LUA_DIR, file), 'utf8').split('\n');
      const code = codeOnly(raw.join('\n'));
      const bad: string[] = [];
      code.forEach((l, i) => {
        if (!/\bfor\b.*\bdo\b/.test(l)) return;
        if (!UNBOUNDED.test(l)) return;
        // The loop body: to the matching-ish `end` at the same indent, capped so one runaway
        // regex cannot swallow the file.
        const indent = (l.match(/^\s*/) ?? [''])[0].length;
        let end = i + 1;
        while (end < code.length && end < i + 60) {
          if (new RegExp(`^\\s{${indent}}end\\b`).test(code[end])) break;
          end++;
        }
        const body = code.slice(i, end).join('\n');
        if (!CROSSES.test(body) || YIELDS.test(body)) return;
        if (exemptNear(raw, i, 'lua-yield: allow')) return;
        bad.push(`${file}:${i + 1} ${raw[i].trim().slice(0, 70)}`);
      });
      expect(bad, [
        'This loop calls into Java every iteration and never yields. CC:T kills a coroutine that',
        'runs ~10s without yielding, uncatchably -- the computer ends up OFF with a clean-looking',
        'last-run. Add `os.queueEvent("x") os.pullEvent("x")` inside the loop, or if the iteration',
        'count is genuinely bounded and small: -- lua-yield: allow (<why>)',
      ].join('\n')).toEqual([]);
    });
  }
});
