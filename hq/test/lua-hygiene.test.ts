/**
 * STATIC GUARDS FOR THE MISTAKES THIS CODEBASE ACTUALLY KEEPS MAKING.
 *
 * Every rule here is a bug that shipped, was diagnosed at cost, fixed -- and then reappeared
 * somewhere else, because the knowledge lived in one function and the next author (usually me) wrote
 * a fresh copy. Extracting a helper does not prevent that; nothing stops copy number five. A check
 * that fails the build does.
 *
 * These run against the Lua sources from the TypeScript test suite because that is the only test
 * runner in the project. If a rule here fires, do not weaken the rule -- the rule is the cheapest
 * part of the loop.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';

const LUA_DIR = path.resolve(__dirname, '../../lua');

/**
 * An exemption is a `-- lua-hygiene: allow (<why>)` comment on the offending line or just above it.
 *
 * Checked over a small window rather than a single line, because a justification worth writing is
 * usually a sentence or two -- and requiring it to fit on one line is how a rule gets bypassed by
 * deleting the explanation instead of keeping it.
 */
const exempt = (raw: string[], i: number, span = 4) =>
  raw.slice(Math.max(0, i - span), i + 1).some((l) => /lua-hygiene: allow/.test(l));
const files = readdirSync(LUA_DIR).filter((f) => f.endsWith('.lua'));
const read = (f: string) => readFileSync(path.join(LUA_DIR, f), 'utf8');

/**
 * Strip string literals and comments so matches are on code, not prose.
 *
 * STRINGS FIRST. This stripped comments first, so a `--` INSIDE a string literal truncated the line
 * mid-string and left the opening quote unmatched -- after which the string regex could not match
 * and the prose leaked back in as if it were code. `trace("heartbeat: ... -- relayed ...")` was
 * reported as a use of the `heartbeat` function, four thousand lines above its declaration.
 *
 * The failure mode that matters is the quiet one: the same bug silently HIDES real violations
 * whenever the offending identifier happens to sit after a `--` in a string, so every rule built on
 * this helper was weaker than it looked.
 */
function code(src: string): string[] {
  return src.split('\n').map((l) => {
    const noStrings = l
      .replace(/"(?:[^"\\]|\\.)*"/g, '""')
      .replace(/'(?:[^'\\]|\\.)*'/g, "''");
    return noStrings.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--.*$/, '');
  });
}

describe('lua hygiene: the local-declared-below trap', () => {
  /**
   * A `local x` at file scope declared BELOW a function that references `x` does not resolve to
   * that local. It compiles to a GLOBAL lookup, which is nil, silently, for ever.
   *
   * Seven separate outages: pgps.mayStep (underground movement never worked at all), m_DroneEvents,
   * reportTask, digGuarded, m_HomePos (the distance-aware fuel floor silently reverted to a flat
   * constant), and two more. There is no error and no warning -- the branch is simply dead.
   */
  for (const f of files) {
    it(`${f} has no file-scope local used above its declaration`, () => {
      const lines = code(read(f));

      // File-scope `local name` / `local name, other` -- column 0 only.
      const declaredAt = new Map<string, number>();
      lines.forEach((l, i) => {
        const m = /^local\s+(?:function\s+)?([A-Za-z_][\w]*)/.exec(l);
        if (m && !declaredAt.has(m[1])) declaredAt.set(m[1], i);
      });

      // Function bodies that begin at column 0.
      const offenders: string[] = [];
      for (const [name, declLine] of declaredAt) {
        // Only names distinctive enough to match safely.
        if (name.length < 3) continue;
        const use = new RegExp(`\\b${name}\\b`);
        for (let i = 0; i < declLine; i++) {
          if (!/^(local\s+)?function\s/.test(lines[i])) continue;
          // Walk this function body to its terminating `end` at column 0.
          for (let j = i + 1; j < declLine; j++) {
            if (/^end\b/.test(lines[j])) break;
            if (use.test(lines[j]) && !/^local\s/.test(lines[j])) {
              offenders.push(`${name}: used line ${j + 1}, declared line ${declLine + 1}`);
              break;
            }
          }
        }
      }
      expect(offenders, `${f}:\n  ${offenders.join('\n  ')}`).toEqual([]);
    });
  }
});

