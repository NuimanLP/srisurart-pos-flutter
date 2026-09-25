import {
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  NotFoundException,
  Param,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { InjectQueue } from '@nestjs/bullmq';
import { Job, Queue } from 'bullmq';
import { open } from 'node:fs/promises';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { authorisedTenantId } from '../common/request-context.js';
import { newId } from '../common/ids.js';
import { clientIp } from '../common/client-ip.js';
import {
  DEFAULT_JOB_OPTIONS,
  JOB_TENANT_EXPORT,
  QUEUE_BACKUP,
  type TenantExportJobPayload,
} from '../queue/queue.constants.js';
import { exportFilePath, type ExportDescriptor } from './export-file.js';

interface AuthenticatedRequest extends Request {
  user?: {
    userId?: string;
    tenantId?: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

/**
 * No handler here opens a transaction: none touches Postgres. Only the tenant the guard
 * authorised is needed (`authorisedTenantId()`), and holding a pooled connection across a
 * Redis round trip — as the old `runTx` wrappers did on every status poll — just starves
 * the pool.
 */
@Controller('backup')
@UseGuards(TenantGuard)
export class BackupController {
  constructor(@InjectQueue(QUEUE_BACKUP) private readonly backupQueue: Queue) {}

  @Post('export')
  @HttpCode(HttpStatus.ACCEPTED)
  async exportTenantData(@Req() req: AuthenticatedRequest) {
    if (!req.user?.deviceId) {
      throw new DeviceRoleForbiddenException();
    }

    const payload: TenantExportJobPayload = {
      tenantId: authorisedTenantId(),
      correlationId: newId('export_'),
      requestedByUserId: req.user?.userId ?? '',
      ip: clientIp(req) ?? undefined,
    };

    const job = await this.backupQueue.add(
      JOB_TENANT_EXPORT,
      payload,
      DEFAULT_JOB_OPTIONS,
    );

    return {
      jobId: job.id,
      status: 'queued',
    };
  }

  /**
   * Status only. The snapshot itself is never inline: it is served by `…/download` below,
   * streamed from the file the worker wrote. `data`/`result` carry the small descriptor.
   */
  @Get('jobs/:id')
  async getJobStatus(@Req() req: AuthenticatedRequest, @Param('id') id: string) {
    const job = await this.ownJob(req, id);
    const state = await job.getState();
    const descriptor = exportDescriptor(job.returnvalue);
    const resultData = descriptor
      ? { ...descriptor, downloadPath: `/api/v1/backup/jobs/${job.id}/download` }
      : null;

    return {
      id: job.id,
      status: state,
      state,
      progress: job.progress,
      data: resultData,
      result: resultData,
      error: job.failedReason ?? null,
    };
  }

  /**
   * Streams the finished export (`sa_*` + `__meta` JSON). The file path comes from the
   * authorised tenant and the job's own id — never from the request — and the job must
   * belong to that tenant, so one shop can never read another's file. 404 once the job or
   * its file has expired (`EXPORT_TTL_MS`). Library-mode `@Res()`: the envelope interceptor
   * must not wrap a file body.
   */
  @Get('jobs/:id/download')
  async downloadExport(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Res() res: Response,
  ): Promise<void> {
    const job = await this.ownJob(req, id);
    const descriptor = exportDescriptor(job.returnvalue);
    if (!descriptor || (await job.getState()) !== 'completed') {
      throw notFound('Export not ready');
    }

    // Open first, then stat the handle: a prune racing between the two cannot hand us a
    // path that no longer exists.
    let fh;
    try {
      fh = await open(exportFilePath(job.data.tenantId, String(job.id)), 'r');
    } catch {
      throw notFound('Export expired');
    }
    let size: number;
    try {
      ({ size } = await fh.stat());
    } catch (err) {
      await fh.close();
      throw err;
    }
    res.status(HttpStatus.OK);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Content-Length', String(size));
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="backup-${descriptor.exportedAt.slice(0, 10)}.json"`,
    );
    res.setHeader('Cache-Control', 'no-store');
    const stream = fh.createReadStream();
    stream.on('error', () => res.destroy());
    // A client that disconnects mid-download must not leave the file handle open.
    res.on('close', () => stream.destroy());
    stream.pipe(res);
  }

  /** The job, if it exists and belongs to the authorised tenant; 404 otherwise. */
  private async ownJob(
    req: AuthenticatedRequest,
    id: string,
  ): Promise<Job<TenantExportJobPayload>> {
    if (!req.user?.deviceId) {
      throw new DeviceRoleForbiddenException();
    }
    const tenantId = authorisedTenantId();
    const job = (await this.backupQueue.getJob(id)) as
      | Job<TenantExportJobPayload>
      | undefined;
    if (!job || job.data?.tenantId !== tenantId) {
      throw notFound('Job not found');
    }
    return job;
  }
}

function notFound(message: string): NotFoundException {
  return new NotFoundException({ code: 'NOT_FOUND', message });
}

/** `TenantJobRunner` wraps the processor's return as `{ skipped, result }`. */
function exportDescriptor(raw: unknown): ExportDescriptor | null {
  const result =
    raw && typeof raw === 'object' && 'result' in raw
      ? (raw as { result: unknown }).result
      : raw;
  return result && typeof result === 'object' && 'sha256' in result
    ? (result as ExportDescriptor)
    : null;
}
