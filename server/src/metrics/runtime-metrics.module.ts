import { Module } from '@nestjs/common';
import { MetricsModule } from './metrics.module.js';
import { RuntimeMetricsService } from './runtime-metrics.service.js';

/** API process only: needs `DB_POOL_STATS` (the global DbModule) and the queues (QueueModule). */
@Module({
  imports: [MetricsModule],
  providers: [RuntimeMetricsService],
})
export class RuntimeMetricsModule {}
