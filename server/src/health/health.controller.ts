import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { HealthService } from './health.service.js';

@Controller('health')
export class HealthController {
  constructor(private readonly health: HealthService) {}

  /** Liveness: touches nothing. A DB outage must not restart every instance. */
  @Get('live')
  live() {
    return { status: 'up' };
  }

  /** Readiness: Postgres + both Redis. 503 NOT_READY if any is down. */
  @Get('ready')
  async ready() {
    const checks = await this.health.readiness();
    if (Object.values(checks).some((c) => c === 'down')) {
      throw new HttpException(
        {
          code: 'NOT_READY',
          message: 'Dependency unavailable',
          details: checks,
        },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    return { status: 'up', checks };
  }
}
