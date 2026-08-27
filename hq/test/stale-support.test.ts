/**
 * A SUPPORT TASK OUTLIVES THE REASON IT EXISTED.
 *
 * scoutForMiners creates support-X only for a miner that is WORKING at that moment -- correct at
 * creation, and nothing ever retired them.
 *
 * Found live: all three open support tasks pointed at drones that were lost or idle. They sit at
 * priority 1, AHEAD of exploration, and the settlement has exactly two scouts (role is hardware --
 * a geo scanner -- so no miner can be promoted to cover), one of which was dry. The single working
 * scout was therefore aimed at priority-1 work supporting drones that had stopped digging, while
 * eleven scout tasks queued up behind it. From outside that reads as "the scouts aren't helping".
 */
import { describe, it, expect } from 'vitest';
import { staleSupportTasks } from '../src/agent/supply.js';

const drones = [
  { name: 'D5', status: 'working' },
  { name: 'D3', status: 'lost' },
  { name: 'D14', status: 'idle' },
];

describe('support tasks retire with their target', () => {
  it('keeps support for a miner that is still working', () => {
    expect(staleSupportTasks([{ id: 1, name: 'support-D5' }], drones)).toEqual([]);
  });

  it('retires support for a lost or idle target -- the exact live case', () => {
    expect(staleSupportTasks(
      [{ id: 1, name: 'support-D3' }, { id: 2, name: 'support-D14' }], drones,
    )).toEqual([1, 2]);
  });

  it('retires support for a drone that is gone from the fleet entirely', () => {
    expect(staleSupportTasks([{ id: 9, name: 'support-D99' }], drones)).toEqual([9]);
  });

  it('never touches anything that is not a support task', () => {
    const other = [
      { id: 1, name: 'tower-L0-p01' }, { id: 2, name: 'gather:coal_ore' },
      { id: 3, name: 'rescue-D7' }, { id: 4, name: 'fuel-D4' },
    ];
    expect(staleSupportTasks(other, drones)).toEqual([]);
  });

  it('leaves finished tasks alone -- they are already done, not stale', () => {
    expect(staleSupportTasks([{ id: 1, name: 'support-D3', progress: 100 }], drones)).toEqual([]);
  });

  it('survives empty and missing inputs', () => {
    expect(staleSupportTasks([], [])).toEqual([]);
    expect(staleSupportTasks(null as any, null as any)).toEqual([]);
  });
});
