import { BadRequestException, HttpException, HttpStatus, Injectable, NotFoundException } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { AuditService } from '../audit/audit.service.js';
import { ClientIdReusedException } from '../common/client-id-reused.exception.js';
import { TenantService } from '../common/database/tenant.service.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';
import type {
  PaymentAccount,
  PaymentAccountCreate,
  PaymentAccountPatch,
} from './payment-accounts.dto.js';
import { MAX_ACTIVE_PAYMENT_ACCOUNTS, type ImageMime, type PaymentAccountKind } from './payment-accounts.rules.js';

export interface PaymentAccountRow {
  id: string;
  nickname: string;
  bank_code: string;
  kind: PaymentAccountKind;
  promptpay_id: string | null;
  image: Buffer | null;
  image_mime: ImageMime | null;
  is_default: boolean;
  sort_order: number;
  updated_at: Date;
  deleted_at: Date | null;
}

const COLUMNS = `id, nickname, bank_code, kind, promptpay_id, image, image_mime,
                 is_default, sort_order, updated_at, deleted_at`;

/**
 * The shop's QR payment accounts (contract §1/§2). Every write runs inside the route's
 * `runIdempotent` transaction (this service's `runTx` joins it) and first takes a
 * per-tenant transaction-scoped advisory lock, so the 5-active count, the id check and
 * the default switch are all judged with no other account write of this shop in flight —
 * including the very first one, when there is no row yet to lock `FOR UPDATE`.
 *
 * The advisory lock touches no table row, so a sale naming an account (its FK check takes
 * `FOR KEY SHARE` on the account row) never waits on it; and an `UPDATE` here changes no
 * key column, so it takes `FOR NO KEY UPDATE`, which `FOR KEY SHARE` does not conflict with.
 */
/** Who is acting — from the token, never from the body. */
export interface PaymentAccountActor {
  userId?: string;
  deviceId?: string;
  ip?: string;
}

@Injectable()
export class PaymentAccountsService {
  constructor(
    private readonly tenants: TenantService,
    private readonly audit: AuditService,
  ) {}

  /** Active rows only, in display order. */
  list(): Promise<PaymentAccount[]> {
    return this.tenants.runTx(() => this.listIn());
  }

