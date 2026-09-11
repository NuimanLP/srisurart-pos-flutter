import {
  Injectable,
  type CallHandler,
  type ExecutionContext,
  type NestInterceptor,
} from '@nestjs/common';
import { map, type Observable } from 'rxjs';
import { Paginated } from './paginated.js';

/**
 * Success envelope per 02_API_SCREENS.md §1.2: `{ status: 'success', data }`, plus
 * `meta` when the handler returned a `Paginated` page — §1.2 puts `total`, `page`,
 * `limit` and `totalPages` beside `data`, not inside it.
 */
@Injectable()
export class EnvelopeInterceptor implements NestInterceptor {
  intercept(_ctx: ExecutionContext, next: CallHandler): Observable<unknown> {
    return next
      .handle()
      .pipe(
        map((data) =>
          data instanceof Paginated
            ? { status: 'success', data: data.items, meta: data.meta }
            : { status: 'success', data },
        ),
      );
  }
}
