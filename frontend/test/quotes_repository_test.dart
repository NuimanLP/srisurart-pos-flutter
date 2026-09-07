// Unit tests for QuotesRepository — quotes NEVER touch stock.
//
// Invariants asserted (ported from pos/db.js lines 408-441):
//  • saveQuote sets quoteNo (QT…), status 'open', a validUntil ≈ now+validDays,
//    writes the quote + items, and writes NO product or sale rows.
//  • duplicateQuote produces an OPEN copy with a new id + new quoteNo, same items.
//  • purgeOldQuotes removes a long-expired quote and keeps a fresh one.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/quotes_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

void main() {
  late AppDatabase db;
  late QuotesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = QuotesRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'saveQuote sets quoteNo + open + validUntil and writes NO product/sale rows',
    () async {
      final productsBefore = (await db.select(db.products).get()).length;
      final salesBefore = (await db.select(db.sales).get()).length;

      final saved = await repo.saveQuote(
        QuoteInput(
          subtotal: 100,
          discount: 0,
          total: 100,
          customerName: 'ลูกค้า A',
          validDays: 30,
          items: const [
            QuoteLineInput(
              productId: 'p1',
              name: 'น้ำมันเครื่อง',
              qty: 2,
              price: 50,
            ),
          ],
        ),
      );

      // Header invariants.
      expect(saved.id, startsWith('q'));
      expect(saved.quoteNo, startsWith('QT'));
      expect(saved.status, 'open');

      // validUntil ≈ date + 30 days (allow 1s skew between now() calls).
      final expectedMs = saved.date.millisecondsSinceEpoch + 30 * 86400000;
      expect(
        (saved.validUntil.millisecondsSinceEpoch - expectedMs).abs() < 1000,
        isTrue,
      );

      // Quote + item persisted.
      final all = await repo.getQuotes();
      expect(all.length, 1);
      expect(all.first.items.length, 1);
      expect(all.first.items.first.name, 'น้ำมันเครื่อง');
      expect(all.first.items.first.qty, 2);

      // Quotes NEVER touch stock: no product / sale rows created.
      final productsAfter = (await db.select(db.products).get()).length;
      final salesAfter = (await db.select(db.sales).get()).length;
      expect(productsAfter, productsBefore);
      expect(salesAfter, salesBefore);
    },
  );

  test(
    'saveQuote default status is open and falls back to settings quoteValidDays',
    () async {
      final saved = await repo.saveQuote(
        const QuoteInput(
          items: [QuoteLineInput(name: 'item', qty: 1, price: 10)],
        ),
      );
      expect(saved.status, 'open');
      // Default settings quoteValidDays = 30.
      final expectedMs = saved.date.millisecondsSinceEpoch + 30 * 86400000;
      expect(
        (saved.validUntil.millisecondsSinceEpoch - expectedMs).abs() < 1000,
        isTrue,
      );
    },
  );

  test(
    'duplicateQuote produces an open copy with a new id/quoteNo, same items',
    () async {
      final original = await repo.saveQuote(
        QuoteInput(
          subtotal: 200,
          total: 200,
          status: 'converted',
          validDays: 15,
          items: const [
            QuoteLineInput(productId: 'p9', name: 'ผ้าเบรก', qty: 4, price: 50),
          ],
        ),
      );

      final dup = await repo.duplicateQuote(original.id);
      expect(dup, isNotNull);
      expect(dup!.id, isNot(original.id));
      expect(dup.quoteNo, isNot(original.quoteNo));
      expect(
        dup.status,
        'open',
      ); // forced open even though source was converted
      expect(dup.convertedAt, isNull);

      // Items copied verbatim.
      final all = await repo.getQuotes();
      final dupWithItems = all.firstWhere((q) => q.quote.id == dup.id);
      expect(dupWithItems.items.length, 1);
      expect(dupWithItems.items.first.name, 'ผ้าเบรก');
      expect(dupWithItems.items.first.qty, 4);
      expect(dupWithItems.items.first.price, 50);

      // Two quotes now exist (original + duplicate).
      expect(all.length, 2);
    },
  );

  test('duplicateQuote returns null when source is missing', () async {
    expect(await repo.duplicateQuote('does-not-exist'), isNull);
  });

  test(
    'purgeOldQuotes removes an expired-long-ago quote and keeps a fresh one',
    () async {
      // Fresh open quote (validUntil far in the future).
      final fresh = await repo.saveQuote(
        const QuoteInput(
          validDays: 30,
          items: [QuoteLineInput(name: 'fresh', qty: 1, price: 1)],
        ),
      );

      // Insert a stale open quote directly: validUntil 200 days ago.
      final staleDate = DateTime.now().subtract(const Duration(days: 230));
      final staleValidUntil = DateTime.now().subtract(
        const Duration(days: 200),
      );
      await db
          .into(db.quotes)
          .insert(
            QuoteRow(
              id: 'q_stale',
              quoteNo: 'QT_STALE',
              status: 'open',
              date: staleDate,
              validUntil: staleValidUntil,
            ),
          );
      await db
          .into(db.quoteItems)
          .insert(
            QuoteItemsCompanion.insert(
              quoteId: 'q_stale',
              name: 'stale',
              qty: 1,
              price: 1,
            ),
          );

      expect((await repo.getQuotes()).length, 2);

      final removed = await repo.purgeOldQuotes(); // default 90 days
      expect(removed, 1);

      final remaining = await repo.getQuotes();
      expect(remaining.length, 1);
      expect(remaining.first.quote.id, fresh.id);

      // Stale quote's items were removed too.
      final staleItems = await (db.select(
        db.quoteItems,
      )..where((t) => t.quoteId.equals('q_stale'))).get();
      expect(staleItems, isEmpty);
    },
  );

  test(
    'purgeOldQuotes keeps a converted quote whose convertedAt is recent',
    () async {
      final recentConverted = await repo.saveQuote(
        const QuoteInput(
          validDays: 1, // already expired by validUntil, but...
          items: [QuoteLineInput(name: 'c', qty: 1, price: 1)],
        ),
      );
      // Mark converted with a recent convertedAt so it should be KEPT despite
      // the expired validUntil (converted branch uses convertedAt||date).
      await repo.updateQuote(
        recentConverted.id,
        QuotesCompanion(
          status: const Value('converted'),
          convertedAt: Value(DateTime.now()),
          validUntil: Value(DateTime.now().subtract(const Duration(days: 500))),
        ),
      );

      final removed = await repo.purgeOldQuotes();
      expect(removed, 0);
      expect((await repo.getQuotes()).length, 1);
    },
  );

  test('deleteQuote removes the quote and its items', () async {
    final q = await repo.saveQuote(
      const QuoteInput(items: [QuoteLineInput(name: 'x', qty: 1, price: 1)]),
    );
    await repo.deleteQuote(q.id);
    expect(await repo.getQuotes(), isEmpty);
    final items = await (db.select(
      db.quoteItems,
    )..where((t) => t.quoteId.equals(q.id))).get();
    expect(items, isEmpty);
  });
}
