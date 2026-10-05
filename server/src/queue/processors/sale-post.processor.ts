import { Inject, Injectable, Optional } from '@nestjs/common';
import { InjectQueue, Processor, WorkerHost } from '@nestjs/bullmq';
import { type Job, Queue } from 'bullmq';
import type { Logger } from 'pino';
import { LOGGER } from '../../infra/logger.provider.js';
import {
  JOB_INVENTORY_CHECK,
  JOB_RETURN_CREATED,
  JOB_SALE_CREATED,
  QUEUE_INVENTORY,
  QUEUE_SALE_POST,
  type ReturnCreatedJobPayload,
  type SaleCreatedJobPayload,
} from '../queue.constants.js';
import { TenantJobRunner } from '../tenant-job-runner.js';

@Injectable()
@Processor(QUEUE_SALE_POST)
export class SalePostProcessor extends WorkerHost {
  constructor(
    private readonly tenantJobRunner: TenantJobRunner,
    @Inject(LOGGER) private readonly logger: Logger,
    @Optional() @InjectQueue(QUEUE_INVENTORY) private readonly inventoryQueue?: Queue,
  ) {
    super();
  }

  async process(job: Job<SaleCreatedJobPayload | ReturnCreatedJobPayload>): Promise<unknown> {
    const { name, data } = job;
    this.logger.info(
      { jobId: job.id, jobName: name, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing sale-post job',
    );

    return this.tenantJobRunner.runWithTenantContext(job, async (em) => {
      if (name === JOB_SALE_CREATED || name === JOB_RETURN_CREATED) {
        const payload = data;
        const productIds = payload.productIds ?? [];

        if (productIds.length > 0 && this.inventoryQueue) {
          // Check if any product is now at or below minimum stock
          const lowStockProducts: Array<{ id: string; stock: number; min_stock: number }> =
            await em.query(
              `SELECT id, stock, min_stock
                 FROM products
                WHERE tenant_id = $1::uuid
                  AND id = ANY($2::uuid[])
                  AND stock <= min_stock
                  AND deleted_at IS NULL`,
              [payload.tenantId, productIds],
            );

          if (lowStockProducts.length > 0) {
            this.logger.warn(
              {
                tenantId: payload.tenantId,
                lowStockCount: lowStockProducts.length,
                products: lowStockProducts.map((p) => p.id),
              },
              'Low stock detected during sale-post processing; enqueuing inventory check',
            );

            await this.inventoryQueue.add(
              JOB_INVENTORY_CHECK,
              {
                tenantId: payload.tenantId,
                correlationId: payload.correlationId,
                productIds: lowStockProducts.map((p) => p.id),
              },
              {
                // De-duplicate inventory checks for the same tenant
                jobId: `inv-check:${payload.tenantId}:${lowStockProducts.map((p) => p.id).sort().join(',')}`,
              },
            );
          }
        }

        return {
          processed: true,
          jobName: name,
          itemCount: productIds.length,
        };
      }

      this.logger.warn({ jobName: name }, 'Unknown job name in sale-post queue');
      return { skipped: true, reason: 'UNKNOWN_JOB_NAME' };
    });
  }
}
