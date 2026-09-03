import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const supply = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');
const core = readFileSync(join(__dirname, '../src/tools/core.ts'), 'utf8');
const taskman = readFileSync(join(__dirname, '../../lua/TaskMan.lua'), 'utf8');

/**
 * CLEARING A CLASS OF WORK MUST NOT GO THROUGH A WINDOW.
 *
 * stopTasksNamed read fleet.tasks, filtered by name, and sent the ids to task.stop. Every layer of
 * that has a cap in it, and none of them is visible to the caller:
 *
 *   TaskMan GetTasks   40 tasks   -- to fit the 61,440-byte websocket frame
 *   fleet.tasks        60 live    -- same reason, one layer up
 *   task.stop          32 ids     -- schema `.max(32)`
 *
 * Measured: 131 `tower-L0` patches in TaskMan's own store, 37 of them visible through fleet.tasks.
 * The loop stopped what it could see and reported success, so a finished floor's leftovers could
 * never be cleared -- and clearing them is the only thing that lets the next floor be ordered. The
 * tower sat at level 0 behind 131 dead patches while every log line said the clear had worked.
 *
 * Three caps, none wrong on its own, and a caller that could not see any of them. The fix is not a
 * bigger window: the question "which tasks are named like this" belongs to the module holding the
 * tasks.
 */
describe('clearing a floor happens where the tasks are', () => {
  const fn = (() => {
    const i = supply.indexOf('async function stopTasksNamed');
    if (i < 0) throw new Error('stopTasksNamed is gone -- move this assertion, do not delete it');
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  })();
  /** CODE ONLY -- the comment above the function quotes the banned approach to record its cost. */
  const code = fn.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');

  it('asks TaskMan to do it, rather than enumerating ids out here', () => {
    expect(code).toMatch(/task\.stopNamed/);
    expect(code).not.toMatch(/fleet\.tasks/);   // the 40/60-task window
    expect(code).not.toMatch(/'task\.stop'/);   // the 32-id window
  });

  it('reports a clear that matched nothing rather than returning a bare zero', () => {
    expect(code).toMatch(/nothing matched among/);
    expect(code).toMatch(/could not clear/);
  });

  /**
   * The endpoint must count what it MARKED, not what it was asked to mark -- the distinction that
   * makes this different from the thing it replaced.
   */
  it('TaskMan counts the tasks it actually stopped', () => {
    const i = taskman.indexOf('local function OnStopNamed');
    if (i < 0) throw new Error('OnStopNamed is gone -- move this assertion, do not delete it');
    const lua = taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
    expect(lua).toMatch(/s_Stopped = s_Stopped \+ 1/);
    expect(lua).toMatch(/stopped = s_Stopped/);
    // an empty prefix matches the whole queue, and a dropped field is how one gets here
    expect(lua).toMatch(/refusing to match the whole queue/);
    // CC kills a coroutine that runs 10s without yielding, and this walks the entire queue
    expect(lua).toMatch(/os\.queueEvent\("stopNamed"\) os\.pullEvent\("stopNamed"\)/);
  });

  /**
   * PowNet silently drops any field the endpoint does not declare, and the call still succeeds --
   * which here would mean an empty prefix and a refusal on every call, for ever.
   */
  it('declares its params, or they never arrive', () => {
    const i = taskman.indexOf('StopNamed = {');
    if (i < 0) throw new Error('StopNamed is not registered -- move this assertion, do not delete it');
    const decl = taskman.slice(i, i + 600);
    expect(decl).toMatch(/prefix = \{ optional = false/);
    expect(decl).toMatch(/reason = \{ optional = true/);
  });

  /**
   * Cancelling a task in the queue does not reach the machine. An unstopped drone keeps executing,
   * never goes idle, and can never be given work again -- indistinguishable from a dead fleet.
   * task.stop knew this and looked the holder up through GetTasks, which is itself capped at 40, so
   * for most tasks it found nobody and still reported success. Both paths now carry the holder out
   * of TaskMan instead of searching for it.
   */
  it('releases the drones that were holding the tasks', () => {
    const i = core.indexOf("name: 'task.stopNamed'");
    if (i < 0) throw new Error('task.stopNamed is gone -- move this assertion, do not delete it');
    const tool = core.slice(i, core.indexOf('\n});', i));
    expect(tool).toMatch(/'DroneMan', 'Stop'/);
    expect(tool).toMatch(/verify-at-effect:/);
    expect(taskman).toMatch(/abandoned = true, heldBy = s_Held/);
  });
});

/**
 * ABSENT FROM A CAPPED LIST IS NOT GONE.
 *
 * confirmStopped is task.stop's verify-at-effect step: it re-reads the queue and sets `stopped` from
 * whether the task is really gone. It read GetTasks, which returns AT MOST 40 TASKS -- so "not in
 * the reply" meant either "stopped" or "outside the window", and with a full queue the second is by
 * far the more likely. The verifier written to catch false successes was manufacturing them.
 *
 * A sample cannot prove a negative. At the cap it must say "unverified" rather than "stopped".
 */
describe('the stop verifier does not read a sample as proof', () => {
  const fn = (() => {
    const i = core.indexOf('async function confirmStopped');
    if (i < 0) throw new Error('confirmStopped is gone -- move this assertion, do not delete it');
    return core.slice(i, core.indexOf('\n}\n', i) + 3);
  })();

  it('treats a full page as unverifiable rather than as success', () => {
    expect(fn).toMatch(/list\.length >= 40/);
    expect(fn).toMatch(/row\.verified = false/);
    // the unconditional "absent means stopped" is what created the false success
    const code = fn.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    expect(code).not.toMatch(/row\.stopped = !live\.has/);
  });

  /** A task seen still live is a definite failure, and must stay reportable in both cases. */
  it('still reports a task it can see is not stopped', () => {
    expect(fn).toMatch(/if \(seen\) row\.stopped = false/);
  });

  /**
   * task.stop found the holding drone by searching that same 40-task window, so for most tasks it
   * released nobody and still answered `stopped: true` -- leaving a drone running a cancelled task
   * for ever. TaskMan reports the holder from the assignment it clears instead.
   */
  it('takes the holder from TaskMan rather than searching for it', () => {
    const i = core.indexOf("name: 'task.stop'");
    const tool = core.slice(i, core.indexOf('\n});', i));
    const code = tool.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    expect(code).toMatch(/numField\(res, 'heldBy'\)/);
    expect(code).not.toMatch(/list\.find\(\(t: any\) => String\(t\.id\) === String\(id\)\)/);
  });
});
