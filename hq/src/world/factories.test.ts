import { describe, it, expect } from 'vitest';
import { chain, unmetInputs, buildOrder, inputsOf, type Factory } from './factories.js';

const f = (name: string, produces: string): Factory =>
  ({ name, produces, plot: `${name}-plot`, status: 'planned' });

describe('factory chaining', () => {
  it('derives links from the recipe graph rather than configuration', () => {
    // Nobody says "planks feed the chest line". The recipes already say it.
    const plant = [f('planks-1', 'minecraft:oak_planks'), f('chests-1', 'minecraft:chest')];
    expect(chain(plant)).toEqual([
      { from: 'planks-1', to: 'chests-1', item: 'minecraft:oak_planks' },
    ]);
  });

  it('rewires automatically when a factory is added', () => {
    const before = [f('computers-1', 'computercraft:computer_normal')];
    expect(chain(before)).toEqual([]);
    const after = [...before, f('stone-1', 'minecraft:stone')];
    expect(chain(after)).toContainEqual(
      { from: 'stone-1', to: 'computers-1', item: 'minecraft:stone' });
  });

  it('never links a factory to itself', () => {
    // A loop in a routing table moves items back and forth for ever while looking busy.
    const plant = [f('stone-1', 'minecraft:stone'), f('stone-2', 'minecraft:stone')];
    expect(chain(plant).every((l) => l.from !== l.to)).toBe(true);
  });

  it('names the inputs nothing in the plant produces — the real boundary', () => {
    const plant = [f('turtles-1', 'computercraft:turtle_normal')];
    const unmet = unmetInputs(plant);
    const items = unmet.map((u) => u.item);
    expect(items).toContain('minecraft:iron_ingot');
    expect(items).toContain('computercraft:computer_normal');
    // And it says HOW each would have to arrive, which is the actionable part.
    expect(unmet.every((u) => typeof u.source === 'string' && u.source.length > 0)).toBe(true);
  });

  it('closes the boundary as upstream factories are added', () => {
    const plant = [
      f('turtles-1', 'computercraft:turtle_normal'),
      f('computers-1', 'computercraft:computer_normal'),
    ];
    const items = unmetInputs(plant).map((u) => u.item);
    expect(items).not.toContain('computercraft:computer_normal');
  });

  it('orders construction so nothing is built before what feeds it', () => {
    const plant = [
      f('turtles-1', 'computercraft:turtle_normal'),
      f('computers-1', 'computercraft:computer_normal'),
      f('stone-1', 'minecraft:stone'),
    ];
    const { order, cycles } = buildOrder(plant);
    expect(cycles).toEqual([]);
    expect(order.indexOf('stone-1')).toBeLessThan(order.indexOf('computers-1'));
    expect(order.indexOf('computers-1')).toBeLessThan(order.indexOf('turtles-1'));
  });

  it('reads a factory’s inputs straight off its recipe', () => {
    expect(inputsOf('computercraft:turtle_normal').sort()).toEqual([
      'computercraft:computer_normal', 'minecraft:chest', 'minecraft:iron_ingot',
    ]);
  });
});
