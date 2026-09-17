import { Injectable, NotFoundException } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { TenantService } from '../common/database/tenant.service.js';
import { newId } from '../common/ids.js';
import { Paginated } from '../common/paginated.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import {
  type ReviewItem,
  type ReviewItemKind,
  type ReviewItemStatus,
} from './review-items.dto.js';

interface ReviewItemRow {
  id: string;
  kind: ReviewItemKind;
  ref_id: string;
  details: Record<string, unknown>;
  created_at: Date | string;
  reviewed_at: Date | string | null;
  reviewed_by: string | null;
}

const REVIEW_ITEM_COLUMNS =
  'id, kind, ref_id, details, created_at, reviewed_at, reviewed_by';

function toReviewItem(row: ReviewItemRow): ReviewItem {
  return {
    id: row.id,
    kind: row.kind,
    refId: row.ref_id,
    details:
      typeof row.details === 'object' && row.details !== null
        ? row.details
        : {},
    createdAt:
      row.created_at instanceof Date
        ? row.created_at.toISOString()
        : String(row.created_at),
    reviewedAt: row.reviewed_at
      ? row.reviewed_at instanceof Date
        ? row.reviewed_at.toISOString()
        : String(row.reviewed_at)
      : null,
    reviewedBy: row.reviewed_by ?? null,
  };
}

export interface ReviewActor {
  userId: string;
  ip?: string;
}

export interface CreateReviewItemInput {
  id?: string;
  kind: ReviewItemKind;
  refId: string;
  details?: Record<string, unknown>;
}

@Injectable()
export class ReviewItemsService {
  constructor(
    private readonly tenants: TenantService,
    private readonly audit: AuditService,
  ) {}

  list(
    status: ReviewItemStatus,
    page: number,
    limit: number,
  ): Promise<Paginated<ReviewItem>> {
    return this.tenants.runTx(() => this.listIn(status, page, limit));
  }

  private async listIn(
    status: ReviewItemStatus,
    page: number,
    limit: number,
  ): Promise<Paginated<ReviewItem>> {
    const { tenantId, manager } = currentRequestContext();
    const where: string[] = ['tenant_id = $1::uuid'];
    const params: unknown[] = [tenantId];

    if (status === 'pending') {
      where.push('reviewed_at IS NULL');
    } else if (status === 'reviewed') {
      where.push('reviewed_at IS NOT NULL');
    }

    const clause = where.join(' AND ');

    const countRows = (await manager.query(
      `SELECT count(*)::int AS total FROM owner_review_items WHERE ${clause}`,
      params,
    )) as { total: number }[];
    const total = countRows[0]?.total ?? 0;

    const offset = (page - 1) * limit;
    params.push(limit, offset);

    const rows = (await manager.query(
      `SELECT ${REVIEW_ITEM_COLUMNS}
         FROM owner_review_items
        WHERE ${clause}
        ORDER BY created_at DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    )) as ReviewItemRow[];

    return new Paginated(rows.map(toReviewItem), { total, page, limit });
  }

  markReviewed(id: string, actor: ReviewActor): Promise<ReviewItem> {
    return this.tenants.runTx(() => this.markReviewedIn(id, actor));
  }

  private async markReviewedIn(
    id: string,
    actor: ReviewActor,
  ): Promise<ReviewItem> {
    const { tenantId, manager } = currentRequestContext();

    const rows = (await manager.query(
      `SELECT ${REVIEW_ITEM_COLUMNS}
         FROM owner_review_items
        WHERE tenant_id = $1::uuid AND id = $2
        FOR UPDATE`,
      [tenantId, id],
    )) as ReviewItemRow[];

    if (rows.length === 0) {
      throw new NotFoundException('Review item not found');
    }

    const existing = rows[0];
    if (existing.reviewed_at !== null) {
      // Already reviewed — idempotent return
      return toReviewItem(existing);
    }

    const updated = returning<ReviewItemRow>(
      await manager.query(
        `UPDATE owner_review_items
            SET reviewed_at = now(),
                reviewed_by = $3::uuid
          WHERE tenant_id = $1::uuid AND id = $2
          RETURNING ${REVIEW_ITEM_COLUMNS}`,
        [tenantId, id, actor.userId],
      ),
    );

    const result = toReviewItem(updated[0]);

    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      action: 'review_item.reviewed',
      entity: 'owner_review_items',
      entityId: id,
      before: { reviewedAt: null, reviewedBy: null },
      after: { reviewedAt: result.reviewedAt, reviewedBy: result.reviewedBy },
      ip: actor.ip,
    });

    return result;
  }

  createItem(input: CreateReviewItemInput): Promise<ReviewItem> {
    return this.tenants.runTx(() => this.createItemIn(input));
  }

  private async createItemIn(
    input: CreateReviewItemInput,
  ): Promise<ReviewItem> {
    const { tenantId, manager } = currentRequestContext();
    return ReviewItemsService.insertIn(manager, tenantId, input);
  }

  /**
   * Helper for other services executing within an existing transaction.
   */
  static async insertIn(
    manager: EntityManager,
    tenantId: string,
    input: CreateReviewItemInput,
  ): Promise<ReviewItem> {
    const id = input.id ?? newId('rev_');
    const rows = returning<ReviewItemRow>(
      await manager.query(
        `INSERT INTO owner_review_items (tenant_id, id, kind, ref_id, details)
         VALUES ($1::uuid, $2, $3, $4, $5::jsonb)
         RETURNING ${REVIEW_ITEM_COLUMNS}`,
        [
          tenantId,
          id,
          input.kind,
          input.refId,
          JSON.stringify(input.details ?? {}),
        ],
      ),
    );

    return toReviewItem(rows[0]);
  }
}
