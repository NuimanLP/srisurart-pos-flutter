import { Module } from '@nestjs/common';
import { DocNumberService } from './doc-number.service.js';

/** Import wherever a document is written: sales, returns, POs, quotes, credit payments. */
@Module({
  providers: [DocNumberService],
  exports: [DocNumberService],
})
export class DocumentsModule {}