  private async listIn(): Promise<PaymentAccount[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${COLUMNS} FROM payment_accounts
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL
        ORDER BY sort_order ASC, created_at ASC, id ASC`,
      [tenantId],
    )) as PaymentAccountRow[];
    return rows.map(toPaymentAccount);
  }

  create(actor: PaymentAccountActor, input: PaymentAccountCreate): Promise<PaymentAccount> {
    return this.tenants.runTx(() => this.createIn(actor, input));
  }

  private async createIn(actor: PaymentAccountActor, input: PaymentAccountCreate): Promise<PaymentAccount> {
    const { tenantId, manager } = currentRequestContext();
    await lockAccounts(manager, tenantId);

    // A client-minted id already taken — by a live row or a soft-deleted one — is another
    // account, not a retry: a retry carries its Idempotency-Key and was replayed before here.
    const taken = (await manager.query(
      `SELECT 1 FROM payment_accounts WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, input.id],
    )) as unknown[];
    if (taken.length > 0) throw new ClientIdReusedException('payment_account.create', input.id);

    const active = (await manager.query(
      `SELECT count(*)::int AS n FROM payment_accounts
        WHERE tenant_id = $1::uuid AND deleted_at IS NULL`,
      [tenantId],
    )) as { n: number }[];
    if (active[0].n >= MAX_ACTIVE_PAYMENT_ACCOUNTS) throw paymentAccountLimit();

    const previousDefaultId = input.isDefault ? await clearDefault(manager, tenantId) : null;
    const rows = (await manager.query(
      `INSERT INTO payment_accounts
         (tenant_id, id, nickname, bank_code, kind, promptpay_id, image, image_mime, is_default, sort_order)
       VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       RETURNING ${COLUMNS}`,
      [
        tenantId,
        input.id,
        input.nickname,
        input.bankCode,
        input.kind,
        input.promptpayId,
        input.image?.bytes ?? null,
        input.image?.mime ?? null,
        input.isDefault,
        input.sortOrder,
      ],
    )) as PaymentAccountRow[];
    await this.writeAudit(manager, tenantId, actor, 'payment_account.created', rows[0], {
      after: { ...auditSummary(rows[0]), ...(previousDefaultId ? { previousDefaultId } : {}) },
    });
    return toPaymentAccount(rows[0]);
  }

  update(actor: PaymentAccountActor, id: string, patch: PaymentAccountPatch): Promise<PaymentAccount> {
    return this.tenants.runTx(() => this.updateIn(actor, id, patch));
  }

  private async updateIn(
    actor: PaymentAccountActor,
    id: string,
    patch: PaymentAccountPatch,
  ): Promise<PaymentAccount> {
    const { tenantId, manager } = currentRequestContext();
    await lockAccounts(manager, tenantId);
    const current = await activeRow(manager, tenantId, id);

    if (patch.kind !== undefined && patch.kind !== current.kind) {
      throw new BadRequestException(
        `Field 'kind' cannot change (${current.kind}); delete the account and create a new one`,
      );
    }
    if (patch.promptpayId !== undefined && current.kind !== 'promptpay') {
      throw new BadRequestException(`Field 'promptpayId' is only for kind 'promptpay'`);
    }
    if (patch.image !== undefined && current.kind !== 'image') {
      throw new BadRequestException(`Fields 'imageBase64'/'imageMime' are only for kind 'image'`);
    }

    const previousDefaultId =
      patch.isDefault === true && !current.is_default ? await clearDefault(manager, tenantId, id) : null;
    // `returning`: TypeORM answers an UPDATE … RETURNING as `[rows, count]` (common/sql.ts).
    const rows = returning<PaymentAccountRow>(await manager.query(
      `UPDATE payment_accounts SET
              nickname     = $3,
              bank_code    = $4,
              promptpay_id = $5,
              image        = $6,
              image_mime   = $7,
              is_default   = $8,
              sort_order   = $9,
              updated_at   = now()
        WHERE tenant_id = $1::uuid AND id = $2
        RETURNING ${COLUMNS}`,
      [
        tenantId,
        id,
        patch.nickname ?? current.nickname,
        patch.bankCode ?? current.bank_code,
        patch.promptpayId ?? current.promptpay_id,
        patch.image?.bytes ?? current.image,
        patch.image?.mime ?? current.image_mime,
        patch.isDefault ?? current.is_default,
        patch.sortOrder ?? current.sort_order,
      ],
    ));
    const changedFields = changedFieldsOf(current, rows[0]);
    // A PATCH that only moved the default is the default switch; anything else is an edit.
    const action =
      changedFields.length === 1 && changedFields[0] === 'isDefault'
        ? 'payment_account.default_changed'
        : 'payment_account.updated';
    await this.writeAudit(manager, tenantId, actor, action, rows[0], {
      before: auditSummary(current),
      after: {
        ...auditSummary(rows[0]),
        changedFields,
        ...(previousDefaultId ? { previousDefaultId } : {}),
      },
    });
    return toPaymentAccount(rows[0]);
  }

  /**
   * Soft delete: old bills keep their reference and the nickname stays reportable. Deleting
   * the default leaves the shop with no default (the client falls back to the first account).
   */
  remove(actor: PaymentAccountActor, id: string): Promise<PaymentAccount & { deletedAt: string }> {
    return this.tenants.runTx(() => this.removeIn(actor, id));
  }

  private async removeIn(
    actor: PaymentAccountActor,
    id: string,
  ): Promise<PaymentAccount & { deletedAt: string }> {
    const { tenantId, manager } = currentRequestContext();
    await lockAccounts(manager, tenantId);
    const rows = returning<PaymentAccountRow>(await manager.query(
      `UPDATE payment_accounts SET deleted_at = now(), is_default = false, updated_at = now()
        WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL
        RETURNING ${COLUMNS}`,
      [tenantId, id],
    ));
    if (rows.length === 0) throw paymentAccountNotFound();
    const deletedAt = rows[0].deleted_at!.toISOString();
    await this.writeAudit(manager, tenantId, actor, 'payment_account.deleted', rows[0], {
      after: { ...auditSummary(rows[0]), deletedAt },
    });
    return { ...toPaymentAccount(rows[0]), deletedAt };
  }

  /** One `audit_log` row on the request transaction: a write that rolls back leaves none. */
  private writeAudit(
    manager: EntityManager,
    tenantId: string,
    actor: PaymentAccountActor,
    action: string,
    row: PaymentAccountRow,
    detail: { before?: Record<string, unknown>; after: Record<string, unknown> },
  ): Promise<void> {
    return this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      ip: actor.ip,
      action,
      entity: 'payment_accounts',
      entityId: row.id,
      ...detail,
    });
  }
}

