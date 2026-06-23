// pendingQuoteForCartProvider — hand-off channel from QuotesManager to the
// checkout cart.
//
// In the JS app, Quote convert/edit calls `onLoad(quote)` which CheckoutScreen's
// `loadQuote` prop re-validates and drops into the cart. There is no shared cart
// notifier in the Flutter build yet, so this provider holds the most recent
// quote that QuotesScreen asked checkout to load. QuotesScreen sets it then
// navigates to `/`; the CheckoutScreen agent should read + clear it on build
// (re-validating stock, clamping qty, dropping missing items — same as the JSX
// `validateItems`). Until checkout consumes it, the value is simply parked here.
//
// Owned by the Quotes screen agent (added per CONTRACT §4: screen agents may add
// their own UI-state providers in a new file, not in the frozen providers.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/aggregates.dart';

/// Holds the quote (header + items) that the checkout cart should be primed
/// with, or null when there is nothing pending. CheckoutScreen reads this on
/// build and clears it (`set(null)`) once the cart has been loaded.
class PendingQuoteNotifier extends Notifier<QuoteWithItems?> {
  @override
  QuoteWithItems? build() => null;

  /// Stage a quote for checkout to pick up.
  void set(QuoteWithItems? quote) => state = quote;

  /// Clear the staged quote (call after the cart has consumed it).
  void clear() => state = null;
}

final pendingQuoteForCartProvider =
    NotifierProvider<PendingQuoteNotifier, QuoteWithItems?>(
        PendingQuoteNotifier.new);
