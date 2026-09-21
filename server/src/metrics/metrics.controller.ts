import { Controller, Get, Res } from '@nestjs/common';
import type { Response } from 'express';
import { MetricsService } from './metrics.service.js';

@Controller('metrics')
export class MetricsController {
  constructor(private readonly metricsService: MetricsService) {}

  /**
   * Prometheus scrape endpoint:
   * Uses `@Res()` in library mode (without `passthrough: true`) and `res.send()`
   * to bypass the `EnvelopeInterceptor` that `configureApp` registers globally, so Prometheus receives
   * raw text format instead of a JSON envelope.
   */
  @Get()
  async getMetrics(@Res() res: Response): Promise<void> {
    res.setHeader('Content-Type', this.metricsService.contentType);
    res.send(await this.metricsService.metrics());
  }
}
