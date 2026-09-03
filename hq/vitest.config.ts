import { defineConfig } from 'vitest/config';

/**
 * Which files are tests, stated once.
 *
 * The test script used to name its targets as bare filter strings -- `vitest run src/world test` --
 * and vitest treats those as SUBSTRINGS, not paths. So "test" matched src/tools/core.test.ts, which
 * is a standalone tsx script rather than a vitest suite, and dist/tools/core.test.js, which is the
 * compiled copy of the same thing. Both were reported as failing test files while every actual test
 * passed, which is the sort of noise that teaches people to ignore a red build.
 *
 * Worth saying what this exposed: test/ was not in the glob at all, so the suites living there had
 * never run. A test nobody runs is not a test.
 */
export default defineConfig({
  test: {
    include: ['src/world/**/*.test.ts', 'test/**/*.test.ts'],
    exclude: ['dist/**', 'node_modules/**'],
  },
});
