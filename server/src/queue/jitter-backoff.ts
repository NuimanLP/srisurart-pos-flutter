/**
 * Exponential backoff with full jitter strategy for BullMQ.
 *
 * Course deck omits jitter; without it, failed jobs collide on retries.
 * Delay formula: delay = min(maxDelay, baseDelay * 2^(attemptsMade - 1))
 * Jittered delay: uniform random in [0, delay].
 */
export function calculateJitterBackoff(
  attemptsMade: number,
  baseDelay = 1000,
  maxDelay = 30000,
  randomFn: () => number = Math.random,
): number {
  if (attemptsMade <= 0) return 0;
  const exponent = Math.min(20, attemptsMade - 1);
  const maxForAttempt = Math.min(maxDelay, baseDelay * Math.pow(2, exponent));
  return Math.floor(randomFn() * maxForAttempt);
}

export const JITTER_BACKOFF_STRATEGY = {
  'exponential-jitter': (attemptsMade: number): number => {
    return calculateJitterBackoff(attemptsMade);
  },
};
