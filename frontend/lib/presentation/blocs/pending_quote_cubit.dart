// PendingQuoteCubit — hand-off channel from QuotesManager to the checkout
// cart. flutter_bloc port of the former Riverpod PendingQuoteNotifier
// (see docs/plans/riverpod-to-bloc.md).
//
// Holds the quote (header + items) that the checkout cart should be primed
// with, or null when there is nothing pending. CheckoutScreen reads this on
// build and clears it (`set(null)`) once the cart has consumed it.

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/models/aggregates.dart';

class PendingQuoteCubit extends Cubit<QuoteWithItems?> {
  PendingQuoteCubit() : super(null);

  /// Stage a quote for checkout to pick up.
  void set(QuoteWithItems? quote) => emit(quote);

  /// Clear the staged quote (call after the cart has consumed it).
  void clear() => emit(null);
}
