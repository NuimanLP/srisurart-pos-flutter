import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { newId } from '../common/ids.js';
import { fromSatang } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import { ReviewItemsService } from '../review-items/review-items.service.js';

/** Who is at the drawer — from the token, never from the body. */
export interface Actor {
  userId: string;
  deviceId: string;
}

export interface OpenShiftInput {
  id?: string;
  startingCashSatang: number;
  openedAt?: Date;
}

/** A shift row as the API hands it back. Money is the wire format, `"1234.50"`. */
export interface Shift {
  id: string;
  dateStr: string;
  startingCash: string;
  openedAt: string;
  closedAt: string | null;
  physicalCash: string | null;
  isActive: boolean;
  autoArchived: boolean;
  archivedAt: string | null;
  deviceId: string | null;
}

export interface DrawerEntry {
  id: string;
  shiftId: string;
  type: 'in' | 'out';
  amount: string;
  note: string;
  createdAt: string;
}

export interface ShiftWithEntries extends Shift {
  entries: DrawerEntry[];
}

interface ShiftRow {
  id: string;
  date_str: string;
  starting_cash: string;
  opened_at: Date;
  closed_at: Date | null;
  physical_cash: string | null;
  is_active: boolean;
  auto_archived: boolean;
  archived_at: Date | null;
  device_id: string | null;
}

const SHIFT_COLUMNS = `id, date_str, starting_cash, opened_at, closed_at,
                       physical_cash, is_active, auto_archived, archived_at, device_id`;

/**
 * The cash drawer: one shift per device at a time, and the `shift_id` stamp that
 * makes the closing report computable at all.
 *
 * ⚠️ **`is_active` does not mean "open".** `closeShift` leaves it true — the shift
 * keeps being *this device's current drawer* until the next open archives it, which
 * is what `shifts_repository.dart` does and what `uq_shift_active` (unique on
 * `(tenant_id, device_id) WHERE is_active`) depends on. "Open" is `closed_at IS NULL`.
 *
 * Reads are tenant-wide, writes are per device (ADR-0004: reading does not touch the
 * drawer, so `backoffice` may look; only `pos` may open, close or add money). In this
 * shop those coincide — `one_pos_per_tenant` means there is exactly one drawer — but
 * a read that filtered by the caller's device would show a `backoffice` machine
 * nothing at all, which is not what "readable from both" means.
 */
@Injectable()
export class ShiftsService {
  constructor(private readonly tenants: TenantService) {}

  /** The tenant's current drawer with its entries, or null when none was ever opened. */
  current(): Promise<ShiftWithEntries | null> {
    return this.tenants.runTx(() => this.currentIn());
  }

