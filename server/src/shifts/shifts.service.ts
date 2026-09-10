import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { newId } from '../common/ids.js';
import { fromSatang } from '../common/money.js';
import { currentRequestContext } from '../common/request-context.js';
import { returning } from '../common/sql.js';

/** Who is at the drawer — from the token, never from the body. */
export interface Actor {
  userId: string;
  deviceId: string;
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
  /** The tenant's current drawer with its entries, or null when none was ever opened. */
  async current(): Promise<ShiftWithEntries | null> {
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
  async history(page: number, limit: number): Promise<{ items: ShiftWithEntries[]; total: number }> {
    const { tenantId, manager } = currentRequestContext();
    const totalRows = (await manager.query(
      `SELECT count(*)::int AS n FROM shifts WHERE tenant_id = $1::uuid AND NOT is_active`,
      [tenantId],
    )) as { n: number }[];
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND NOT is_active
        ORDER BY opened_at DESC
        LIMIT $2 OFFSET $3`,
      [tenantId, limit, (page - 1) * limit],
    )) as ShiftRow[];
    const items = [];
    for (const row of rows) items.push(await this.withEntries(manager, tenantId, row));
    return { items, total: totalRows[0].n };
  }

  /**
   * Opens today's drawer for `deviceId`.
   *
   * Re-opening on the same day returns the existing shift untouched — staff press the
   * button twice. A new day archives the previous shift **first**, flagged
   * `auto_archived` if it was never closed, so a day's takings are never lost.
   */
  async open(
    actor: Actor,
    startingCashSatang: number,
  ): Promise<ShiftWithEntries> {
    const deviceId = actor.deviceId;
    const { tenantId, manager } = currentRequestContext();
    const today = await this.today(manager, tenantId);

    const active = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active
        ORDER BY opened_at DESC
        LIMIT 1
          FOR UPDATE`,
      [tenantId, deviceId],
    )) as ShiftRow[];

    if (active.length > 0 && active[0].date_str === today) {
      return this.withEntries(manager, tenantId, active[0]);
    }

    if (active.length > 0) {
      await this.archive(manager, tenantId, active[0]);
    }

    const inserted = (await manager.query(
      `INSERT INTO shifts (tenant_id, id, date_str, starting_cash, opened_at, is_active, device_id, opened_by)
            VALUES ($1::uuid, $2, $3, $4, now(), TRUE, $5, $6::uuid)
       ON CONFLICT (tenant_id, device_id) WHERE is_active DO NOTHING
         RETURNING ${SHIFT_COLUMNS}`,
      [
        tenantId,
        newId('sh'),
        today,
        fromSatang(startingCashSatang),
        deviceId,
        actor.userId,
      ],
    )) as ShiftRow[];

    if (inserted.length > 0) return this.withEntries(manager, tenantId, inserted[0]);

    // Another request opened the drawer while this one was deciding to. Pressing the
    // button twice must not be an error, so hand back what that one opened.
    const winner = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active
        LIMIT 1`,
      [tenantId, deviceId],
    )) as ShiftRow[];
    if (winner.length === 0) {
      throw new Error(`Shift for device ${deviceId} vanished between insert and read.`);
    }
    return this.withEntries(manager, tenantId, winner[0]);
  }

  /**
   * Stamps `closed_at` and the cash actually counted. The shift stays `is_active`:
   * it is still this device's drawer until tomorrow's open archives it.
   */
  async close(deviceId: string, physicalCashSatang: number): Promise<ShiftWithEntries> {
    const { tenantId, manager } = currentRequestContext();
    const shift = await this.lockActive(manager, tenantId, deviceId);
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
   * Closes whatever `deviceId` still has open, for retiring a `pos` machine: ADR-0004
   * requires that to happen in the same transaction as setting `retired_at`, so the
   * device endpoint calls this rather than reaching into `shifts` itself. A device
   * with nothing open is not an error here — there is simply nothing to close.
   */
  async closeForRetirement(
    deviceId: string,
    physicalCashSatang: number,
  ): Promise<ShiftWithEntries | null> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${SHIFT_COLUMNS} FROM shifts
        WHERE tenant_id = $1::uuid AND device_id = $2 AND is_active AND closed_at IS NULL
        LIMIT 1
          FOR UPDATE`,
      [tenantId, deviceId],
    )) as ShiftRow[];
    if (rows.length === 0) return null;
    return this.close(deviceId, physicalCashSatang);
  }

  /** Adds money in or out of the open drawer. */
  async addEntry(
    actor: Actor,
    entry: { type: 'in' | 'out'; amountSatang: number; note: string | null },
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

    const rows = (await manager.query(
      `INSERT INTO drawer_entries (tenant_id, id, shift_id, type, amount, note, created_by)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, $7::uuid)
         RETURNING id, shift_id, type, amount, note, created_at`,
      [
        tenantId,
        newId('de'),
        shift.id,
        entry.type,
        fromSatang(entry.amountSatang),
        entry.note ?? '',
        actor.userId,
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
   * the drawer was never opened — the old app lets staff sell without opening it, and
   * refusing the sale would be a new rule, not a ported one.
   *
   * The closing report is computed **by `shift_id`**, never by a timestamp window: a
   * window breaks across midnight and cannot separate two machines.
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
        LIMIT 1`,
      [tenantId, deviceId],
    )) as { id: string }[];
    return rows.length === 0 ? null : rows[0].id;
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
    if (rows.length === 0) {
      throw new HttpException(
        { code: 'NO_OPEN_SHIFT', message: 'No open shift' },
        HttpStatus.CONFLICT,
      );
    }
    return rows[0];
  }

  /**
   * Retires the previous shift. A shift that was never closed is archived with
   * `auto_archived` set rather than discarded — the day's takings are still a day's
   * takings even if nobody pressed the button.
   */
  private async archive(
    manager: EntityManager,
    tenantId: string,
    shift: ShiftRow,
  ): Promise<void> {
    const neverClosed = shift.closed_at === null;
    await manager.query(
      `UPDATE shifts
          SET is_active = FALSE,
              auto_archived = $3,
              archived_at = CASE WHEN $3 THEN now() ELSE archived_at END
        WHERE tenant_id = $1::uuid AND id = $2`,
      [tenantId, shift.id, neverClosed],
    );
  }

  /** Today's date key (yyyy-MM-dd) in the tenant's own timezone, not in UTC's. */
  private async today(manager: EntityManager, tenantId: string): Promise<string> {
    const rows = (await manager.query(
      `SELECT to_char(now() AT TIME ZONE t.timezone, 'YYYY-MM-DD') AS d
         FROM tenants t WHERE t.id = $1::uuid`,
      [tenantId],
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
    )) as {
      id: string;
      shift_id: string;
      type: 'in' | 'out';
      amount: string;
      note: string;
      created_at: Date;
    }[];
    return { ...toShift(shift), entries: rows.map(toEntry) };
  }

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

function toEntry(row: {
  id: string;
  shift_id: string;
  type: 'in' | 'out';
  amount: string;
  note: string;
  created_at: Date;
}): DrawerEntry {
  return {
    id: row.id,
    shiftId: row.shift_id,
    type: row.type,
    amount: row.amount,
    note: row.note,
    createdAt: row.created_at.toISOString(),
  };
}
