import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpException,
  HttpStatus,
  Param,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import type { JwtVerifier } from '../auth/jwt-keys.service.js';
import { clientIp } from '../common/client-ip.js';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { parseUuid } from '../common/ids.js';
import { authorisedTenantId } from '../common/request-context.js';
import { zipUploadOf } from './zip-upload.js';
import {
  SnapshotPayload,
  TenantImportService,
} from '../platform/tenant-import.service.js';

/** `POST /backup/import` as Express sees it under the global prefix (`app.setup.ts`). */
export const OWNER_IMPORT_ROUTE = '/api/v1/backup/import';

interface AuthenticatedRequest extends Request {
  user?: { userId?: string; role?: string; deviceId?: string };
}

/**
 * The shop owner imports a backup file into their own, still-empty shop (Settings →
 * กู้คืนข้อมูล). The same `TenantImportService` the platform route uses — same pre-flight
 * (empty shop only, UUID ids only, …), same one-job-at-a-time index, same worker — with the
 * tenant taken from `TenantGuard`, never from the request.
 *
 * Owner role AND an enrolled device, like the export and device retire (08 phase 2: retire /
 * enrol / export need an enrolled device token).
 *
 * No `Idempotency-Key` claim, like `POST /platform/tenants/:id/import` and `POST /backup/export`:
 * a claim opens a `pos_app` transaction (`runIdempotent`), while the import's pre-flight and
 * insert run on `ADMIN_DATA_SOURCE` — two pool connections in one request (#162). A resent
 * request is refused anyway: 409 while the first job is queued/running
 * (`uq_import_jobs_active`), 409 once it has written bills (the empty-shop check).
 *
 * No handler opens a `runTx`: none touches the tenant's own tables through `pos_app`.
 */
@Controller('backup/import')
@UseGuards(TenantGuard)
export class OwnerImportController {
  constructor(private readonly importService: TenantImportService) {}

  /**
   * `?mode=replace&confirmShopName=<the shop's name>` replaces a shop that already has data
   * (owner decision 2026-10-07): the worker copies the current data to a file, deletes it and
   * writes the snapshot, in one transaction. Without it a shop with bills is still refused 409.
   * `?jobId=<uuid>` lets the client name the job, so a lost reply is found by polling it.
   *
   * The file is the legacy JSON (`application/json`, ≤ 10 MiB, parsed into `body`) or the
   * backup ZIP (`application/zip`, ≤ 200 MB, streamed to disk by `app.setup.ts` — contract §4).
   */
  @Post()
  @HttpCode(HttpStatus.ACCEPTED)
  async importSnapshot(
    @Body() body: SnapshotPayload,
    @Req() req: AuthenticatedRequest,
    @Query('mode') mode?: string,
    @Query('confirmShopName') confirmShopName?: string,
    @Query('jobId') jobId?: string,
  ) {
    const zipFile = zipUploadOf(req);
    let userId: string;
    let requestedJobId: string | undefined;
    try {
      userId = requireOwnerDevice(req);
      if (mode !== undefined && mode !== 'replace') {
        throw new BadRequestException(`mode must be 'replace' or absent`);
      }
      requestedJobId = jobId === undefined ? undefined : parseUuid(jobId, 'jobId');
    } catch (err) {
      await this.importService.discardUpload(zipFile);
      throw err;
    }
    return this.importService.createOwnerJob(
      authorisedTenantId(),
      body,
      userId,
      clientIp(req) ?? undefined,
      mode === 'replace' ? { confirmShopName: confirmShopName ?? '' } : undefined,
      requestedJobId,
      zipFile,
    );
  }

  @Get(':jobId')
  async getImportJob(
    @Param('jobId', ParseUuidPipe) jobId: string,
    @Req() req: AuthenticatedRequest,
  ) {
    requireOwnerDevice(req);
    return this.importService.getJob(authorisedTenantId(), jobId);
  }
}

function requireOwnerDevice(req: AuthenticatedRequest): string {
  if (req.user?.role !== 'owner' || !req.user.userId) {
    throw new HttpException(
      { code: 'FORBIDDEN', message: 'Only the shop owner may import a backup' },
      HttpStatus.FORBIDDEN,
    );
  }
  if (!req.user.deviceId) {
    throw new DeviceRoleForbiddenException();
  }
  return req.user.userId;
}

/**
 * `app.setup.ts`: only a request this predicate accepts earns the 10 MiB body parser on
 * {@link OWNER_IMPORT_ROUTE} — a verified tenant access token of an owner on an enrolled
 * device, the same claims `requireOwnerDevice` checks after `TenantGuard`. Anyone else falls
 * through to Nest's 100 KiB parser, so nobody may make the API buffer 10 MiB unauthenticated.
 */
export function ownerImportTokenFromHeader(header: unknown, verifier: JwtVerifier): boolean {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  try {
    const p = verifier.verify(header.substring(7), 'access');
    return p.aud === 'tenant' && p.role === 'owner' && !!p.tid && !!p.did;
  } catch {
    return false;
  }
}
