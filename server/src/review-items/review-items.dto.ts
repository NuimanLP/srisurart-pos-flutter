import { BadRequestException } from '@nestjs/common';

export type ReviewItemKind =
  | 'void_offline'
  | 'credit_override'
  | 'shift_uncounted'
  | 'date_flag'
  | 'device_force_retired';

export const REVIEW_ITEM_KINDS: readonly ReviewItemKind[] = [
  'void_offline',
  'credit_override',
  'shift_uncounted',
  'date_flag',
  'device_force_retired',
] as const;

export type ReviewItemStatus = 'pending' | 'reviewed' | 'all';

export interface ReviewItem {
  id: string;
  kind: ReviewItemKind;
  refId: string;
  details: Record<string, unknown>;
  createdAt: string;
  reviewedAt: string | null;
  reviewedBy: string | null;
}

export function parseReviewItemStatus(
  raw?: string,
): ReviewItemStatus {
  if (!raw || raw === 'pending') return 'pending';
  if (raw === 'reviewed') return 'reviewed';
  if (raw === 'all') return 'all';
  throw new BadRequestException('status must be one of: pending, reviewed, all');
}
