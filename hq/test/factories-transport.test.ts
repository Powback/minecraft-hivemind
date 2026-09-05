import { describe, it, expect } from 'vitest';
import { transportFor, type Factory, type Link } from '../src/world/factories.js';

const mk = (name: string, over: Partial<Factory> = {}): Factory =>
  ({ name, produces: 'x', plot: 'p', status: 'planned', ...over });

const link: Link = { from: 'A', to: 'B', item: 'minecraft:stone' };

describe('transport is pipes-first, droids-when-not', () => {
  it('hauls while either end is not yet wired -- during the build, and before the fleet can commission wiring', () => {
    expect(transportFor(link, [mk('A'), mk('B')])).toBe('haul');                       // neither end wired
    expect(transportFor(link, [mk('A', { output: 'chest_0' }), mk('B')])).toBe('haul'); // only producer wired
    expect(transportFor(link, [mk('A'), mk('B', { input: 'chest_1' })])).toBe('haul');  // only consumer wired
  });

  it('upgrades to a wired route the moment both ends are on the network', () => {
    expect(transportFor(link, [mk('A', { output: 'chest_0' }), mk('B', { input: 'chest_1' })])).toBe('route');
  });
});