/**
 * What `audit_log` keeps of an account. Never the image bytes, and never the whole PromptPay
 * id: `audit_log` is read more widely than the till, which needs the number to build the QR.
 */
export function auditSummary(row: PaymentAccountRow): Record<string, unknown> {
  return {
    id: row.id,
    nickname: row.nickname,
    bankCode: row.bank_code,
    kind: row.kind,
    promptpayId: maskPromptPayId(row.promptpay_id),
    isDefault: row.is_default,
  };
}

/** `0812345678` → `******5678`: the last 4 digits only. */
export function maskPromptPayId(id: string | null): string | null {
  if (id === null) return null;
  return id.length <= 4 ? '*'.repeat(id.length) : '*'.repeat(id.length - 4) + id.slice(-4);
}

/** The wire names of the fields a PATCH actually changed (an image compares by its bytes). */
export function changedFieldsOf(before: PaymentAccountRow, after: PaymentAccountRow): string[] {
  const sameImage =
    before.image === null || after.image === null
      ? before.image === after.image
      : Buffer.from(before.image).equals(Buffer.from(after.image));
  const changed: Array<[string, boolean]> = [
    ['nickname', before.nickname !== after.nickname],
    ['bankCode', before.bank_code !== after.bank_code],
    ['promptpayId', before.promptpay_id !== after.promptpay_id],
    ['imageBase64', !sameImage],
    ['imageMime', before.image_mime !== after.image_mime],
    ['isDefault', before.is_default !== after.is_default],
    ['sortOrder', Number(before.sort_order) !== Number(after.sort_order)],
  ];
  return changed.filter(([, c]) => c).map(([name]) => name);
}

/** One account writer per shop at a time (see the class comment). */
async function lockAccounts(manager: EntityManager, tenantId: string): Promise<void> {
  await manager.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
    `${tenantId}:payment_accounts`,
  ]);
}

async function activeRow(manager: EntityManager, tenantId: string, id: string): Promise<PaymentAccountRow> {
  const rows = (await manager.query(
    `SELECT ${COLUMNS} FROM payment_accounts
      WHERE tenant_id = $1::uuid AND id = $2 AND deleted_at IS NULL`,
    [tenantId, id],
  )) as PaymentAccountRow[];
  if (rows.length === 0) throw paymentAccountNotFound();
  return rows[0];
}

/**
 * Clears the shop's default, in the same transaction that sets the new one. Returns the id
 * that was the default, for the audit row (null = there was none).
 */
async function clearDefault(
  manager: EntityManager,
  tenantId: string,
  exceptId?: string,
): Promise<string | null> {
  const rows = returning<{ id: string }>(
    await manager.query(
      `UPDATE payment_accounts SET is_default = false, updated_at = now()
        WHERE tenant_id = $1::uuid AND is_default AND deleted_at IS NULL
          AND ($2::uuid IS NULL OR id <> $2::uuid)
        RETURNING id`,
      [tenantId, exceptId ?? null],
    ),
  );
  return rows[0]?.id ?? null;
}

export function toPaymentAccount(row: PaymentAccountRow): PaymentAccount {
  return {
    id: row.id,
    nickname: row.nickname,
    bankCode: row.bank_code,
    kind: row.kind,
    promptpayId: row.promptpay_id,
    imageBase64: row.image === null ? null : Buffer.from(row.image).toString('base64'),
    imageMime: row.image_mime,
    isDefault: row.is_default,
    sortOrder: Number(row.sort_order),
    updatedAt: row.updated_at.toISOString(),
  };
}

function paymentAccountLimit(): HttpException {
  return new HttpException(
    {
      code: 'PAYMENT_ACCOUNT_LIMIT',
      message: `บันทึกบัญชีรับเงินได้สูงสุด ${MAX_ACTIVE_PAYMENT_ACCOUNTS} บัญชี`,
    },
    HttpStatus.CONFLICT,
  );
}

/** An unknown id, a soft-deleted one, or another shop's (RLS hides it) — all the same 404. */
function paymentAccountNotFound(): NotFoundException {
  return new NotFoundException('Payment account not found');
}
