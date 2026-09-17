import {
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  NotFoundException,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { DeviceRoleForbiddenException } from '../common/device-role-forbidden.exception.js';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import { currentRequestContext } from '../common/request-context.js';
import { TenantService } from '../common/database/tenant.service.js';
import { newId } from '../common/ids.js';
import { clientIp } from '../common/client-ip.js';
import {
  DEFAULT_JOB_OPTIONS,
  JOB_TENANT_EXPORT,
  QUEUE_BACKUP,
  type TenantExportJobPayload,
} from '../queue/queue.constants.js';

interface AuthenticatedRequest extends Request {
  user?: {
    userId?: string;
    tenantId?: string;
    role?: string;
    deviceId?: string;
    deviceRole?: string;
  };
}

@Controller('backup')
@UseGuards(TenantGuard)
export class BackupController {
  constructor(
    @InjectQueue(QUEUE_BACKUP) private readonly backupQueue: Queue,
    private readonly tenants: TenantService,
  ) {}

  @Post('export')
  @HttpCode(HttpStatus.ACCEPTED)
  exportTenantData(@Req() req: AuthenticatedRequest) {
    return this.tenants.runTx(() => this.exportTenantDataIn(req));
  }

  private async exportTenantDataIn(req: AuthenticatedRequest) {
    if (!req.user?.deviceId) {
      throw new DeviceRoleForbiddenException();
    }

    const { tenantId } = currentRequestContext();
    const correlationId = newId('export_');
    const ip = clientIp(req) ?? undefined;

    const payload: TenantExportJobPayload = {
      tenantId,
      correlationId,
      requestedByUserId: req.user?.userId ?? '',
      ip,
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

  @Get('jobs/:id')
  getJobStatus(@Req() req: AuthenticatedRequest, @Param('id') id: string) {
    return this.tenants.runTx(() => this.getJobStatusIn(req, id));
  }

  private async getJobStatusIn(req: AuthenticatedRequest, id: string) {
    if (!req.user?.deviceId) {
      throw new DeviceRoleForbiddenException();
    }

    const { tenantId } = currentRequestContext();
    const job = await this.backupQueue.getJob(id);

    if (!job || job.data?.tenantId !== tenantId) {
      throw new NotFoundException({
        code: 'NOT_FOUND',
        message: 'Job not found',
      });
    }

    const state = await job.getState();
    const rawResult = job.returnvalue;
    const resultData =
      rawResult && typeof rawResult === 'object' && 'result' in rawResult
        ? (rawResult as { result: unknown }).result
        : rawResult ?? null;

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
}
