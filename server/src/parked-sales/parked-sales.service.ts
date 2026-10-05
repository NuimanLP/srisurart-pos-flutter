import {
  BadRequestException,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { newUuid } from '../common/ids.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';

/** A parked bill on the wire. */
export interface ParkedSale {
  id: string;
  parkedAt: string;
  /** The `pos` device that parked it. Recorded, not filtered on — see `list`. */
  deviceId: string | null;
  /** The cart snapshot exactly as the client sent it (`{ items, customerId, mechanicId, discount, … }`). */
  payload: Record<string, unknown>;
}

interface ParkedRow {
  id: string;
  parked_at: Date;
  device_id: string | null;
  payload: Record<string, unknown>;
}

const COLUMNS = 'id, parked_at, device_id, payload';

/**
 * Parked bills (#27), ported from `parked_repository.dart`. A cart snapshot and
 * nothing more: **no method here reads or writes `products`**. Stock is re-checked
 * when the cart is sold, by the sale path — the Dart reference keeps its resume-time
 * re-validation in Checkout, not in the repository, for the same reason.
 */
@Injectable()
export class ParkedSalesService {
  constructor(private readonly tenants: TenantService) {}

  /**
   * Every parked bill of the tenant, newest first (`getParked`). Not filtered by
   * device: the Dart app has one machine, and ADR-0004 allows one active `pos` per
   * tenant, so the only other device a cart could belong to is a retired one.
   */
  list(): Promise<ParkedSale[]> {
    return this.tenants.runTx(() => this.listIn());
  }

  private async listIn(): Promise<ParkedSale[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM parked_sales WHERE tenant_id = $1::uuid
        ORDER BY parked_at DESC, id DESC`,
      [tenantId],
    )) as ParkedRow[];
    return rows.map(toParked);
  }

  /** `parkSale`: a fresh `pk` id and `parkedAt = now`. */
  park(
    payload: Record<string, unknown>,
    deviceId: string,
  ): Promise<ParkedSale> {
    return this.tenants.runTx(() => this.parkIn(payload, deviceId));
  }

  private async parkIn(
    payload: Record<string, unknown>,
    deviceId: string,
  ): Promise<ParkedSale> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `INSERT INTO parked_sales (tenant_id, id, device_id, payload)
       VALUES ($1::uuid, $2, $3, $4::jsonb)
       RETURNING ${COLUMNS}`,
      [tenantId, newUuid(), deviceId, JSON.stringify(payload)],
    )) as ParkedRow[];
    return toParked(rows[0]);
  }

  /**
   * `deleteParked` — which is also how a bill is recalled: Checkout's `_handleResume`
   * loads the cart and deletes the row. The deleted row comes back, so the delete
   * *is* the recall: two tills recalling the same bill cannot both get it, because
   * only one `DELETE … RETURNING` finds the row and the other is `404`.
   */
  remove(id: string): Promise<ParkedSale> {
    return this.tenants.runTx(() => this.removeIn(id));
  }

  private async removeIn(id: string): Promise<ParkedSale> {
    const { tenantId, manager } = currentRequestContext();
    const rows = returning<ParkedRow>(
      await manager.query(
        `DELETE FROM parked_sales WHERE tenant_id = $1::uuid AND id = $2 RETURNING ${COLUMNS}`,
        [tenantId, id],
      ),
    );
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'PARKED_SALE_NOT_FOUND', message: 'Parked sale not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    return toParked(rows[0]);
  }
}

/** `{ payload: { … } }` — the snapshot must be a JSON object; its contents are the client's. */
export function parseParkBody(body: unknown): Record<string, unknown> {
  const payload = (body as { payload?: unknown } | null)?.payload;
  if (
    typeof payload !== 'object' ||
    payload === null ||
    Array.isArray(payload)
  ) {
    throw new BadRequestException('payload must be an object');
  }
  return payload as Record<string, unknown>;
}

function toParked(r: ParkedRow): ParkedSale {
  return {
    id: r.id,
    parkedAt: r.parked_at.toISOString(),
    deviceId: r.device_id,
    payload: r.payload,
  };
}
