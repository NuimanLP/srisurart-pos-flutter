import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    globals: true,
    root: './',
    include: ['**/*.e2e-spec.ts'],
    // One file at a time. Each e2e file boots the whole application, so parallel
    // files multiply the connection pools: seven files at `DB_POOL_SIZE` 20, plus an
    // admin pool each, blows past the compose Postgres's `max_connections=100` and
    // the run dies as "worker exited unexpectedly" rather than as a failed assertion.
    fileParallelism: false,
    // The sale-concurrency case fires 200 requests at once and is slow by design.
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
});
