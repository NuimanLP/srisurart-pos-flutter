import { Module } from '@nestjs/common';
import { DocCountersController } from './doc-counters.controller.js';
import { DocCountersService } from './doc-counters.service.js';
import { DocNumberService } from './doc-number.service.js';

/** Import wherever a document is written: sales, returns, POs, quotes, credit payments. */
@Module({
  // `GET /doc-counters` (#188) — the pos device's seed for its phase-2 counter.
  controllers: [DocCountersController],
  providers: [DocNumberService, DocCountersService],
  exports: [DocNumberService],
})
export class DocumentsModule {}
