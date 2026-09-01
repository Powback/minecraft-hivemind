/**
 * PRIORITY MEANS THE SAME THING AT BOTH ENDS, OR IT MEANS NOTHING.
 *
 * The convention is stated in TypeScript and acted on in Lua, and for a while the two disagreed:
 * `order.issue` documents "1 is highest -- issuing at 1 pushes existing work down", the supply
 * loop's comments say support work is "queued at priority 1, AHEAD of exploration", and TaskMan's
 * comparator sorted the other way up. So every priority anybody set did the exact opposite of what
 * it says on the tin, silently, with nothing anywhere to notice.
 *
 * It cost the settlement its critical path. The redstone shaft is created at priority 2 and the
 * wood gathers at 3, so the gathers won permanently: shaft-mine_head-01 sat "queued: no miner free"
 * through four working miners while redstone stayed at 0 -- and redstone is the one item gating
 * wired modems, therefore storage, therefore everything above it.
 *
 * This is the same shape as every other expensive bug here: ONE question, answered in two places,
 * with the copies free to drift. They cannot both be checked by a type, because one of them is a
 * sentence in a description string and the other is a comparison operator -- so they are pinned to
 * each other instead. Change either and this fails, which is the point: the failure asks you to go
 * and look at the other one.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const TASKMAN = path.resolve(__dirname, '../../lua/TaskMan.lua');
const CORE = path.resolve(__dirname, '../src/tools/core.ts');

const WHY = [
  'Priority is defined in one place and acted on in another, and they must agree.',
  '',
  '  hq/src/tools/core.ts  order.issue: "1 is highest"',
  '  lua/TaskMan.lua       orderedTasks: return pa < pb',
  '',
  'If you meant to flip the convention, flip BOTH and update this test. If you did not, one of',
  'them has drifted -- and the drift is invisible in production: work simply gets done in the',
  'wrong order for ever.',
].join('\n');

describe('priority means the same thing everywhere', () => {
  it('TaskMan dispatches the lowest priority number first', () => {
    const lua = readFileSync(TASKMAN, 'utf8');
    // The comparator itself, not a comment: comments are stripped of authority by being prose.
    const cmp = /if\s+pa\s*~=\s*pb\s+then\s+return\s+pa\s*([<>])\s*pb\s+end/.exec(
      lua.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n'),
    );
    expect(cmp, 'orderedTasks no longer compares pa and pb the way this test expects').not.toBeNull();
    expect(cmp![1], WHY).toBe('<');
  });

  it('the tool contract still says 1 is highest', () => {
    expect(readFileSync(CORE, 'utf8'), WHY).toContain('1 is highest');
  });

  it('an unset priority is least urgent, not most', () => {
    /**
     * The stored default is -1, chosen when the comparison ran the other way and -1 therefore meant
     * "last". Under lowest-first a raw -1 would leap to the FRONT of the queue -- every legacy task
     * in DATA jumping ahead of real work -- so priorityOf has to normalise it.
     */
    const lua = readFileSync(TASKMAN, 'utf8');
    expect(/function priorityOf\(/.test(lua), 'priorityOf is what normalises the old -1 default').toBe(true);
    const body = lua.slice(lua.indexOf('function priorityOf('));
    expect(body.slice(0, body.indexOf('\nend')), [
      'priorityOf must send an unset or negative priority to the BACK of the queue.',
      'The stored default is -1 and lowest-first would otherwise make that the most urgent task',
      'in the settlement.',
    ].join('\n')).toMatch(/n\s*<\s*1\s*then\s*return\s*9/);
  });
});
