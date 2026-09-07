import {
  Injectable,
  type CallHandler,
  type ExecutionContext,
  type NestInterceptor,
} from '@nestjs/common';
import { map, type Observable } from 'rxjs';

/** Success envelope per 02_API_SCREENS.md §1.2: { status: 'success', data }. */
@Injectable()
export class EnvelopeInterceptor implements NestInterceptor {
  intercept(_ctx: ExecutionContext, next: CallHandler): Observable<unknown> {
    return next.handle().pipe(map((data) => ({ status: 'success', data })));
  }
}