  private async currentIn(): Promise<ShiftWithEntries | null> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND is_active
        ORDER BY opened_at DESC
        LIMIT 1`,
      [tenantId],
    )) as ShiftRow[];
    if (rows.length === 0) return null;
    return this.withEntries(manager, tenantId, rows[0]);
  }

  /** Archived shifts, newest first. Paginated — this table grows by one a day forever. */
  history(
    page: number,
    limit: number,
  ): Promise<{ items: ShiftWithEntries[]; total: number }> {
    return this.tenants.runTx(() => this.historyIn(page, limit));
  }

  private async historyIn(
    page: number,
    limit: number,
  ): Promise<{ items: ShiftWithEntries[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const totalRows = (await manager.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid AND NOT is_active`,
      [tenantId],
    )) as { n: number }[];
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND NOT is_active
        ORDER BY opened_at DESC, id DESC
        LIMIT $2 OFFSET $3`,
      [tenantId, limit, (page - 1) * limit],
    )) as ShiftRow[];
    if (rows.length === 0) return { items: [], total: totalRows[0].n };

    // #417: one query for the whole page's drawer entries, not one per shift.
    const entries = (await manager.query(
      `SELECT id, shift_id, type, amount, note, created_at
         FROM drawer_entries
        WHERE tenant_id = $1::uuid AND shift_id = ANY($2::text[])
        ORDER BY shift_id, created_at DESC`,
      [tenantId, rows.map((r) => r.id)],
    )) as EntryRow[];
    const byShift = new Map<string, DrawerEntry[]>();
    for (const entry of entries) {
      const list = byShift.get(entry.shift_id) ?? [];
      list.push(toEntry(entry));
      byShift.set(entry.shift_id, list);
    }
    return {
      items: rows.map((row) => ({
        ...toShift(row),
        entries: byShift.get(row.id) ?? [],
      })),
      total: totalRows[0].n,
    };
  }

  /**
   * Opens a drawer for `deviceId`.
   *
   * Accepts an optional client `id` and `openedAt`. If a shift with `id` already exists,
   * returns it untouched without re-archiving. If an active shift exists on this device,
   * archives it; if that previous shift was never closed, it is flagged `auto_archived`
   * and recorded in `owner_review_items` as `shift_uncounted`.
   */
  open(actor: Actor, input: OpenShiftInput): Promise<ShiftWithEntries> {
    return this.tenants.runTx(() => this.openIn(actor, input));
  }

  private async openIn(
    actor: Actor,
    input: OpenShiftInput,
  ): Promise<ShiftWithEntries> {
    const deviceId = actor.deviceId;
    const { tenantId, manager } = currentRequestContext();

    // 🔴 A retired machine may not open a drawer (#144). Its access token lives up to 15
    // minutes past the retirement (ADR-0009 — no denylist), and a drawer opened in that
    // window is exactly the stranded shift retirement archived away: `current()` would
    // show it above the replacement till's. `FOR SHARE` so a concurrent retirement
    // (`FOR NO KEY UPDATE` on this row) either finishes first and is seen here, or waits
    // for this open and then archives what it opened. Lock order: devices → shifts.
    const device = (await manager.query(
      `SELECT retired_at FROM devices
        WHERE tenant_id = $1::uuid AND id = $2
          FOR NO KEY UPDATE`,
      [tenantId, deviceId],
    )) as { retired_at: Date | null }[];
    if (device.length === 0 || device[0].retired_at !== null) {
      throw new DeviceRoleForbiddenException();
    }

    // 🔴 Slice 7: If the client passed an id and that shift already exists for this tenant,
    // hand it back untouched without re-archiving.
    const shiftId = input.id ? input.id.trim() : null;
    if (shiftId) {
      const existing = (await manager.query(
        `SELECT ${SHIFT_COLUMNS} FROM shifts
          WHERE tenant_id = $1::uuid AND id = $2`,
        [tenantId, shiftId],
      )) as ShiftRow[];
      if (existing.length > 0) {
        return this.withEntries(manager, tenantId, existing[0]);
      }
    }

    const active = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active
        ORDER BY opened_at DESC
        LIMIT 1
          FOR UPDATE`,
      [tenantId, deviceId],
    )) as ShiftRow[];

    if (active.length > 0) {
      const uncounted = await this.archive(manager, tenantId, active[0]);
      if (uncounted) {
        await ReviewItemsService.insertIn(manager, tenantId, {
          kind: 'shift_uncounted',
          refId: active[0].id,
          details: {
            shiftId: active[0].id,
            deviceId,
            startingCash: active[0].starting_cash,
            openedAt:
              active[0].opened_at instanceof Date
                ? active[0].opened_at.toISOString()
                : String(active[0].opened_at),
          },
        });
      }
    }

    const openedAt = input.openedAt ?? new Date();
    const dateStr = await this.dateStrOf(manager, tenantId, openedAt);
    const newShiftId = shiftId ?? newId('sh');

    const conflictClause = shiftId
      ? `ON CONFLICT (tenant_id, id) DO NOTHING`
      : `ON CONFLICT (tenant_id, device_id) WHERE is_active DO NOTHING`;

    const inserted = (await manager.query(
      `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active, device_id, opened_by)
            VALUES ($1::uuid, $2, $3, $4, $5, TRUE, $6, $7::uuid)
       ${conflictClause}
         RETURNING ${SHIFT_COLUMNS}`,
      [
        tenantId,
        newShiftId,
        dateStr,
        fromSatang(input.startingCashSatang),
        openedAt,
        deviceId,
        actor.userId,
      ],
    )) as ShiftRow[];

    if (inserted.length > 0)
      return this.withEntries(manager, tenantId, inserted[0]);

    // Another request opened the drawer while this one was deciding to. Pressing the
    // button twice must not be an error, so hand back what that one opened.
    const winnerQuery = shiftId
      ? `SELECT ${SHIFT_COLUMNS} FROM shifts WHERE tenant_id = $1::uuid AND id = $2`
      : `SELECT ${SHIFT_COLUMNS} FROM shifts WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active LIMIT 1`;
    const winnerParams = shiftId ? [tenantId, shiftId] : [tenantId, deviceId];
    const winner = (await manager.query(
      winnerQuery,
      winnerParams,
    )) as ShiftRow[];
    if (winner.length === 0) {
      throw new Error(
        `Shift for device ${deviceId} vanished between insert and read.`,
      );
    }
    return this.withEntries(manager, tenantId, winner[0]);
  }

  /**
   * Stamps `closed_at` and the cash actually counted. The shift stays `is_active`:
   * it is still this device's drawer until tomorrow's open archives it.
   */
  close(
    deviceId: string,
    physicalCashSatang: number,
  ): Promise<ShiftWithEntries> {
    return this.tenants.runTx(() => this.closeIn(deviceId, physicalCashSatang));
  }

  private async closeIn(
    deviceId: string,
    physicalCashSatang: number,
  ): Promise<ShiftWithEntries> {
    const { tenantId, manager } = currentRequestContext();
    const shift = await this.lockActive(manager, tenantId, deviceId);
    if (shift.closed_at !== null) {
      // `physical_cash` is the number the day is reconciled against. A second press of
      // the button carries a different idempotency key, so nothing else would stop it
      // from overwriting the counted cash — silently, with no audit trail.
      //
      // Not `DRAWER_CLOSED`: that code's documented Thai message is about refusing a
      // *cash entry*, which is a different action, and the Dart reference never refuses
      // a second close at all — so there is no Thai sentence to copy. English until the
      // shop words it, per §8.1.
      throw new HttpException(
        {
          code: 'SHIFT_ALREADY_CLOSED',
          message: 'This shift is already closed.',
        },
        HttpStatus.CONFLICT,
      );
    }
    const rows = returning<ShiftRow>(
      await manager.query(
        `UPDATE shifts SET closed_at = now(), physical_cash = $3
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING ${SHIFT_COLUMNS}`,
        [tenantId, shift.id, fromSatang(physicalCashSatang)],
      ),
    );
    return this.withEntries(manager, tenantId, rows[0]);
  }

  /**
   * Closes and archives whatever drawer `deviceId` still holds, for retiring a machine:
   * ADR-0004 requires that to happen in the same transaction as setting `retired_at`, so
   * `DevicesService.retire` calls this rather than reaching into `shifts` itself. A device
   * with no current drawer is not an error here — there is simply nothing to close.
   *
   * 🔴 **The caller must already hold the device row** (`FOR NO KEY UPDATE`, taken by
   * `DevicesService.retire`). Lock order is **devices → shifts**, the same order `open()`
   * takes (`FOR SHARE` on the device, then the shift), so a stale `pos` access token
   * opening a drawer and the owner retiring that machine cannot deadlock.
   *
   * - An **open** drawer (`closed_at IS NULL`) needs the counted cash:
   *   `physicalCashSatang === null` is `409 PHYSICAL_CASH_REQUIRED`, never a defaulted 0
   *   (the same reason `POST /shifts/close` requires it).
   * - A drawer **closed but still `is_active`** (closed tonight, retired before the next
   *   open) is archived as it is — its counted cash is kept, and `physicalCash` is ignored.
   *
   * Returns the archived shift (`isActive: false`), or null when there was none.
   */
  closeForRetirement(
    deviceId: string,
    physicalCashSatang: number | null,
  ): Promise<ShiftWithEntries | null> {
    return this.tenants.runTx(() =>
      this.closeForRetirementIn(deviceId, physicalCashSatang),
    );
  }

  private async closeForRetirementIn(
    deviceId: string,
    physicalCashSatang: number | null,
  ): Promise<ShiftWithEntries | null> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active
        ORDER BY opened_at DESC
        LIMIT 1
          FOR UPDATE`,
      [tenantId, deviceId],
    )) as ShiftRow[];
    if (rows.length === 0) return null;
    const shift = rows[0];

    let result: ShiftWithEntries;
    if (shift.closed_at === null) {
      if (physicalCashSatang === null) {
        throw new HttpException(
          {
            code: 'PHYSICAL_CASH_REQUIRED',
            message:
              'This device has an open shift. Count the drawer and send physicalCash to close it.',
            details: { shiftId: shift.id },
          },
          HttpStatus.CONFLICT,
        );
      }
      result = await this.close(deviceId, physicalCashSatang);
    } else {
      result = await this.withEntries(manager, tenantId, shift);
    }

    // 🔴 Archive it too. Normally the device's NEXT open archives the drawer, but a
    // retired device never opens again — so the row would stay `is_active` forever,
    // and `history()` (`NOT is_active`) would hide that day's takings while
    // `current()` shows a drawer nothing can close. That is exactly the day ADR-0004
    // wants preserved. A drawer closed before the retirement is stranded the same way,
    // which is why it is archived too (with `auto_archived` left false: it was closed).
    const archived = returning<ShiftRow>(
      await manager.query(
        `UPDATE shifts
            SET is_active = FALSE,
                archived_at = COALESCE(archived_at, now())
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING ${SHIFT_COLUMNS}`,
        [tenantId, shift.id],
      ),
    );
    return { ...toShift(archived[0]), entries: result.entries };
  }

  /** Adds money in or out of the open drawer. */
  addEntry(
    actor: Actor,
    entry: {
      id?: string | null;
      type: 'in' | 'out';
      amountSatang: number;
      note: string | null;
      createdAt?: Date | string | null;
    },
  ): Promise<DrawerEntry> {
    return this.tenants.runTx(() => this.addEntryIn(actor, entry));
  }

  private async addEntryIn(
    actor: Actor,
    entry: {
      id?: string | null;
      type: 'in' | 'out';
      amountSatang: number;
      note: string | null;
      createdAt?: Date | string | null;
    },
  ): Promise<DrawerEntry> {
    const { tenantId, manager } = currentRequestContext();
    const shift = await this.lockActive(manager, tenantId, actor.deviceId);

    if (shift.closed_at !== null) {
      throw new HttpException(
        {
          code: 'DRAWER_CLOSED',
          message: 'ลิ้นชักปิดแล้ว ไม่สามารถบันทึกรายการเงินเพิ่มได้',
        },
        HttpStatus.CONFLICT,
      );
    }

    const entryId = entry.id?.trim() || newId('de');
    const createdAtVal = entry.createdAt
      ? entry.createdAt instanceof Date
        ? entry.createdAt.toISOString()
        : entry.createdAt
      : null;

    const rows = (await manager.query(
      `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_by, created_at)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7::uuid, COALESCE($8::timestamptz, now()))
         RETURNING id, shift_id, type, amount, note, created_at`,
      [
        tenantId,
        entryId,
        shift.id,
        entry.type,
        fromSatang(entry.amountSatang),
        entry.note ?? '',
        actor.userId,
        createdAtVal,
      ],
    )) as {
      id: string;
      shift_id: string;
      type: 'in' | 'out';
      amount: string;
      note: string;
      created_at: Date;
    }[];
    return toEntry(rows[0]);
  }

  /**
   * The shift id to stamp on a document this device is writing right now, or null if
   * the drawer was never opened. Only a non-cash `POST /returns` still uses it; money
   * crossing the drawer goes through `requireOpenShiftIdFor`, which refuses instead.
   *
   * The closing report is computed **by `shift_id`**, never by a timestamp window: a
   * window breaks across midnight and cannot separate two machines.
   *
   * 🔴 **`FOR SHARE`, for the same reason as `requireOpenShiftIdFor`** (#100 review). A
   * transfer refund moves no expected cash, but the closing report's `grossProfit` nets
   * refunds of every method; unlocked, a `close()` could commit between this read and the
   * insert and the credit note would land on — and change — a shift already counted.
   * Locked, the close waits, or the refund reads the row after it and stamps null. Over
   * zero rows the lock takes nothing and the answer is null, as before.
   */
  async currentShiftIdFor(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
  ): Promise<string | null> {
    const rows = (await manager.query(
      `SELECT id FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active AND closed_at IS NULL
        ORDER BY opened_at DESC
        LIMIT 1
          FOR SHARE`,
      [tenantId, deviceId],
    )) as { id: string }[];
    return rows.length === 0 ? null : rows[0].id;
  }

  /**
   * The shift id to stamp on money this device is taking right now — or
   * `409 NO_OPEN_SHIFT`. `POST /sales` and `POST /mechanics/:id/credit-payments` use
   * this, for every payment method (and `POST /sales/:id/void`, #94, to compare against
   * the bill's own shift; and a `'เงินสด'` `POST /returns`, #100): the owner's rule
   * (2026-09-13) is that money is only taken while this device's drawer is open, because
   * money stamped with no shift lands in no closing report. "Open" is `closed_at IS NULL`,
   * so a drawer that was closed and not yet archived by the next open refuses too.
   *
   * 🔴 **`FOR SHARE`, not a plain read.** Unlocked, a bill can read the drawer open,
   * `close()` can commit the counted cash, and the bill then commits stamped onto a shift
   * that was already counted — the very money this rule exists to catch. `close()` takes
   * `FOR UPDATE` on this row, so it waits for bills in flight; a bill arriving behind the
   * close re-checks the row once the close commits, finds `closed_at` set, and is
   * refused. `SHARE` rather than `UPDATE` so bills on one till do not serialise on each
   * other. Shared locks never wait on each other, which is why this lock's place relative
   * to the mechanic's row (after it on a credit payment, before it on a sale, a void or
   * any refund, where it follows the bill's own row lock) cannot
   * deadlock: the only exclusive holders — open, close, drawer entries, retirement —
   * take no other money-path lock. Keep it that way.
   */
  async requireOpenShiftIdFor(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
  ): Promise<string> {
    const rows = (await manager.query(
      `SELECT id FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active AND closed_at IS NULL
        ORDER BY opened_at DESC
        LIMIT 1
          FOR SHARE`,
      [tenantId, deviceId],
    )) as { id: string }[];
    if (rows.length === 0) throw noOpenShift();
    return rows[0].id;
  }

  /** This device's current drawer, locked, or `409 NO_OPEN_SHIFT`. */
  private async lockActive(
    manager: EntityManager,
    tenantId: string,
    deviceId: string,
  ): Promise<ShiftRow> {
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active
        ORDER BY opened_at DESC
        LIMIT 1
          FOR UPDATE`,
      [tenantId, deviceId],
    )) as ShiftRow[];
    if (rows.length === 0) throw noOpenShift();
    return rows[0];
  }

  /**
   * Retires the previous shift. A shift that was never closed is archived with
   * `auto_archived` set rather than discarded — the day's takings are still a day's
   * takings even if nobody pressed the button. Returns true when the shift was never closed.
   */
  private async archive(
    manager: EntityManager,
    tenantId: string,
    shift: ShiftRow,
  ): Promise<boolean> {
    const neverClosed = shift.closed_at === null;
    await manager.query(
      `UPDATE shifts
          SET is_active = FALSE,
              auto_archived = auto_archived OR $3,
              archived_at = COALESCE(archived_at, now())
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, shift.id, neverClosed],
    );
    return neverClosed;
  }

  /** Date key (yyyy-MM-dd) from opened_at in the tenant's own timezone, not in UTC's. */
  private async dateStrOf(
    manager: EntityManager,
    tenantId: string,
    openedAt: Date,
  ): Promise<string> {
    const rows = (await manager.query(
      `SELECT to_char($2::timestamptz AT TIME ZONE t.timezone, 'YYYY-MM-DD') AS d
         FROM tenants t WHERE t.id = $1::uuid`,
      [tenantId, openedAt],
    )) as { d: string }[];
    if (rows.length === 0) throw new Error(`Tenant ${tenantId} not found.`);
    return rows[0].d;
  }

  private async withEntries(
    manager: EntityManager,
    tenantId: string,
    shift: ShiftRow,
  ): Promise<ShiftWithEntries> {
    const rows = (await manager.query(
      `SELECT id, shift_id, type, amount, note, created_at
         FROM drawer_entries
        WHERE tenant_id = $1::uuid AND shift_id = $2
        ORDER BY created_at DESC`,
      [tenantId, shift.id],
    )) as EntryRow[];
    return { ...toShift(shift), entries: rows.map(toEntry) };
  }
}

/** The one `NO_OPEN_SHIFT` shape, shared by the drawer's own writes and the money path. */
function noOpenShift(): HttpException {
  return new HttpException(
    { code: 'NO_OPEN_SHIFT', message: 'No open shift' },
    HttpStatus.CONFLICT,
  );
}

function toShift(row: ShiftRow): Shift {
  return {
    id: row.id,
    dateStr: row.date_str,
    startingCash: row.starting_cash,
    openedAt: row.opened_at.toISOString(),
    closedAt: row.closed_at ? row.closed_at.toISOString() : null,
    physicalCash: row.physical_cash,
    isActive: row.is_active,
    autoArchived: row.auto_archived,
    archivedAt: row.archived_at ? row.archived_at.toISOString() : null,
    deviceId: row.device_id,
  };
}

type EntryRow = {
  id: string;
  shift_id: string;
  type: 'in' | 'out';
  amount: string;
  note: string;
  created_at: Date;
};

function toEntry(row: EntryRow): DrawerEntry {
  return {
    id: row.id,
    shiftId: row.shift_id,
    type: row.type,
    amount: row.amount,
    note: row.note,
    createdAt: row.created_at.toISOString(),
  };
}
