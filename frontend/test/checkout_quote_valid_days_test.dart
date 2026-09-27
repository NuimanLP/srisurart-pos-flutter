// #464 regression: CheckoutScreen's "ใบเสนอราคา" (save quote) button must pass
// the shop's configured settings.quoteValidDays into QuoteInput.validDays.
//
// Before the fix, `_handleSaveQuote` built a `QuoteInput` with no `validDays`
// at all, so `QuotesRepository.saveQuote`'s own `validDays ?? 30` fallback
// (which exists for db.js/API parity, never to read settings itself — see
// `quotes_repository.dart`) silently applied 30 days regardless of what the
// shop configured in ตั้งค่า → "ใบเสนอราคา · มีอายุ (วัน)".
//
// Harness mirrors checkout_credit_override_test.dart: a real in-memory Drift
// DB via repositoryProviders(db), with QuotesRepository swapped for a
// capturing fake so the exact QuoteInput the screen built is inspectable.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/checkout_screen.dart';

/// Records the `QuoteInput` the screen built, then delegates to the real
/// (Drift-backed) `saveQuote` so the screen's normal success path — including
/// its post-await `ScaffoldMessenger` snackbar — completes without needing a
/// try/catch this screen (unlike `_handleCheckout`) does not have.
class _CapturingQuotes extends QuotesRepository {
  _CapturingQuotes(super.db);

  final List<QuoteInput> inputs = [];
  QuoteInput? get captured => inputs.isEmpty ? null : inputs.last;

  @override
  Future<QuoteRow> saveQuote(QuoteInput input) async {
    inputs.add(input);
    return super.saveQuote(input);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
    'saving a quote passes settings.quoteValidDays, not the 30-day default',
    (tester) async {
      // Tall enough that the whole checkout column lays out in one pass —
      // matches checkout_credit_override_test.dart's viewport.
      tester.view.physicalSize = const Size(1800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final quotes = _CapturingQuotes(db);
      final cartCubit = CartCubit();
      final pendingQuoteCubit = PendingQuoteCubit();
      addTearDown(cartCubit.close);
      addTearDown(pendingQuoteCubit.close);

      await tester.runAsync(() async {
        // A non-default validity, so this test cannot pass by coincidence
        // with the hardcoded 30-day fallback.
        await (db.update(
          db.settingsRow,
        )..where((t) => t.id.equals(0))).write(
          const SettingsRowCompanion(quoteValidDays: Value(45)),
        );

        final p = (await ProductsRepository(db).getAll()).firstWhere(
          (x) => x.stock >= 1,
        );
        expect(
          cartCubit.add(p),
          isNull,
          reason: 'the seeded product has stock',
        );

        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: repositoryProviders(db),
            child: RepositoryProvider<QuotesRepository>.value(
              value: quotes,
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<PendingQuoteCubit>.value(
                    value: pendingQuoteCubit,
                  ),
                  BlocProvider<CartCubit>.value(value: cartCubit),
                ],
                child: const MaterialApp(
                  home: Scaffold(body: CheckoutScreen()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        await tester.tap(find.widgetWithText(OutlinedButton, 'ใบเสนอราคา'));
        await tester.pumpAndSettle();

        expect(
          quotes.captured,
          isNotNull,
          reason: 'saveQuote was never called',
        );
        expect(quotes.captured!.validDays, 45);
      });
    },
  );
}
