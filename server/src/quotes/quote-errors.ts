import { HttpException, HttpStatus } from '@nestjs/common';

/** The refusals a quote can answer with — shared by the quote routes and `POST /sales` (#27). */

export function quoteNotFound(): HttpException {
  return new HttpException(
    { code: 'QUOTE_NOT_FOUND', message: 'Quote not found' },
    HttpStatus.NOT_FOUND,
  );
}

export function quoteAlreadyConverted(
  convertedSaleId: string | null,
): HttpException {
  return new HttpException(
    {
      code: 'QUOTE_ALREADY_CONVERTED',
      message: 'Quote has already been converted into a sale.',
      details: { convertedSaleId },
    },
    HttpStatus.CONFLICT,
  );
}

export function quoteExpired(validUntil: Date): HttpException {
  return new HttpException(
    {
      code: 'QUOTE_EXPIRED',
      message: 'Quote has expired and cannot be converted.',
      details: { validUntil: validUntil.toISOString() },
    },
    HttpStatus.CONFLICT,
  );
}

/** Owner, 2026-10-03 (#27 Q2): a converted quote is the record a bill was sold from. */
export function quoteConvertedNotDeletable(
  convertedSaleId: string | null,
): HttpException {
  return new HttpException(
    {
      code: 'QUOTE_CONVERTED_NOT_DELETABLE',
      message: 'A converted quote cannot be deleted.',
      details: { convertedSaleId },
    },
    HttpStatus.CONFLICT,
  );
}
