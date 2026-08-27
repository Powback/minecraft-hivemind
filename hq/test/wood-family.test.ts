/**
 * Any wood is wood.
 *
 * The recipe table names oak because a table needs a name; Minecraft does not care. Every log
 * species makes its own planks, and every planks species makes the same chest, stick and crafting
 * table. Hard-matching oak is how a fleet standing in a birch forest reports
 * "storage has none of the ingredients: minecraft:oak_log" and never builds anything.
 *
 * This mirrors SameItem/WoodFamily in DroneLogic, which is where the matching actually happens.
 */
import { describe, it, expect } from 'vitest';

const woodFamily = (n: string): string | null => {
  if (n.includes('_planks')) return 'planks';
  if (n.includes('_log') || n.includes('_wood')) return 'log';
  return null;
};
const sameItem = (want: string, have: string) => {
  if (want === have) return true;
  const a = woodFamily(want), b = woodFamily(have);
  return a !== null && a === b;
};

describe('wood family matching', () => {
  it('accepts any log where the recipe says oak_log', () => {
    for (const w of ['birch', 'spruce', 'jungle', 'acacia', 'dark_oak', 'mangrove', 'cherry']) {
      expect(sameItem('minecraft:oak_log', `minecraft:${w}_log`)).toBe(true);
    }
  });

  it('accepts any planks where the recipe says oak_planks', () => {
    expect(sameItem('minecraft:oak_planks', 'minecraft:birch_planks')).toBe(true);
  });

  it('does NOT confuse logs with planks -- they are different steps', () => {
    expect(sameItem('minecraft:oak_planks', 'minecraft:birch_log')).toBe(false);
    expect(sameItem('minecraft:oak_log', 'minecraft:oak_planks')).toBe(false);
  });

  it('leaves non-wood alone: coal is not a substitute for anything', () => {
    expect(sameItem('minecraft:coal', 'minecraft:charcoal')).toBe(false);
    expect(sameItem('minecraft:iron_ingot', 'minecraft:oak_log')).toBe(false);
  });

  it('still matches exact names, wood or not', () => {
    expect(sameItem('minecraft:coal', 'minecraft:coal')).toBe(true);
  });
});
