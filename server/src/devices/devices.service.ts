import { HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { createHash, randomBytes } from 'node:crypto';
import { AuditService } from '../audit/audit.service.js';
import { newId } from '../common/ids.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { returning } from '../common/sql.js';
import {
  ShiftsService,
  type ShiftWithEntries,
} from '../shifts/shifts.service.js';
import { ReviewItemsService } from '../review-items/review-items.service.js';

export type DeviceRole = 'pos' | 'backoffice';

export interface RetireOptions {
  force?: boolean;
  note?: string | null;
}

/** A device as the API hands it back. Never carries `token_hash` or `enrol_code_hash`. */
export interface Device {
  id: string;
  label: string;
  deviceNo: number;
  role: DeviceRole;
  retiredAt: string | null;
  /** A browser has exchanged the enrolment code for a device token (`POST /auth/device`). */
  enrolled: boolean;
  /** When the outstanding enrolment code stops working, or null when none is outstanding. */
  enrolExpiresAt: string | null;
  lastSeenAt: string | null;
  unsyncedOps: number;
  unsyncedReportedAt: string | null;
}

/** Who is acting — from the token, never from the body. */
export interface DeviceActor {
  userId: string;
  deviceId?: string;
  ip?: string;
}

interface DeviceRow {
  id: string;
  label: string;
  device_no: number;
  role: DeviceRole;
  retired_at: Date | null;
  enrolled: boolean;
  enrol_expires_at: Date | null;
  last_seen_at: Date | null;
  unsynced_ops: number;
  unsynced_reported_at: Date | null;
}

const DEVICE_COLUMNS = `id, label, device_no, role, retired_at,
                        token_hash IS NOT NULL AS enrolled,
                        CASE WHEN enrol_expires_at > now() THEN enrol_expires_at END AS enrol_expires_at,
                        last_seen_at,
                        unsynced_ops,
                        unsynced_reported_at`;

/** `devices.device_no` is `CHECK (device_no BETWEEN 1 AND 99)` — two digits in every document number. */
const MAX_DEVICE_NO = 99;

/**
 * ADR-0004 proposes 15 minutes for the enrolment code and leaves it open for the owner;
 * the code is single-use either way (`auth_enrol_device` clears it).
 */
const ENROL_CODE_TTL_MINUTES = 15;

const UNIQUE_VIOLATION = '23505';

/**
 * Device binding (ADR-0004 "การผูกเครื่อง"): the owner creates a device and gets a one-time
 * enrolment code; the browser exchanges it at `POST /auth/device` (already in `AuthService`)
 * for the device token that `POST /auth/token` turns into `did`/`drole`. Retiring a device
 * closes its drawer and stamps `retired_at` in one transaction.
 */
@Injectable()
export class DevicesService {
  constructor(
    private readonly shifts: ShiftsService,
    private readonly audit: AuditService,
    private readonly tenants: TenantService,
  ) {}

  /** Every device of the tenant, retired ones included, by `device_no`. */
  list(): Promise<Device[]> {
    return this.tenants.runTx(() => this.listIn());
  }

  private async listIn(): Promise<Device[]> {
    const { tenantId, manager } = currentRequestContext();
    const rows = (await manager.query(
      `SELECT ${DEVICE_COLUMNS} FROM devices
        WHERE tenant_id = $1::uuid
        ORDER BY device_no`,
      [tenantId],
    )) as DeviceRow[];
    return rows.map(toDevice);
  }

  /**
   * Creates a device and its one-time enrolment code. The server picks the id and the
   * `device_no`; the body names only the label and the role.
   *
   * `device_no` is `max + 1` over **every** row, retired ones included, so a number is
   * never handed out twice (ADR-0004: a re-used number collides with the retired
   * machine's receipt series). Allocation is serialised per tenant with a transaction
   * advisory lock — the pattern `customers.service.ts` uses for its code sequence — so two
   * owners pressing "add device" at once cannot both read the same max.
   */
  create(
    actor: DeviceActor,
    input: { label: string; role: DeviceRole },
  ): Promise<{ device: Device; enrolCode: string }> {
    return this.tenants.runTx(() => this.createIn(actor, input));
  }

  private async createIn(
    actor: DeviceActor,
    input: { label: string; role: DeviceRole },
  ): Promise<{ device: Device; enrolCode: string }> {
    const { tenantId, manager } = currentRequestContext();
    await manager.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [
      `devices:${tenantId}`,
    ]);

    if (input.role === 'pos') {
      const live = (await manager.query(
        `SELECT id FROM devices
          WHERE tenant_id = $1::uuid AND role = 'pos' AND retired_at IS NULL
          LIMIT 1`,
        [tenantId],
      )) as { id: string }[];
      if (live.length > 0) throw posDeviceExists(live[0].id);
    }

    const next = (await manager.query(
      `SELECT COALESCE(MAX(device_no), 0) + 1 AS n FROM devices WHERE tenant_id = $1::uuid`,
      [tenantId],
    )) as { n: number }[];
    const deviceNo = Number(next[0].n);
    if (deviceNo > MAX_DEVICE_NO) {
      throw new HttpException(
        {
          code: 'DEVICE_NO_EXHAUSTED',
          message: `All ${MAX_DEVICE_NO} device numbers of this shop have been used.`,
        },
        HttpStatus.CONFLICT,
      );
    }

    // Same shape and hash as the first device `POST /platform/tenants` provisions, and what
    // `AuthService.enrolDevice` expects: 8 upper-case hex characters, SHA-256 hex at rest.
    const enrolCode = randomBytes(4).toString('hex').toUpperCase();
    const enrolCodeHash = createHash('sha256').update(enrolCode).digest('hex');

    let rows: DeviceRow[];
    try {
      rows = (await manager.query(
        `INSERT INTO devices (tenant_id, id, label, device_no, role, enrol_code_hash, enrol_expires_at)
              VALUES ($1::uuid, $2, $3, $4, $5, $6, now() + make_interval(mins => $7))
           RETURNING ${DEVICE_COLUMNS}`,
        [
          tenantId,
          newId('dv'),
          input.label,
          deviceNo,
          input.role,
          enrolCodeHash,
          ENROL_CODE_TTL_MINUTES,
        ],
      )) as DeviceRow[];
    } catch (err) {
      // The pre-check above is the answer in practice; this is the backstop for a writer
      // that does not take the advisory lock (platform provisioning, an import).
      const e = err as { code?: string; constraint?: string };
      if (e.code === UNIQUE_VIOLATION && e.constraint === 'one_pos_per_tenant') {
        throw posDeviceExists(null);
      }
      throw err;
    }
    const device = toDevice(rows[0]);

    // Never the code itself: `audit_log` is read by people who must not be able to enrol.
    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      action: 'device.create',
      entity: 'devices',
      entityId: device.id,
      after: {
        label: device.label,
        role: device.role,
        deviceNo: device.deviceNo,
        enrolExpiresAt: device.enrolExpiresAt,
      },
      ip: actor.ip,
    });

    return { device, enrolCode };
  }

  /**
   * Retires a device — ADR-0004's "ย้ายเครื่องขาย" button.
   *
   * 🔴 **One transaction, lock order devices → shifts:**
   *   1. the device row `FOR NO KEY UPDATE` — serialises two retirements of one machine and
   *      makes a concurrent `POST /shifts/open` from that machine (`FOR SHARE` on the same
   *      row) wait or be refused. `NO KEY` because `retired_at` is in no non-partial unique
   *      index, so a future foreign key to `devices` (which takes `FOR KEY SHARE`) is not
   *      blocked by a retirement;
   *   2. `ShiftsService.closeForRetirement` — the drawer row `FOR UPDATE`, which waits for
   *      any sale, void, refund or credit payment still holding it `FOR SHARE`, then closes
   *      and archives it;
   *   3. `retired_at`, and the outstanding enrolment code cleared;
   *   4. `audit_log` (`device.retire`), in the same transaction, so a failed audit rolls the
   *      retirement back.
   *
   * After the commit: `POST /auth/token` with the device token is 401 (`AuthService.login`),
   * `/auth/refresh` is 401 (ADR-0009), document numbers are refused (`DocNumberService`) and
   * a new drawer is refused (`ShiftsService.open`). An access token already issued still
   * reads for up to 15 minutes — ADR-0009 has no denylist, by decision.
   */
  retire(
    actor: DeviceActor,
    deviceId: string,
    physicalCashSatang: number | null,
    options?: RetireOptions,
  ): Promise<{ device: Device; shift: ShiftWithEntries | null }> {
    return this.tenants.runTx(() =>
      this.retireIn(actor, deviceId, physicalCashSatang, options),
    );
  }

  private async retireIn(
    actor: DeviceActor,
    deviceId: string,
    physicalCashSatang: number | null,
    options?: RetireOptions,
  ): Promise<{ device: Device; shift: ShiftWithEntries | null }> {
    const { tenantId, manager } = currentRequestContext();

    const locked = (await manager.query(
      `SELECT ${DEVICE_COLUMNS} FROM devices
        WHERE tenant_id = $1::uuid AND id = $2
          FOR NO KEY UPDATE`,
      [tenantId, deviceId],
    )) as DeviceRow[];
    if (locked.length === 0) {
      throw new HttpException(
        { code: 'DEVICE_NOT_FOUND', message: 'Device not found' },
        HttpStatus.NOT_FOUND,
      );
    }
    if (locked[0].retired_at !== null) {
      throw new HttpException(
        {
          code: 'DEVICE_ALREADY_RETIRED',
          message: 'This device is already retired.',
          details: { retiredAt: locked[0].retired_at.toISOString() },
        },
        HttpStatus.CONFLICT,
      );
    }

    if (locked[0].unsynced_ops > 0) {
      if (!options?.force) {
        throw new HttpException(
          {
            code: 'DEVICE_HAS_UNSYNCED_OPS',
            message:
              'เครื่องนี้ยังมีรายการขายค้างส่ง กรุณาเชื่อมต่อเน็ตเพื่อส่งข้อมูลก่อนปลดเครื่อง',
            details: {
              unsyncedOps: Number(locked[0].unsynced_ops),
              reportedAt: locked[0].unsynced_reported_at
                ? (locked[0].unsynced_reported_at instanceof Date
                    ? locked[0].unsynced_reported_at.toISOString()
                    : String(locked[0].unsynced_reported_at))
                : null,
            },
          },
          HttpStatus.CONFLICT,
        );
      }

      await ReviewItemsService.insertIn(manager, tenantId, {
        kind: 'device_force_retired',
        refId: deviceId,
        details: {
          deviceId,
          unsyncedOps: Number(locked[0].unsynced_ops),
          reportedAt: locked[0].unsynced_reported_at
            ? (locked[0].unsynced_reported_at instanceof Date
                ? locked[0].unsynced_reported_at.toISOString()
                : String(locked[0].unsynced_reported_at))
            : null,
          note: options.note!,
        },
      });
    }

    // Called for every role: a `backoffice` machine cannot open a drawer, so this is null
    // for it, and asking costs one indexed read rather than a rule about which roles can.
    const shift = await this.shifts.closeForRetirement(deviceId, physicalCashSatang);

    const rows = returning<DeviceRow>(
      await manager.query(
        `UPDATE devices
            SET retired_at = now(), enrol_code_hash = NULL, enrol_expires_at = NULL
          WHERE tenant_id = $1::uuid AND id = $2
      RETURNING ${DEVICE_COLUMNS}`,
        [tenantId, deviceId],
      ),
    );
    const device = toDevice(rows[0]);

    await this.audit.log(manager, {
      tenantId,
      userId: actor.userId,
      deviceId: actor.deviceId,
      action: 'device.retire',
      entity: 'devices',
      entityId: device.id,
      before: { role: device.role, deviceNo: device.deviceNo },
      after: {
        retiredAt: device.retiredAt,
        shiftId: shift?.id ?? null,
        physicalCash: shift?.physicalCash ?? null,
        ...(options?.force ? { forced: true, note: options.note } : {}),
      },
      ip: actor.ip,
    });

    return { device, shift };
  }
}

function posDeviceExists(existingId: string | null): HttpException {
  return new HttpException(
    {
      code: 'POS_DEVICE_EXISTS',
      message: 'This shop already has a pos device. Retire it before adding another.',
      ...(existingId ? { details: { deviceId: existingId } } : {}),
    },
    HttpStatus.CONFLICT,
  );
}

function toDevice(row: DeviceRow): Device {
  return {
    id: row.id,
    label: row.label,
    deviceNo: Number(row.device_no),
    role: row.role,
    retiredAt: row.retired_at ? row.retired_at.toISOString() : null,
    enrolled: row.enrolled,
    enrolExpiresAt: row.enrol_expires_at ? row.enrol_expires_at.toISOString() : null,
    lastSeenAt: row.last_seen_at ? row.last_seen_at.toISOString() : null,
    unsyncedOps: Number(row.unsynced_ops ?? 0),
    unsyncedReportedAt: row.unsynced_reported_at
      ? (row.unsynced_reported_at instanceof Date
          ? row.unsynced_reported_at.toISOString()
          : String(row.unsynced_reported_at))
      : null,
  };
}
