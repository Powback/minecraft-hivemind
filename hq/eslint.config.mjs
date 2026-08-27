// COMPLEXITY ONLY. This config deliberately enables exactly one rule.
//
// It is not here for style -- formatting arguments are not worth a toolchain. It is here because
// the functions that have failed in production here are, without exception, the biggest ones:
// `rescueNeeded` (CC 83) is what sent healthy drones to rescue each other, and `DepositNow` (CC 59)
// is what looped for four hours holding 515 items without ever saying why. Branch count is the
// closest thing to a measurable predictor of "nobody can hold this in their head", which is the
// actual defect.
//
// The Lua half of the fleet is checked by `npm run lint:lua` (luacheck W561) against the same
// threshold, with the same ratchet. See test/complexity.test.ts.
import tseslint from 'typescript-eslint';

export const MAX_COMPLEXITY = 15;

export default tseslint.config(
  {
    ignores: ['dist/**', 'node_modules/**', 'public/**', '**/*.test.ts'],
  },
  {
    files: ['src/**/*.ts'],
    languageOptions: { parser: tseslint.parser },
    rules: {
      complexity: ['error', { max: MAX_COMPLEXITY }],
    },
  },
);
