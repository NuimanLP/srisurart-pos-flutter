// ApiQuotesRepository — write-through cache implementation of QuotesRepository.
//
// Complies with ADR-0010:
//  • Server is authority on quotes and expiration dates.
//  • Quotes NEVER touch stock (pure document persistence).
//  • Writes results through to Drift immediately; offline fallback preserved.

import '../../core/network/api_exception.dart';
import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import 'quotes_repository.dart';

class ApiQuotesRepository extends QuotesRepository {
  final ApiClient apiClient;

  ApiQuotesRepository(super.db, this.apiClient);

  Future<void> syncFromServer() async {
    try {
      final res = await apiClient.get('/api/v1/quotes');
      if (res is List) {
        for (final item in res) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final quoteId = map['id'] as String;
            final quoteNo = (map['quoteNo'] ?? map['quote_no'] ?? '') as String;
            final dateStr = map['date'] ?? map['createdAt'] ?? map['created_at'];
            final date = dateStr != null
                ? DateTime.tryParse(dateStr.toString()) ?? DateTime.now()
                : DateTime.now();
            final validUntilStr = map['validUntil'] ?? map['valid_until'];
            final validUntil = validUntilStr != null
                ? DateTime.tryParse(validUntilStr.toString()) ?? date.add(const Duration(days: 30))
                : date.add(const Duration(days: 30));
            final status = (map['status'] ?? 'open') as String;
            final customerName = (map['customerName'] ?? map['customer_name']) as String?;
            final customerPhone = (map['customerPhone'] ?? map['customer_phone']) as String?;
            final notes = map['notes'] as String?;

            double parseNum(dynamic val) {
              if (val is num) return val.toDouble();
              if (val is String) return double.tryParse(val) ?? 0.0;
              return 0.0;
            }

            final subtotal = parseNum(map['subtotal']);
            final discount = parseNum(map['discount']);
            final total = parseNum(map['total']);

            DateTime? convertedAt;
            final convertedAtStr = map['convertedAt'] ?? map['converted_at'];
            if (convertedAtStr != null) {
              convertedAt = DateTime.tryParse(convertedAtStr.toString());
            }

            await db.into(db.quotes).insert(
                  QuotesCompanion(
                    id: Value(quoteId),
                    quoteNo: Value(quoteNo),
                    date: Value(date),
                    validUntil: Value(validUntil),
                    status: Value(status),
                    customerName: Value(customerName),
                    customerPhone: Value(customerPhone),
                    notes: Value(notes),
                    subtotal: Value(subtotal),
                    discount: Value(discount),
                    total: Value(total),
                    convertedAt: Value(convertedAt),
                  ),
                  onConflict: DoUpdate((old) => QuotesCompanion(
                        status: Value(status),
                        convertedAt: Value(convertedAt),
                      )),
                );

            final items = item['items'];
            if (items is List) {
              await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(quoteId))).go();
              for (final line in items) {
                if (line is Map) {
                  final lineMap = Map<String, dynamic>.from(line);
                  final productId = (lineMap['productId'] ?? lineMap['product_id']) as String?;
                  final name = (lineMap['name'] ?? '') as String;
                  final qty = (lineMap['qty'] as num?)?.toInt() ?? 0;
                  final price = parseNum(lineMap['price']);

                  await db.into(db.quoteItems).insert(
                        QuoteItemsCompanion.insert(
                          quoteId: quoteId,
                          productId: Value(productId),
                          name: name,
                          qty: qty,
                          price: price,
                        ),
                      );
                }
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  @override
  Future<List<QuoteWithItems>> getQuotes() async {
    await syncFromServer();
    return super.getQuotes();
  }

  @override
  Future<QuoteRow> saveQuote(QuoteInput input) async {
    try {
      final body = {
        'customerName': input.customerName,
        'customerPhone': input.customerPhone,
        'notes': input.notes,
        'validDays': input.validDays ?? 30,
        'status': input.status ?? 'open',
        'subtotal': input.subtotal?.toStringAsFixed(2),
        'discount': input.discount?.toStringAsFixed(2) ?? '0.00',
        'total': input.total?.toStringAsFixed(2),
        'items': input.items
            .map((item) => {
                  'productId': item.productId,
                  'name': item.name,
                  'qty': item.qty,
                  'price': item.price.toStringAsFixed(2),
                })
            .toList(),
      };

      final res = await apiClient.post('/api/v1/quotes', body: body);
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final quoteId = (resMap['id'] ?? newId('q')) as String;
        final quoteNo = (resMap['quoteNo'] ?? resMap['quote_no'] ?? docNo('QT')) as String;
        final now = DateTime.now();
        final validDays = input.validDays ?? 30;
        final validUntil = now.add(Duration(days: validDays));

        final row = QuoteRow(
          id: quoteId,
          quoteNo: quoteNo,
          date: now,
          validUntil: validUntil,
          status: input.status ?? 'open',
          customerName: input.customerName,
          customerPhone: input.customerPhone,
          notes: input.notes,
          subtotal: input.subtotal ?? 0,
          discount: input.discount ?? 0,
          total: input.total ?? 0,
        );

        await db.into(db.quotes).insertOnConflictUpdate(row);

        for (final item in input.items) {
          await db.into(db.quoteItems).insert(
                QuoteItemsCompanion.insert(
                  quoteId: quoteId,
                  productId: Value(item.productId),
                  name: item.name,
                  qty: item.qty,
                  price: item.price,
                ),
              );
        }

        return row;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {
      // Offline fallback
    }

    return super.saveQuote(input);
  }

  @override
  Future<void> updateQuote(String id, QuotesCompanion patch) async {
    try {
      final body = <String, dynamic>{};
      if (patch.customerName.present) body['customerName'] = patch.customerName.value;
      if (patch.customerPhone.present) body['customerPhone'] = patch.customerPhone.value;
      if (patch.notes.present) body['notes'] = patch.notes.value;
      if (patch.status.present) body['status'] = patch.status.value;

      await apiClient.patch('/api/v1/quotes/$id', body: body);
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {}

    await super.updateQuote(id, patch);
  }

  @override
  Future<QuoteRow?> duplicateQuote(String id) async {
    try {
      final res = await apiClient.post('/api/v1/quotes/$id/duplicate');
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final newIdStr = (resMap['id'] ?? newId('q')) as String;
        final newQuoteNo = (resMap['quoteNo'] ?? resMap['quote_no'] ?? docNo('QT')) as String;
        final now = DateTime.now();

        final source = await (db.select(db.quotes)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (source != null) {
          final newRow = source.copyWith(
            id: newIdStr,
            quoteNo: newQuoteNo,
            date: now,
            validUntil: now.add(const Duration(days: 30)),
            status: 'open',
          );
          await db.into(db.quotes).insertOnConflictUpdate(newRow);

          final sourceItems = await (db.select(db.quoteItems)..where((t) => t.quoteId.equals(id))).get();
          for (final item in sourceItems) {
            await db.into(db.quoteItems).insert(
                  QuoteItemsCompanion.insert(
                    quoteId: newIdStr,
                    productId: Value(item.productId),
                    name: item.name,
                    qty: item.qty,
                    price: item.price,
                  ),
                );
          }
          return newRow;
        }
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {}

    return super.duplicateQuote(id);
  }

  @override
  Future<int> purgeOldQuotes({int olderThanDays = 90}) async {
    try {
      final res = await apiClient.post('/api/v1/quotes/purge', body: {'olderThanDays': olderThanDays});
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        if (resMap['count'] != null) {
          // Also clean local Drift
          await super.purgeOldQuotes(olderThanDays: olderThanDays);
          return (resMap['count'] as num).toInt();
        }
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {}

    return super.purgeOldQuotes(olderThanDays: olderThanDays);
  }

  @override
  Future<void> deleteQuote(String id) async {
    try {
      await apiClient.delete('/api/v1/quotes/$id');
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } catch (_) {}

    await super.deleteQuote(id);
  }
}