describe('lua hygiene: no fresh copies of the shared primitives', () => {
  /**
   * Taking items out of a chest is subtle in one specific way, and the subtlety is invisible until
   * it costs you an hour:
   *
   *   turtle.suckDown ALWAYS takes the chest's first occupied slot. Pull a stack, decide it is not
   *   what you wanted, drop it back -- and it returns to that same first slot. So a drone cycles
   *   the same cobblestone for ever and never sees the coal four slots behind it.
   *
   * stageFromChest solved this and wrote it down. CollectFuel then had to rediscover it. Then
   * RefuelAtStorage flew home with 641 fuel from a chest holding three stacks of coal, because the
   * fix lived in a different function. Then the craft self-fetch would have been the fourth.
   *
   * TakeFromChest is now the one implementation. This test is what stops the fifth.
   */
  it('withdrawing from a chest goes through TakeFromChest', () => {
    const src = read('DroneLogic.lua');
    const lines = code(src);
    // Markers live in comments, and code() strips comments -- so read them from the raw source.
    const raw = src.split('\n');

    // Where the sanctioned implementations live.
    const allowed = [
      /^function TakeFromChest/,     // the primitive itself
      /^local function stageFromChest/, // pre-existing, and the one that got it RIGHT
    ];
    const spans: Array<[number, number]> = [];
    lines.forEach((l, i) => {
      if (!allowed.some((re) => re.test(l))) return;
      let j = i + 1;
      while (j < lines.length && !/^end\b/.test(lines[j])) j++;
      spans.push([i, j]);
    });
    const inAllowed = (i: number) => spans.some(([a, b]) => i >= a && i <= b);

    const offenders = lines
      .map((l, i) => ({ l, i }))
      // An explicit `-- lua-hygiene: allow (<why>)` on the line or just above it is a deliberate,
      // reviewable exemption. Weakening the rule instead would make it worthless.
      .filter(({ l, i }) =>
        /turtle\.suckDown/.test(l) &&
        !inAllowed(i) &&
        !exempt(raw, i))
      .map(({ i }) => `line ${i + 1}`);

    expect(
      offenders,
      `raw turtle.suckDown outside TakeFromChest at ${offenders.join(', ')} -- ` +
      `use the primitive; it knows about the leading-stacks trap`,
    ).toEqual([]);
  });

  /**
   * The travel chain -- moveTo, then digTo, then flyTo -- was missing from Mine, Gather, Deposit
   * AND RefuelAtStorage. Each omission stalled something different and was diagnosed separately:
   * miners that could not reach their own shaft head, gathers that reached zero buried targets,
   * deposits that failed silently and aborted the gather that called them.
   *
   * A bare moveTo whose failure is not handled is the shape of that bug.
   */
  it('every pgps.moveTo has a fallback or is inside a travel primitive', () => {
    const srcMove = read('DroneLogic.lua');
    const lines = code(srcMove);
    const raw = srcMove.split('\n');
    const offenders: string[] = [];
    lines.forEach((l, i) => {
      if (!/pgps\.moveTo\(/.test(l)) return;
      // Look ahead a few lines for a fallback, or an explicit best-effort marker.
      const after = raw.slice(i, i + 14).join(' ');
      const hasFallback = /digTo|flyTo|TravelTo|ArriveAt|best effort|FlyHome/i.test(after);
      // The primitives themselves are the fallback. ReachByAnyMeans joined them when the
      // moveTo -> climb -> digTo ladder was pulled out of DepositNow: it is the ladder, so
      // demanding that IT have a fallback is asking the fallback to have a fallback.
      const inPrimitive = lines.slice(Math.max(0, i - 40), i)
        .some((p) => /^function (TravelTo|ArriveAt|FlyHome|ReachByAnyMeans)/.test(p));
      if (!hasFallback && !inPrimitive && !exempt(raw, i)) offenders.push(`line ${i + 1}`);
    });
    expect(
      offenders,
      `pgps.moveTo without a fallback at ${offenders.join(', ')} -- ` +
      `route through TravelTo/ArriveAt, or say why a bare move is correct here`,
    ).toEqual([]);
  });
});

describe('lua hygiene: dropping is not depositing', () => {
  /**
   * turtle.dropDown with a container below deposits. With anything else below -- including being
   * ONE BLOCK off the chest -- it throws the stack on the ground, returns true, and the items
   * despawn. No error, no way to tell afterwards.
   *
   * That is where sixteen freshly cut logs went. Not a reboot (a turtle's inventory survives one);
   * a drone that arrived beside the chest instead of on it and tipped its cargo onto the floor
   * while reporting success. There were ten unguarded call sites.
   */
  it('every drop goes through PutDown, which checks what is underneath', () => {
    const src = read('DroneLogic.lua');
    const raw = src.split('\n');
    const lines = code(src);
    const guard = lines.findIndex((l) => /^function PutDown\(/.test(l));
    const offenders = lines
      .map((l, i) => ({ l, i }))
      .filter(({ l, i }) =>
        /turtle\.dropDown/.test(l) &&
        !(guard >= 0 && i >= guard && i <= guard + 4) &&
        !exempt(raw, i))
      .map(({ i }) => `line ${i + 1}`);
    expect(
      offenders,
      `raw turtle.dropDown at ${offenders.join(', ')} -- use PutDown, or the cargo lands on the floor`,
    ).toEqual([]);
  });
});

describe('lua hygiene: long jobs must survive a reboot', () => {
  /**
   * MainFrame broadcasts INIT on every boot, and INIT stands the WHOLE FLEET down. So any deploy
   * interrupts whatever every drone is doing -- that is by design and it is fine. What is not fine
   * is that the job then restarted from its original order and re-walked work it had already
   * finished: a gather went back to "0/96 checked, 0 taken" on ground it had already stripped, and
   * sixteen already-cut logs were lost that way.
   *
   * `Resumable(d)` is two lines and makes a job pick up where it stopped. This test is here because
   * the alternative -- remembering to add it to each new job -- is exactly the habit that produced
   * every other repeated bug in this file.
   */
  it('every substantial job handler uses Resumable', () => {
    const src = read('DroneLogic.lua');
    const raw = src.split('\n');
    const lines = code(src);

    // Handlers actually wired into the drone's verb table.
    const wired = new Set<string>();
    const tableStart = lines.findIndex((l) => /^m_DroneEvents\s*=/.test(l));
    if (tableStart >= 0) {
      for (let i = tableStart; i < lines.length && !/^}/.test(lines[i]); i++) {
        const m = /func\s*=\s*(On\w+)/.exec(lines[i]);
        if (m) wired.add(m[1]);
      }
    }
    expect(wired.size, 'no handlers found -- the table shape changed').toBeGreaterThan(5);

    const offenders: string[] = [];
    for (const name of wired) {
      const start = lines.findIndex((l) => new RegExp(`^function ${name}\\b`).test(l));
      if (start < 0) continue;
      let end = start + 1;
      while (end < lines.length && !/^end\b/.test(lines[end])) end++;
      const body = lines.slice(start, end);
      // Include the few lines ABOVE the handler: an exemption belongs in the doc comment that
      // explains it, not buried inside the body. Same convention as the other rules here.
      const bodyRaw = raw.slice(Math.max(0, start - 6), end).join('\n');

      // Short handlers do no iterative work; there is nothing to resume.
      if (body.length < 40) continue;
      // A job that iterates work items is the case that matters.
      const iterates = body.some((l) => /\bfor\b.*\b(ipairs|pairs)\b/.test(l) || /\bwhile\b/.test(l));
      if (!iterates) continue;
      if (/Resumable\s*\(/.test(bodyRaw)) continue;
      if (/lua-hygiene: allow/.test(bodyRaw)) continue;
      offenders.push(`${name} (${body.length} lines)`);
    }

    expect(
      offenders,
      `these jobs restart from scratch after a fleet stand-down: ${offenders.join(', ')} -- ` +
      `add Resumable(d) (two lines), or mark why restarting is correct`,
    ).toEqual([]);
  });
});

describe('lua hygiene: a chest write that is not reported is drift', () => {
  /**
   * StorageMan's picture of where things are comes from drones reporting what they observed in the
   * chest they were standing on. That only stays true if EVERY path that changes a chest reports it.
   *
   * This is not hypothetical and it is not a one-off. The delta ledger drifted first: 22 oak logs
   * were withdrawn, the craft failed, the logs went back unreported, and stock read zero while the
   * chest held 22 -- so the crafter was dispatched to the wrong chest for hours. Replacing deltas
   * with observations fixed that, and then the craft's grid clean-up put 6 surplus logs back without
   * reporting, the chest was recorded as empty, and the fetch sweep SKIPPED it. Stale is worse than
   * absent: absent means "go and look", stale means "do not bother".
   *
   * So: a function that calls PutDown in a loop is writing to a chest, and must call ReportChest
   * before it returns. Handovers are the exception -- they drop onto a drone, not a container.
   */
  it('every function that bulk-writes to a chest calls ReportChest', () => {
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      const lines = code(read(f));
      let start = -1, name = '', puts = 0, reports = 0, depth = 0;
      const flush = (end: number) => {
        // A single PutDown is a one-off (a handover, a probe); a loop of them is a deposit.
        if (start >= 0 && puts >= 2 && reports === 0 && !exempt(raw, start, 6)) {
          offenders.push(`${f}:${start + 1} ${name} writes to a chest but never calls ReportChest`);
        }
      };
      lines.forEach((l, i) => {
        const m = l.match(/^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)?/);
        if (m && depth === 0) { flush(i); start = i; name = m[1] ?? '?'; puts = 0; reports = 0; }
        if (/\bfunction\b/.test(l)) depth++;
        if (/^\s*end\b/.test(l) && depth > 0) depth--;
        if (/\bPutDown\s*\(/.test(l)) puts++;
        if (/\bReportChest\s*\(/.test(l)) reports++;
      });
      flush(lines.length);
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: a failed turtle call must not discard its reason', () => {
  /**
   * `turtle.forward()` returns `false, "<reason>"`. Every mover in pgps discarded the second value,
   * so "Cannot enter protected area" -- a server configuration fault that NO retry can ever fix --
   * reached the caller as a bare `false`, indistinguishable from a rock in the way.
   *
   * TravelTo then did what it does for a rock: mapped route, climb out, dig through, fly over. All
   * five failed identically and silently. The fleet sat frozen for hours logging "no mapped route"
   * while the very first call had stated the cause exactly. The cost of that lost string was an
   * entire day of chasing congestion, pathfinding and GPS -- none of which were wrong.
   *
   * So: if a function calls a turtle movement API inside a condition and has a failure branch, it
   * has to capture the reason. `local ok, err = turtle.forward()` is the shape we want.
   */
  it('turtle movement failures capture the error string', () => {
    const MOVERS = /\bturtle\.(forward|back|up|down)\s*\(\s*\)/;
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        if (!MOVERS.test(l)) return;
        // Capturing forms: `local ok, err = turtle.up()` / `= turtle.up()` assigned to two names.
        if (/local\s+[\w_]+\s*,\s*[\w_]+\s*=\s*turtle\.(forward|back|up|down)/.test(l)) return;
        // A bare guarded call with no failure branch is fine -- nothing is being swallowed.
        if (!/\bif\b/.test(l)) return;
        if (exempt(raw, i, 4)) return;
        offenders.push(`${f}:${i + 1} discards the reason from ${l.trim()}`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: turtle.dig is always a function', () => {
  /**
   * `turtle.dig` exists on EVERY turtle whether or not a tool is equipped -- it simply returns
   * `false, "No tool to dig with"`. So `if turtle.dig then` is always true and `if turtle.dig == nil`
   * is always false, and both read exactly like a capability check while performing none.
   *
   * That cost real behaviour twice over: the "a crafter that cannot dig should ask a miner for help"
   * path could never once have run, and crafters executed the full 256-step digTo loop failing on
   * every step instead of skipping straight to flying. Verified by probe on D4 -- dig=function,
   * left=modem, right=workbench, no pickaxe anywhere.
   *
   * The honest test is CanDig()/canDig(): a turtle has two upgrade slots, peripherals report a type,
   * tools do not -- so both slots occupied by peripherals means no tool.
   */
  it('nothing uses turtle.dig as a capability check', () => {
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        // Calling it is fine. Testing its truthiness or nil-ness is the bug.
        if (!/\bturtle\.dig\b/.test(l)) return;
        if (/\bturtle\.dig\s*\(/.test(l)) return;                 // a call, not a test
        // Passed as an argument (digGuarded(turtle.dig, ...)) is a reference, not a capability test.
        if (/\bturtle\.dig\s*,/.test(l)) return;
        if (!/\b(if|and|or|not)\b/.test(l)) return;
        if (exempt(raw, i, 4)) return;
        offenders.push(`${f}:${i + 1} tests turtle.dig as a capability: ${l.trim()}`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: every pgps.X() a caller uses must exist', () => {
  /**
   * A refactor of digTo deleted moveTo along with it -- the file still PARSED, luac was happy, and
   * every drone crashed on "attempt to call a nil value" the moment it tried to travel. Lua resolves
   * `pgps.moveTo` at call time, so a missing export is invisible until production.
   *
   * This is the cheapest possible guard: the set of names callers reference must be a subset of the
   * names the API defines. It would have caught that deletion the instant it was made, instead of
   * after a fleet reboot and a crash report.
   */
  it('DroneLogic only calls pgps functions that pgps defines', () => {
    const pgps = read('pgps.lua');
    const defined = new Set<string>();
    for (const m of pgps.matchAll(/^\s*(?:local\s+)?function\s+([A-Za-z_]\w*)\s*\(/gm)) {
      defined.add(m[1]);
    }
    // Fields are legitimate too (pgps.SOMETHING = ...), so count those as defined.
    for (const m of pgps.matchAll(/^\s*([A-Za-z_]\w*)\s*=/gm)) defined.add(m[1]);

    const missing = new Set<string>();
    for (const f of files) {
      if (f === 'pgps.lua') continue;
      for (const l of code(read(f))) {
        for (const m of l.matchAll(/\bpgps\.([A-Za-z_]\w*)\s*\(/g)) {
          if (!defined.has(m[1])) missing.add(`${f} calls pgps.${m[1]}() which pgps.lua does not define`);
        }
      }
    }
    expect([...missing]).toEqual([]);
  });
});

describe('lua hygiene: SCREAMING_CASE constants must be defined where they are used', () => {
  /**
   * A refactor deleted moveTo and, with it, MOVE_LEG_MIN / MOVE_LEG_MAX / MOVE_STUCK. The file still
   * parsed; luac was happy. At runtime `s_Before <= s_Leg` compared a number with nil and every
   * drone crashed mid-journey -- twice, because restoring the function did not restore the constants
   * and the second failure looked like a different bug entirely.
   *
   * An upper-case identifier used but never assigned in its own file is nil, and nil in this
   * codebase means "silently wrong" far more often than "crash". Cheap to check, and it catches the
   * whole class: deletions, typos, and constants that moved file without their callers.
   */
  it('no file uses a CONSTANT it never defines', () => {
    const offenders: string[] = [];
    for (const f of files) {
      const lines = code(read(f));
      const src = lines.join('\n');
      const defined = new Set<string>();
      for (const m of src.matchAll(/^\s*(?:local\s+)?([A-Z][A-Z0-9_]*_[A-Z0-9_]+)\s*=/gm)) defined.add(m[1]);
      // Names provided by CC, PowNet or another API are not this file's business.
      const external = /^(MESSAGE_TYPE|SERVER_PROTOCOL|DRONE_PROTOCOL|REDNET_TIMEOUT|MAINFRAME)$/;
      const used = new Set<string>();
      // Must contain an underscore: that is what distinguishes a constant (MOVE_LEG_MIN) from an
      // ordinary capitalised word that happens to appear in a message (REFUSED, DRONE, DATA).
      for (const m of src.matchAll(/\b([A-Z][A-Z0-9_]*_[A-Z0-9_]+)\b/g)) {
        const n = m[1];
        if (defined.has(n) || external.test(n)) continue;
        // Qualified references (PowNet.X, pgps.X, os.X) belong to the other module.
        if (new RegExp(`[\\w.]\\.${n}\\b`).test(src)) continue;
        used.add(n);
      }
      for (const n of used) offenders.push(`${f} uses ${n} but never defines it`);
    }
    expect(offenders).toEqual([]);
  });
});

/*
 * REMOVED: "a global function called above its definition line".
 *
 * The bug was real -- SendHeartBeat called MeshReady, defined 4,600 lines lower, and every drone
 * died at boot on "attempt to call global 'MeshReady' (a nil value)". But the rule is not
 * statically decidable: `function f()` assigns the global when execution REACHES it, so a call
 * textually above the definition is perfectly safe as long as the caller runs after load -- which
 * is true of almost every function in these files. The rule flagged eleven sites, ten of them
 * correct code, and a check that is mostly false alarms trains people to ignore the suite.
 *
 * What actually catches this: last-run.txt records the module's runtime error verbatim, which
 * identified this one in seconds. The call site is now guarded with type(f) == "function", which is
 * the cheap defence for anything on the boot path.
 */

describe('lua hygiene: never move the turtle without recording it', () => {
  /**
   * pgps tracks position by counting its own moves. A RAW turtle.forward/back/up/down bypasses that
   * counter, so the drone physically moves while believing it did not -- and the error is permanent,
   * silent, and cumulative.
   *
   * Heading derivation legitimately needs raw moves (pgps.forward needs a heading, which is what it
   * is deriving), and it steps out and back so the net is zero. But the return move was UNCHECKED:
   * whenever something sat behind the drone it stayed one block forward, one block wrong, for ever.
   * Two drones were found 28 and 45 blocks from their own saved pose, still convinced they were
   * inside the operating region -- so the region-return never fired and every recovery path was
   * reasoning from fiction.
   *
   * So: a raw turtle move must either have its result captured, or carry an explicit exemption
   * saying why losing track is safe there.
   */
  it('raw turtle moves capture their result', () => {
    const RAW = /\bturtle\.(forward|back|up|down)\s*\(\s*\)/;
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        if (!RAW.test(l)) return;
        // Captured: `local ok = turtle.x()` / `local ok, err = turtle.x()` / used in a condition.
        if (/=\s*turtle\.(forward|back|up|down)\s*\(/.test(l)) return;
        if (/\b(if|while|and|or|not|return)\b.*turtle\.(forward|back|up|down)\s*\(/.test(l)) return;
        if (exempt(raw, i, 6)) return;
        offenders.push(`${f}:${i + 1} ${l.trim()}`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: diagnostics must reach the log, not just the screen', () => {
  /**
   * In CC, print() writes to the turtle's SCREEN. Nothing collects it, nothing persists it, and it
   * is readable only by a person standing in the world in front of that specific turtle.
   *
   * pgps -- the module where drones actually get lost -- had twenty-nine bare prints and no logging
   * at all. Among them: "position corrected by 90", "heading re-established: E", and "moved but
   * could not deduce heading". A drone whose cached heading was silently wrong walked 121 blocks in
   * the wrong direction while drone.log recorded, truthfully and uselessly, that it was closing the
   * gap on home. verifyPosition had already COMPUTED the drift every single time and printed it
   * into the void. The bug took hours to find; one of these lines in the log names it outright.
   *
   * So a diagnostic in the movement/logic modules goes through trace()/ptrace(), which print AND
   * append. Bare print() is for the interactive tools, where a human is by definition watching.
   */
  const LOGGED = ['pgps.lua', 'DroneLogic.lua'];
  /**
   * A print carrying INTERPOLATED content is a diagnostic -- it is reporting a value that was
   * computed at runtime, which is exactly the thing you cannot reconstruct afterwards. A print of a
   * fixed string is a banner or a blank line: it tells you the code reached a point you could have
   * worked out from the source anyway. Only the first kind is worth failing the build over, and the
   * distinction is decidable from the line itself.
   */
  const CARRIES_DATA = /\.\.|tostring\s*\(|:format\s*\(|%[dsq]|textutils\./;
  it('movement and drone logic log the values they compute', () => {
    const offenders: string[] = [];
    for (const f of files) {
      if (!LOGGED.includes(f)) continue;
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        if (!/(^|[^a-zA-Z_.])print\s*\(/.test(l)) return;
        if (/\b(ptrace|trace)\s*\(/.test(l)) return;   // the wrapper itself prints, by design
        if (/printError\s*\(/.test(l)) return;          // errors surface through their own channel
        if (!CARRIES_DATA.test(l)) return;               // a banner, not a diagnostic
        if (exempt(raw, i, 4)) return;
        offenders.push(`${f}:${i + 1} ${l.trim()}`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: one compass, not six', () => {
  /**
   * N, W, S, E = 0, 1, 2, 3, anticlockwise, everywhere in first-party code.
   *
   * Six copies of this declaration existed and they did not all agree. DockingMan's read
   * `North, West, East, South = 0, 1, 2, 3` -- East and South swapped -- in the module that hands
   * out dock berths and their orientations. It was dead code and never fired, but it was one
   * reference away from turning every dock approach ninety degrees.
   *
   * The numbering is arbitrary; disagreeing about it is not survivable. A heading is how pgps turns
   * "forward" into a change of coordinates, so a module that is off by one does not compute a wrong
   * answer -- it drives the drone the opposite way while its log reports that it is heading home.
   * That is exactly the failure that stranded five drones: one of them believed it was standing at
   * home while sitting 121 blocks away, having travelled east the entire journey.
   *
   * Modules that cannot load pgps (they run on their own computers) must still declare it, so the
   * rule enforces the ORDER rather than banning the declaration. /lua/libs is vendored upstream
   * code and exempt: lama genuinely uses the opposite rotation, which is why nothing may hand it a
   * raw number -- conversions at that seam go through names.
   */
  const CANON = 'North, West, South, East, Up, Down = 0, 1, 2, 3, 4, 5';
  it('every first-party compass declaration uses the same order', () => {
    const offenders: string[] = [];
    for (const f of files) {
      code(read(f)).forEach((l, i) => {
        if (!/\bNorth\b.*=.*\b0\b\s*,\s*1\s*,\s*2\s*,\s*3/.test(l)) return;
        if (l.trim().replace(/\s+/g, ' ') === CANON) return;
        offenders.push(`${f}:${i + 1} ${l.trim()}  (expected: ${CANON})`);
      });
    }
    expect(offenders).toEqual([]);
  });

  it('no module keeps its own name-to-number compass table', () => {
    const offenders: string[] = [];
    for (const f of files) {
      if (f === 'pgps.lua') return;                 // the one canonical table lives here
      code(read(f)).forEach((l, i) => {
        if (/\bnorth\s*=\s*\d\s*,\s*\w+\s*=\s*\d/.test(l)) offenders.push(`${f}:${i + 1} ${l.trim()}`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: primitives take the shapes they document', () => {
  /**
   * FetchItems(p_Want, p_Min) takes TWO TABLES of item -> count. Both are iterated with pairs().
   *
   * A scalar in either position is not a type error in Lua, it is a runtime crash at the first
   * pairs() -- and it crashes inside the primitive, so the traceback names FetchItems rather than
   * the caller that got it wrong. `FetchItems({coal = 64}, 8)` failed fuel-D3 with "bad argument
   * (table expected, got number)" in the very function that had just been rewritten to stop fuel
   * deliveries failing. The rewrite was right; the call was one argument shy of correct.
   *
   * Cheap to check and worth checking: these primitives exist precisely so that many callers share
   * them, which is exactly what makes one malformed call expensive.
   */
  it('FetchItems is called with two tables', () => {
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        const m = /FetchItems\s*\(([^)]*)\)/.exec(l);
        if (!m || /function FetchItems/.test(l)) return;
        // Split on the top-level comma only: `{a = 1}, {b = 2}` must not split inside the braces.
        let depth = 0, split = -1;
        for (let k = 0; k < m[1].length; k++) {
          const c = m[1][k];
          if (c === '{' || c === '(') depth++;
          else if (c === '}' || c === ')') depth--;
          else if (c === ',' && depth === 0) { split = k; break; }
        }
        if (split < 0) return;                       // one argument: p_Min defaults to p_Want
        const second = m[1].slice(split + 1).trim();
        // A table literal or an identifier holding one. A bare number or string is the bug.
        if (/^[{a-zA-Z_]/.test(second)) return;
        if (exempt(raw, i, 4)) return;
        offenders.push(`${f}:${i + 1} second argument is \`${second}\`, expected a table`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: os.sleep(0) is a tick, not a yield', () => {
  /**
   * `os.sleep(0)` is `os.startTimer(0)` plus a pullEvent, and a zero-delay timer does not fire
   * until the NEXT GAME TICK. It is fifty milliseconds of doing nothing, not a free hand-off.
   *
   * Used as the periodic yield inside a loop over a large structure, that dominates everything.
   * A* yields every 200 nodes, so a search spending its 20,000-node budget cost a hundred sleeps --
   * FIVE SECONDS of wall clock, almost all of it waiting -- and MapServer answers one drone at a
   * time. Seventeen drones asking produced a queue nobody reached the front of: 181 "pathfinder did
   * not answer" in one night and MapServer reported unreachable, while it sat idle-waiting. The map
   * load had the same shape and took 49 seconds; the same file now parses more cells in 10.
   *
   * `os.queueEvent(tag)` + `os.pullEvent(tag)` satisfies the watchdog -- which wants a YIELD, not a
   * delay -- and resumes in the same tick, because the event is already queued when we ask.
   *
   * A real `os.sleep(n)` with n > 0 is a different thing entirely and is left alone: that is a
   * deliberate wait, and this rule does not touch it.
   */
  it('no loop yields with os.sleep(0)', () => {
    const offenders: string[] = [];
    for (const f of files) {
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        if (!/os\.sleep\s*\(\s*0\s*\)/.test(l)) return;
        if (exempt(raw, i, 4)) return;
        offenders.push(`${f}:${i + 1} ${l.trim()} -- use os.queueEvent/os.pullEvent`);
      });
    }
    expect(offenders).toEqual([]);
  });
});

describe('lua hygiene: the map is only as good as the position it was recorded from', () => {
  /**
   * Every observation is keyed by the drone's BELIEVED position plus an offset. When that belief is
   * wrong the block is real, the reading is honest, and the coordinate is fiction -- so the map
   * learns solid terrain where there is air, and every route planned through it is planned around a
   * wall that does not exist.
   *
   * This bit hard the moment drones were allowed to keep working without GPS: dead reckoning
   * underground, peer-trilaterated fixes good only to tens of blocks, and SeekCoverage which walks
   * while deliberately unverified. All three filed observations, and the operator saw slabs of
   * phantom terrain scattered wherever a lost drone had travelled.
   *
   * So noteObservation refuses without a verified fix, and nothing may write to the pending buffers
   * behind its back. requeueObservations is the one sanctioned exception -- it puts back a delta
   * that was verified when taken and that MapServer merely failed to accept.
   */
  it('nothing writes pendingWorld/pendingDetail except the gate and the requeue', () => {
    const src = read('pgps.lua');
    const raw = src.split('\n');
    const offenders: string[] = [];
    // Which function each line belongs to, so a write can be attributed.
    let fn = '(file scope)';
    code(src).forEach((l, i) => {
      const m = /^\s*function\s+([\w.:]+)/.exec(l) ?? /^local function\s+(\w+)/.exec(l);
      if (m) fn = m[1]!;
      if (!/\bpending(World|Detail)\s*\[/.test(l)) return;
      if (/=\s*\{\s*\}/.test(l)) return;                       // resetting the buffers is not a write
      if (['noteObservation', 'requeueObservations', 'takeWorldDelta'].includes(fn)) return;
      if (exempt(raw, i, 4)) return;
      offenders.push(`pgps.lua:${i + 1} writes pending state from ${fn}, bypassing the fix check`);
    });
    expect(offenders).toEqual([]);
  });

  it('noteObservation checks positionVerified before recording', () => {
    const src = code(read('pgps.lua')).join('\n');
    const fn = src.slice(src.indexOf('function noteObservation'));
    const body = fn.slice(0, fn.indexOf('\nend'));
    expect(body).toMatch(/positionVerified\(\)/);
  });
});

describe('lua hygiene: heading-to-offset maps use the canonical compass', () => {
  /**
   * N, W, S, E = 0, 1, 2, 3, and NORTH IS MINUS Z. The declarations are already checked elsewhere;
   * this checks the places that turn a heading into an actual offset, which is where it does damage.
   *
   * DockingMan's GetXZFromHeading read 0=n, 1=e, 2=s, 3=w -- the clockwise convention the vendored
   * LAMA library uses -- and returned z = +1 for north. So a berth on heading 1 was sited east when
   * the fleet meant west, and one on heading 0 sited south instead of north, in the module that
   * hands out dock berths AND the direction a drone faces to reach them.
   *
   * The dead constants in the same file had the identical fault and were deleted for it. Deleting
   * the unused copy looked like finishing the job; the live one survived another day. That is the
   * whole reason this rule exists rather than a note in a comment.
   */
  it('heading 0 is north (-z) and heading 2 is south (+z)', () => {
    const offenders: string[] = [];
    for (const f of files) {
      if (f.startsWith('libs/')) continue;              // vendored: lama genuinely uses the other one
      const raw = read(f).split('\n');
      code(read(f)).forEach((l, i) => {
        // A branch on heading N that yields a z offset in the same statement.
        const m = /==\s*([0-3])\s*\)?\s*then.*z\s*=\s*(-?\d+)/.exec(l);
        if (!m) return;
        const heading = Number(m[1]);
        const z = Number(m[2]);
        const wrong = (heading === 0 && z > 0) || (heading === 2 && z < 0);
        if (wrong && !exempt(raw, i, 4)) {
          offenders.push(`${f}:${i + 1} heading ${heading} maps to z=${z} -- north is -z, south is +z`);
        }
      });
    }
    expect(offenders).toEqual([]);
  });
});

/**
 * ASSERTING A POSITION IS NOT THE SAME AS MOVING TO ONE.
 *
 * The heading audit works by comparing two records: the displacement the drone BELIEVES it made
 * since its last fix, and the displacement GPS says it actually made. Both are measured from an
 * anchor -- `m_FixAtX/Y/Z` -- and `resetAudit()` is the only thing that moves that anchor.
 *
 * So any function that teleports the cache without resetting the anchor leaves every later
 * comparison measured from a position the drone no longer claims. `setLocation` did exactly that,
 * and the mesh calls it every time a drone is out of GPS range with a trilaterated fix good to
 * about ten blocks.
 *
 * The damage was not the confusing log line, though there were hundreds of those
 * ("audit matched (-17,-5,1) yet the fix moved us 5 -- both cannot be right" -- both WERE right).
 * It was that the phantom drift trips "drift is too big for dead reckoning -- re-checking the
 * heading", which steps the turtle forward and back to re-derive a heading that was never wrong.
 * Out of range that ran continuously: fuel spent on probe moves provoked by our own bookkeeping,
 * on drones that were already too far out to afford them.
 *
 * `verifyPosition` had it right from the start -- it audits, writes, then resets. The rule exists
 * because three sibling functions wrote the same cache and only one of them remembered.
 */
describe('lua hygiene: a position assertion must re-anchor the audit', () => {
  it('every writer of the position cache resets the audit anchor', () => {
    const src = read('pgps.lua');
    const lines = src.split('\n');
    const raw = lines;

    // Walk the file tracking which top-level function each line belongs to.
    const offenders: string[] = [];
    let fnName: string | null = null;
    let fnStart = 0;
    const bodies = new Map<string, { start: number; lines: number[] }>();
    lines.forEach((l, i) => {
      const m = /^\s*(?:local\s+)?function\s+([A-Za-z_][\w.]*)/.exec(l);
      if (m) {
        fnName = m[1];
        fnStart = i;
        bodies.set(fnName, { start: fnStart, lines: [] });
      }
      if (fnName) bodies.get(fnName)!.lines.push(i);
    });

    for (const [name, body] of bodies) {
      const text = body.lines.map((i) => lines[i]).join('\n');
      const stripped = code(text).join('\n');
      // Does this function assign the position cache wholesale?
      if (!/cachedX\s*,\s*cachedY\s*,\s*cachedZ\s*=/.test(stripped)) continue;
      // Movement is exempt: it reports intent through notePlannedStep instead, which is what the
      // audit is measuring. Those are steps, not assertions.
      if (/notePlannedStep/.test(stripped)) continue;
      if (/resetAudit/.test(stripped)) continue;
      const at = body.lines.find((i) => /cachedX\s*,\s*cachedY\s*,\s*cachedZ\s*=/.test(lines[i]))!;
      if (exempt(raw, at, 6)) continue;
      offenders.push(
        `pgps.lua:${at + 1} ${name}() writes the position cache without resetAudit() -- ` +
          `the heading audit will measure from an anchor that is no longer where the drone claims to be`,
      );
    }
    expect(offenders).toEqual([]);
  });
});

/**
 * A MOVE PGPS DID NOT MAKE IS STILL A MOVE.
 *
 * Some callers genuinely have to drive the turtle directly -- the heading probe cannot use
 * pgps.forward(), because forward() applies the very heading being tested, and SurfaceForFix climbs
 * precisely when there is no fix, which is the one condition forward() refuses to move under.
 *
 * Going raw is fine. Staying SILENT about it is not. SurfaceForFix climbed up to RECOVERY_CLIMB
 * blocks with turtle.up() and told the position layer nothing, calling verifyPosition after each --
 * a call that fails every time, because no fix is exactly why the drone is climbing. The whole
 * ascent went unrecorded, and surfaced later as drift that the audit could not explain:
 *
 *   position corrected by 10: -493,84,76 -> -488,79,76
 *   audit matched (6,-3,0) yet the fix moved us 10 -- both cannot be right
 *
 * That phantom drift trips the heading re-check, so the climb meant to RECOVER a position was
 * manufacturing the evidence that the drone was lost. This was found on a build that had already
 * fixed three other writers of the same cache -- which is why it is a rule and not a note.
 */
describe('lua hygiene: raw turtle moves must be reported to pgps', () => {
  it('every direct turtle move outside pgps records the step', () => {
    const offenders: string[] = [];
    for (const f of files) {
      if (f === 'pgps.lua' || f.startsWith('libs/')) continue;   // pgps IS the position layer
      const raw = read(f).split('\n');
      const lines = code(read(f));
      lines.forEach((l, i) => {
        if (!/turtle\.(forward|back|up|down)\s*\(/.test(l)) return;
        if (exempt(raw, i, 6)) return;
        // The report may come a little after the move -- the caller usually checks the result and
        // measures something first -- so look ahead a short window for the acknowledgement.
        const after = lines.slice(i, i + 14).join('\n');
        // NOT verifyPosition. It only repairs the cache when it SUCCEEDS, and the case this rule
        // exists for -- SurfaceForFix climbing to regain a fix -- is precisely the case where it
        // fails on every pass. Accepting it here made the rule pass over the bug that motivated it.
        if (/noteExternalStep|notePlannedStep|setLocationFromGPS/.test(after)) return;
        offenders.push(
          `${f}:${i + 1} drives the turtle directly without telling pgps -- ` +
            `call pgps.noteExternalStep(dx,dy,dz), or justify it with a lua-hygiene: allow comment`,
        );
      });
    }
    expect(offenders).toEqual([]);
  });
});
