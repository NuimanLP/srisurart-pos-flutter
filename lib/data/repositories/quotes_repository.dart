// QuotesRepository — quotes / estimates (sa_quotes + sa_quote_items).
//
// Port of pos/db.js lines 408-441. Quotes NEVER touch stock — these methods
// only read/write the Quotes + QuoteItems tables.
//
// db.js methods ported:
//  • getQuotes()             → all quotes newest-first (with items).
//  • saveQuote(QuoteInput)   → id newId('q'), quoteNo docNo('QT'), date now,
//    status (default 'open'), validUntil = now + (validDays ?? quoteValidDays ?? 30)
//    days. Returns the persisted QuoteRow.
//  • updateQuote(id, patch)  → merge patch.
//  • duplicateQuote(id)      → deep-copy items, status 'open', fresh id/quoteNo/
//    date/validUntil, convertedAt stripped. Returns the new QuoteRow (null if
//    source missing).
//  • purgeOldQuotes(olderThanDays=90) → drop converted quotes older than cutoff
//    (by convertedAt||date) and expired quotes (validUntil) older than cutoff;
//    returns count purged.
//  • deleteQuote(id)         → remove quote (and its items).

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';
import '../../domain/models/aggregates.dart';

class QuotesRepository {
  final AppDatabase db;
  QuotesRepository(this.db);

  static const int _dayMs = 86400000;

  /// All quotes newest-first (db.js prepends new quotes → order by date desc),
  /// each paired with its line items.
  Future<List<QuoteWithItems>> getQuotes() async {
    final quotes = await (db.select(db.quotes)
          ..orderBy([(t) => OrderingTerm.desc(t.date)]))
        .get();
    final result = <QuoteWithItems>[];
    for (final q in quotes) {
      final items = await (db.select(db.quoteItems)
            ..where((t) => t.quoteId.equals(q.id)))
          .get();
      result.add(QuoteWithItems(q, items));
    }
    return result;
  }

  /// Persist a new quote. Assigns id (newId('q')), quoteNo (docNo('QT')),
  /// date = now, status (input.status ?? 'open') and
  /// validUntil = now + (validDays ?? settings.quoteValidDays ?? 30) days.
  /// Inserts the header + every item line. Returns the stored QuoteRow.
  Future<QuoteRow> saveQuote(QuoteInput input) async {
    final now = DateTime.now();
    final int validDays = input.validDays ?? await _defaultValidDays();
    final row = QuoteRow(
      id: newId('q'),
      quoteNo: docNo('QT'),
      status: input.status ?? 'open',
      date: now,
      validUntil: DateTime.fromMillisecondsSinceEpoch(
        now.millisecondsSinceEpoch + validDays * _dayMs,
      ),
      convertedAt: null,
      subtotal: input.subtotal,
      discount: input.discount,
      total: input.total,
      customerName: input.customerName,
      customerPhone: input.customerPhone,
      notes: input.notes,
      validDays: input.validDays,
    );
    await db.transaction(() async {
      await db.into(db.quotes).insert(row);
      for (final it in input.items) {
        await db.into(db.quoteItems).insert(
              QuoteItemsCompanion.insert(
                quoteId: row.id,
                productId: Value(it.productId),
                name: it.name,
                qty: it.qty,
                price: it.price,
              ),
            );
      }
    });
    return row;
  }

  /// Merge [patch] into an existing quote (db.js spreads `{ ...x, ...patch }`).
  Future<void> updateQuote(String id, QuotesCompanion patch) async {
    await (db.update(db.quotes)..where((t) => t.id.equals(id))).write(patch);
  }

  /// Deep-copy a quote into a fresh open quote: copies items + header fields but
  /// strips id/quoteNo/status/convertedAt/date/validUntil and forces status
  /// 'open' (db.js destructures those out then re-saveQuote). Returns the new
  /// QuoteRow, or null if the source quote does not exist.
  Future<QuoteRow?> duplicateQuote(String id) async {
    final src = await (db.select(db.quotes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (src == null) return null;
    final items = await (db.select(db.quoteItems)
          ..where((t) => t.quoteId.equals(id)))
        .get();
    return saveQuote(
      QuoteInput(
        subtotal: src.subtotal,
        discount: src.discount,
        total: src.total,
        customerName: src.customerName,
        customerPhone: src.customerPhone,
        notes: src.notes,
        validDays: src.validDays,
        status: 'open',
        items: items
            .map((it) => QuoteLineInput(
                  productId: it.productId,
                  name: it.name,
                  qty: it.qty,
                  price: it.price,
                ))
            .toList(),
      ),
    );
  }

  /// Purge converted quotes whose (convertedAt ?? date) is older than the cutoff
  /// and open/expired quotes whose validUntil is older than the cutoff.
  /// Mirrors db.js: keep converted if (convertedAt||date) > cutoff, otherwise
  /// keep if validUntil > cutoff. Returns the number of quotes removed.
  Future<int> purgeOldQuotes({int olderThanDays = 90}) async {
    final cutoffMs = DateTime.now().millisecondsSinceEpoch - olderThanDays * _dayMs;
    final all = await db.select(db.quotes).get();
    int removed = 0;
    await db.transaction(() async {
      for (final q in all) {
        final bool keep;
        if (q.status == 'converted') {
          final ref = q.convertedAt ?? q.date;
          keep = ref.millisecondsSinceEpoch > cutoffMs;
        } else {
          keep = q.validUntil.millisecondsSinceEpoch > cutoffMs;
        }
        if (!keep) {
          await _deleteQuoteInTx(q.id);
          removed++;
        }
      }
    });
    return removed;
  }

  /// Remove a quote and its line items.
  Future<void> deleteQuote(String id) async {
    await db.transaction(() async {
      await _deleteQuoteInTx(id);
    });
  }

  Future<void> _deleteQuoteInTx(String id) async {
    await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(id))).go();
    await (db.delete(db.quotes)..where((t) => t.id.equals(id))).go();
  }

  /// settings.quoteValidDays (defaults to 30 when no settings row exists).
  Future<int> _defaultValidDays() async {
    final s = await (db.select(db.settingsRow)..where((t) => t.id.equals(0)))
        .getSingleOrNull();
    return s?.quoteValidDays ?? 30;
  }
}
