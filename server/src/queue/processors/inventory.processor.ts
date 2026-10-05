import { Inject, Injectable } from '@nestjs/common';
import { Processor, WorkerHost } from '@nestjs/bullmq';
import type { Job } from 'bullmq';
import type { Logger } from 'pino';
import { LOGGER } from '../../infra/logger.provider.js';
import {
  JOB_INVENTORY_CHECK,
  QUEUE_INVENTORY,
  type InventoryCheckJobPayload,
} from '../queue.constants.js';
import { TenantJobRunner } from '../tenant-job-runner.js';

@Injectable()
@Processor(QUEUE_INVENTORY)
export class InventoryProcessor extends WorkerHost {
  constructor(
    private readonly tenantJobRunner: TenantJobRunner,
    @Inject(LOGGER) private readonly logger: Logger,
  ) {
    super();
  }

  async process(job: Job<InventoryCheckJobPayload>): Promise<unknown> {
    const { name, data } = job;
    this.logger.info(
      { jobId: job.id, jobName: name, tenantId: data.tenantId, correlationId: data.correlationId },
      'Processing inventory job',
    );

    return this.tenantJobRunner.runWithTenantContext(job, async (em) => {
      if (name === JOB_INVENTORY_CHECK) {
        const productIds = data.productIds;
        let query = `
          SELECT id, part_no, name, stock, min_stock
            FROM products
           WHERE tenant_id = $1::uuid
             AND stock <= min_stock
             AND deleted_at IS NULL
        `;
        const params: unknown[] = [data.tenantId];

        if (productIds && productIds.length > 0) {
          query += ` AND id = ANY($2::uuid[])`;
          params.push(productIds);
        }

        const lowStock: Array<{
          id: string;
          part_no: string;
          name: string;
          stock: number;
          min_stock: number;
        }> = await em.query(query, params);

        this.logger.info(
          { tenantId: data.tenantId, lowStockFound: lowStock.length },
          'Inventory low-stock evaluation complete',
        );

        return {
          evaluated: true,
          lowStockCount: lowStock.length,
          items: lowStock.map((p) => ({ id: p.id, stock: p.stock, minStock: p.min_stock })),
        };
      }

      this.logger.warn({ jobName: name }, 'Unknown job name in inventory queue');
      return { skipped: true, reason: 'UNKNOWN_JOB_NAME' };
    });
  }
}
