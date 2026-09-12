import type { JobsOptions } from 'bullmq';

export const QUEUE_SALE_POST = 'sale-post';
export const QUEUE_INVENTORY = 'inventory';
export const QUEUE_MAINTENANCE = 'maintenance';
export const QUEUE_BACKUP = 'backup';
export const QUEUE_DLQ = 'dlq';

export const ALL_QUEUES = [
  QUEUE_SALE_POST,
  QUEUE_INVENTORY,
  QUEUE_MAINTENANCE,
  QUEUE_BACKUP,
  QUEUE_DLQ,
] as const;

export type QueueName = (typeof ALL_QUEUES)[number];

export interface BaseJobPayload {
  tenantId: string;
  correlationId: string;
  [key: string]: unknown;
}

export const DEFAULT_JOB_OPTIONS: JobsOptions = {
  attempts: 3,
  backoff: {
    type: 'exponential-jitter',
    delay: 1000,
  },
  removeOnComplete: {
    age: 3600, // keep for 1 hour
    count: 1000, // keep max 1000 jobs
  },
  removeOnFail: false, // keep failed jobs as evidence (Backend05 reliability)
};
