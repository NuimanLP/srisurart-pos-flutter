import { Injectable, type ArgumentMetadata, type PipeTransform } from '@nestjs/common';
import { parseUuid } from './ids.js';

/**
 * `@Param('id', ParseUuidPipe)` → `400 INVALID_ID` before the handler runs (#616).
 * Not Nest's own `ParseUUIDPipe`: that one accepts uppercase and throws without a `code`.
 */
@Injectable()
export class ParseUuidPipe implements PipeTransform<unknown, string> {
  transform(value: unknown, metadata: ArgumentMetadata): string {
    return parseUuid(value, metadata.data ?? 'id');
  }
}
