/**
 * YOU MAY NOT KEEP WORK YOU COULD NOT BE GIVEN.
 *
 * TaskMan has two rules about a drone and a task, and they were written years apart by the same
 * reasoning applied to opposite ends:
 *
 *   pickDrone                 may this drone be GIVEN work?   hasFuel(d)
 *   releaseStalledAssignments may this drone KEEP work?       d.status == "idle"
 *
 * They have to be the same question. When they are not, there is a band of drones that can be given
 * nothing and are allowed to hold everything, and a task that falls into that band never comes back.
 *
 * It cost the settlement a total stop. D37 ran dry holding lumber:oak_log -- the only renewable
 * fuel there is -- and stranded. Storage was at 0 coal, 0 charcoal, 0 logs, so nothing could refuel
 * it. The task stayed "running", so nobody else could take it. D4 and D31 sat idle with 6,064 fuel
 * between them, which is several trees' worth. The fleet had everything it needed to end its own
 * fuel emergency and could not reach the job, and "idle" could never have caught it, because a
 * stranded drone does not report idle -- it reports stranded.
 *
 * This is the same shape as the priority convention and the three definitions of "what counts as
 * fuel": ONE question with an answer in two places, free to drift, and silent when it does. So the
 * two are pinned to each other. If you change how dispatch decides, this fails and asks you to go
 * and look at how holding decides.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const TASKMAN = path.resolve(__dirname, '../../lua/TaskMan.lua');
const CODE = readFileSync(TASKMAN, 'utf8');

/** The file with comments stripped: a rule stated only in prose is not a rule. */
const BARE = CODE.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n');

function body(name: string): string {
  const at = BARE.indexOf(`local function ${name}(`);
  expect(at, `${name} must exist in TaskMan.lua`).toBeGreaterThan(-1);
  const rest = BARE.slice(at);
  return rest.slice(0, rest.indexOf('\nend'));
}

describe('holding work and being given work ask the same question', () => {
  it('the release test consults fuel, not only the reported status', () => {
    expect(body('heldForNothing'), [
      'heldForNothing decides whether a task should be taken back from its holder.',
      'It must consider FUEL and not only d.status, because a drone that has run dry does not',
      'report "idle" -- it reports "stranded" -- and so it kept the settlement\'s only',
      'fuel-producing task while two fuelled drones sat idle.',
    ].join('\n')).toMatch(/hasFuel\(/);
  });

  it('it uses the dispatch predicate itself rather than its own copy of the number', () => {
    // Two numbers for one idea is how they drift apart -- the same reason DISPATCH_FUEL_FLOOR and
    // DroneLogic's FUEL_RESERVE were collapsed into one value after D9 sat idle at 560 fuel.
    expect(body('heldForNothing'), 'compare via hasFuel, do not re-derive DISPATCH_FUEL_FLOOR here')
      .not.toMatch(/DISPATCH_FUEL_FLOOR/);
  });

  it('releaseStalledAssignments actually gates on it', () => {
    // A predicate that is computed and not used is the bug this whole file exists to catch: the
    // priority comparator, the scarcity flag, and OnDepositPoints all failed exactly that way.
    expect(body('releaseStalledAssignments'), 'the release pass must gate on heldForNothing')
      .toMatch(/heldForNothing\(/);
  });

  it('a released task is requeued, not aborted', () => {
    /**
     * Releasing and aborting are different acts and the difference matters to a dry drone.
     * freeOrphanedDrones deliberately leaves drones below the floor alone, because aborting them
     * clears the distress that marks them for rescue -- D2 was aborted once a minute and flipped
     * between "stuck" and "idle" until the rescue bookkeeping gave up.
     *
     * This pass touches the QUEUE, not the drone: it clears the assignment so somebody who can do
     * the work gets offered it, and the stranded drone keeps its job, its distress and its place in
     * the rescue queue.
     */
    expect(body('releaseStalledAssignments'), 'clear the assignment')
      .toMatch(/v\.assignedTo\s*=\s*nil/);
    expect(body('releaseStalledAssignments'), [
      'Do not abort the holder here. Aborting a dry drone clears the distress that gets it',
      'rescued; this pass is about handing the WORK to someone who can do it.',
    ].join('\n')).not.toMatch(/abortAssigned/);
  });
});
