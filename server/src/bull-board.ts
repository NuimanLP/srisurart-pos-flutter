import { timingSafeEqual } from 'node:crypto';
import { createBullBoard } from '@bull-board/api';
import { ExpressAdapter } from '@bull-board/express';
import express, {
  type NextFunction,
  type Request,
  type Response,
} from 'express';
import { createLogger } from './common/logger.js';

function requiredEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required environment variable ${name}`);
  return v;
}
const user = requiredEnv('BULL_BOARD_USER');
const password = requiredEnv('BULL_BOARD_PASSWORD');
const port = Number(process.env.PORT ?? 3100);
const logger = createLogger({
  level: process.env.LOG_LEVEL ?? 'info',
  instanceId: 'bull-board',
});

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** Basic auth: job payloads carry tenantId + customer data (PDPA). */
function basicAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? '';
  const [scheme, encoded] = header.split(' ');
  if (scheme === 'Basic' && encoded) {
    const [u, ...rest] = Buffer.from(encoded, 'base64').toString().split(':');
    if (safeEqual(u, user) && safeEqual(rest.join(':'), password))
      return next();
  }
  res
    .set('WWW-Authenticate', 'Basic realm="bull-board"')
    .status(401)
    .send('Unauthorized');
}

const serverAdapter = new ExpressAdapter();
serverAdapter.setBasePath('/');
// Queues are registered by #34 (BullMQAdapter per queue on redis-queue).
createBullBoard({ queues: [], serverAdapter });

const app = express();
app.use(basicAuth);
app.use('/', serverAdapter.getRouter());

const server = app.listen(port, '0.0.0.0', () =>
  logger.info({ port }, 'bull-board listening'),
);
for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
