import { createMigrationDataSource } from './data-source.js';

/**
 * Migration runner — the `migrate` compose job (runs once, before api-* start) and
 * the CI integration job both call this. Usage: node dist/db/migrate.js [up|down|status]
 *
 * DATABASE_URL must be the owner role (`postgres`), not `pos_app`.
 */
const command = process.argv[2] ?? 'up';
const url = process.env.DATABASE_URL;
if (!url) {
  console.error(
    'DATABASE_URL is required (owner role, e.g. postgres://postgres:…/pos)',
  );
  process.exit(2);
}

const ds = createMigrationDataSource(url);
try {
  await ds.initialize();
  if (command === 'up') {
    const ran = await ds.runMigrations({ transaction: 'each' });
    console.log(
      ran.length
        ? `applied: ${ran.map((m) => m.name).join(', ')}`
        : 'up to date',
    );
  } else if (command === 'down') {
    await ds.undoLastMigration({ transaction: 'each' });
    console.log('reverted one migration');
  } else if (command === 'status') {
    const pending = await ds.showMigrations();
    console.log(pending ? 'pending migrations exist' : 'up to date');
    process.exitCode = pending ? 1 : 0;
  } else {
    console.error(`unknown command "${command}" — use up | down | status`);
    process.exitCode = 2;
  }
} catch (err) {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
} finally {
  if (ds.isInitialized) await ds.destroy();
}
