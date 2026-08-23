/**
 * The three shapes a Lua collection arrives in, and the one shape that is not a collection at all.
 *
 * The empty case is the whole reason this exists: an empty Lua table serialises to {}, an
 * Array.isArray check called that unreadable, and the supply loop refuses to dispatch when it cannot
 * read the queue -- so on a fresh world the queue stayed empty because it was empty. A cold start
 * could never begin, and nothing in the system reported a fault.
 */

import { describe, it, expect } from 'vitest';
import { luaList, isLuaList } from '../src/lua-table.js';

describe('luaList', () => {
  it('reads a dense list, the easy case', () => {
    expect(luaList([{ id: 1 }, { id: 2 }])).toEqual([{ id: 1 }, { id: 2 }]);
  });

  it('reads a sparse table, which JSON makes an object', () => {
    expect(luaList({ '1': { id: 1 }, '7': { id: 7 } })).toEqual([{ id: 1 }, { id: 7 }]);
  });

  it('reads an EMPTY table as empty, not as unreadable', () => {
    // The bug. {} is a perfectly good answer meaning "no tasks", and treating it as a failure to
    // read deadlocked the whole cold start.
    expect(luaList({})).toEqual([]);
    expect(isLuaList({})).toBe(true);
  });

  it('refuses a PowNet error string, which arrives in the same field as a success', () => {
    expect(luaList('no such endpoint: GetTasks')).toBeNull();
    expect(isLuaList('no such endpoint: GetTasks')).toBe(false);
  });

  it('refuses absence', () => {
    expect(luaList(undefined)).toBeNull();
    expect(luaList(null)).toBeNull();
  });

  it('refuses a number, which is nonsense rather than an empty collection', () => {
    expect(luaList(0)).toBeNull();
  });

  it('keeps empty and unreadable distinguishable, which is the point', () => {
    const empty = luaList({});
    const broken = luaList('TaskMan is not answering');
    expect(empty).not.toBeNull();
    expect(broken).toBeNull();
    expect(empty).toHaveLength(0);
  });
});
