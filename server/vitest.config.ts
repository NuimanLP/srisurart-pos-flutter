import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';

export default defineConfig({
  // Resolves the path aliases declared in tsconfig.json, including the ones
  // added by `nest g library`.
  plugins: [tsconfigPaths()],
  test: {
    globals: true,
    root: './',
    include: ['**/*.spec.ts'],
    // Only read by `pnpm test:coverage` (CI job "unit"). The ratchet in
    // scripts/check-coverage.mjs compares coverage/coverage-summary.json's line % with
    // coverage-baseline.json — unit specs only; the e2e suites are not counted.
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.spec.ts'],
      reporter: ['text-summary', 'json-summary'],
      reportsDirectory: './coverage',
    },
  },
});
