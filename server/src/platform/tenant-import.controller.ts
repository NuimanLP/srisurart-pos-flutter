import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { PlatformAuthGuard } from './platform-auth.guard.js';
import { clientIp } from '../common/client-ip.js';
import { ParseUuidPipe } from '../common/parse-uuid.pipe.js';
import { zipUploadOf } from '../backup/zip-upload.js';
import {
  SnapshotPayload,
  TenantImportService,
} from './tenant-import.service.js';

interface AuthenticatedRequest extends Request {
  platformAdmin: {
    id: string;
    username: string;
  };
}

@Controller('platform/tenants')
@UseGuards(PlatformAuthGuard)
export class TenantImportController {
  constructor(private readonly importService: TenantImportService) {}

  // #239: pre-flight runs here, synchronously, so a bad file still answers 400/409 right
  // away; the write itself is a BullMQ job (`TenantImportProcessor`) — see
  // `tenant-import.service.ts`'s block comment for why a synchronous request stopped being
  // safe (nginx's 30 s `proxy_read_timeout` vs. ~6.4 s per 2 MiB locally, growing with a
  // shop's history).
  @Post(':id/import')
  @HttpCode(HttpStatus.ACCEPTED)
  async importSnapshot(
    @Param('id') id: string,
    @Body() body: SnapshotPayload,
    @Req() req: AuthenticatedRequest,
  ) {
    const ip = clientIp(req) ?? undefined;
    // Legacy JSON in `body`, or the backup ZIP streamed to disk by `app.setup.ts` (contract §4).
    return this.importService.createJob(id, body, req.platformAdmin.id, ip, zipUploadOf(req));
  }

  @Get(':id/import/:jobId')
  async getImportJob(@Param('id') id: string, @Param('jobId', ParseUuidPipe) jobId: string) {
    return this.importService.getJob(id, jobId);
  }
}
