import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const sh = readFileSync(join(__dirname, '../../bootstrap/redeploy.sh'), 'utf8');

/**
 * DEPLOYING TO THE MODULES IS NOT DEPLOYING.
 *
 * redeploy.sh shipped the seven module computers and not one drone, and had since it was written.
 * DroneLogic.lua is the file that changes most in this repo -- every job verb, movement, fuel,
 * deposit and rescue -- and it only ever reached a drone if something happened to reboot that drone
 * afterwards. Nothing in the deploy path did. Measured right after a "successful" redeploy:
 * seventeen of twenty drones on stale code.
 *
 * That is the most expensive class of failure there is, because every measurement taken to diagnose
 * it describes different code from the code in front of you -- hours went into "the fix does not
 * work" for fixes that were never running.
 */
describe('the deploy path reaches the drones', () => {
  it('ships drones as part of a full redeploy', () => {
    const all = sh.match(/^ALL=\(([^)]*)\)/m)?.[1] ?? '';
    expect(all).toMatch(/\bDrones\b/);
  });

  it('writes DroneLogic to every computer that has one', () => {
    expect(sh).toMatch(/deploy_drones\(\)/);
    expect(sh).toMatch(/\[ -f "\$d\/DroneLogic\.lua" \] \|\| continue/);
    expect(sh).toMatch(/cp "\$REPO\/lua\/DroneLogic\.lua"/);
  });

  /** Verify at the effect, never at the call -- a redeploy that silently skips one is the bug. */
  it('verifies afterwards and fails loudly on a stale drone', () => {
    expect(sh).toMatch(/cmp -s "\$REPO\/lua\/DroneLogic\.lua"/);
    expect(sh).toMatch(/STILL STALE after deploy/);
    const v = sh.slice(sh.indexOf('STILL STALE after deploy'));
    expect(v.slice(0, 200)).toMatch(/FAILED=1/);
  });

  /**
   * A DRONE'S BOOTLOADER IS A DIFFERENT PROGRAM FROM A MODULE'S.
   *
   * The first run of deploy_drones copied lua/startup -- the MODULE bootloader -- over every
   * drone's startup and bricked the whole fleet. That bootloader derives what to launch from the
   * computer label, so each drone came up trying to loadfile("D40.lua"), failed, and reboot-looped:
   * seven drones powered ON, executing nothing, every log frozen mid-sentence.
   *
   *   boot-stage.txt: stage=entered-startup label=D40
   *   last-run.txt:   module=D40 ok=false err=loadfile: File not found
   *
   * bootstrap/drone.sh was always the authority ("the drone's bootloader IS DroneBoot").
   */
  it('installs DroneBoot as the drone bootloader, never the module one', () => {
    const fn = sh.slice(sh.indexOf('deploy_drones()'), sh.indexOf('if [[ " ${TARGETS'));
    expect(fn).toMatch(/cp "\$REPO\/lua\/DroneBoot\.lua"\s+"\$d\/startup"/);
    expect(fn).not.toMatch(/cp "\$REPO\/lua\/startup"\s+"\$d\/startup"/);
  });
});
