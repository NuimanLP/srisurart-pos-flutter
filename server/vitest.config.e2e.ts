import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    globals: true,
    root: './',
    include: ['**/*.e2e-spec.ts'],
    // #141: one run per Postgres. Takes a session advisory lock before any file starts
    // and refuses to start, naming the holder, if another `pnpm test:e2e` has it.
    // #160: warns when this Node has the Windows libuv bug that kills a worker at random.
    globalSetup: ['./test/support/windows-node-check.ts', './test/support/e2e-runner-lock.ts'],
    // One file at a time. Each e2e file boots the whole application, so parallel
    // files multiply the connection pools: seven files at `DB_POOL_SIZE` 20, plus an
    // admin pool each, blows past the compose Postgres's `max_connections=100` and
    // the run dies as "worker exited unexpectedly" rather than as a failed assertion.
    fileParallelism: false,
    // The sale-concurrency case fires 200 requests at once and is slow by design.
    testTimeout: 60_000,
    // #410: the suites boot against the compose datastores with .env.example's public
    // `dev-only-*` passwords (config.ts falls back to `dev-only-postgres` for the admin URL),
    // which loadConfig refuses unless this is set. Every loadConfig call here spreads process.env.
    env: { ALLOW_DEV_SECRETS: 'true' },
    hookTimeout: 60_000,
  },
});
