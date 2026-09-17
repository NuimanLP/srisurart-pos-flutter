// ApiQuotesRepository — write-through cache implementation of QuotesRepository.
//
// Complies with ADR-0010:
//  • Server issues QT numbers (ADR-0007) and validates quote conversions/purges.
//  • Quotes do not touch stock or the cash drawer until converted into sales.
//  • Writes results through to Drift immediately.

import 'package:drift/drift.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/aggregates.dart';
import '../db/database.dart';
import 'api/api_wire.dart';
import 'quotes_repository.dart';

class ApiQuotesRepository extends QuotesRepository {
  final ApiClient apiClient;

  ApiQuotesRepository(super.db, this.apiClient);

  Future<void> syncFromServer() async {
    try {
      bool hasMore = true;
      int page = 1;

      while (hasMore) {
        final res = await apiClient.getPaginated(
          '/api/v1/quotes',
          queryParameters: {'page': page, 'limit': 100},
        );
        final items = res.data;

        if (items.isNotEmpty) {
          for (final item in items) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final qId = map['id'] as String;
              final quoteNo = (map['quoteNo'] ?? map['quote_no'] ?? '') as String;
              final customerName = (map['customerName'] ?? map['customer']) as String?;
              final customerPhone = (map['customerPhone'] ?? map['customer_phone']) as String?;
              final date = stampOrNull(map['date']) ?? DateTime.now();
              final validUntil = stampOrNull(map['validUntil'] ?? map['valid_until']) ?? date.add(const Duration(days: 30));
              final total = money(map['total']);
              final status = (map['status'] ?? 'open') as String;
              final convertedAt = stampOrNull(map['convertedAt'] ?? map['converted_at']);
              final notes = (map['notes'] ?? map['note']) as String?;

              final quoteRow = QuoteRow(
                id: qId,
                quoteNo: quoteNo,
                status: status,
                date: date,
                validUntil: validUntil,
                convertedAt: convertedAt,
                subtotal: map['subtotal'] != null ? money(map['subtotal']) : null,
                discount: map['discount'] != null ? money(map['discount']) : null,
                total: total,
                customerName: customerName,
                customerPhone: customerPhone,
                notes: notes,
                validDays: (map['validDays'] as num?)?.toInt(),
              );

              await db.into(db.quotes).insertOnConflictUpdate(quoteRow);

              final qItems = map['items'];
              if (qItems is List) {
                await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(qId))).go();
                for (final line in qItems) {
                  if (line is Map) {
                    final lineMap = Map<String, dynamic>.from(line);
                    final productId = lineMap['productId'] as String?;
                    final name = (lineMap['name'] ?? '') as String;
                    final qty = (lineMap['qty'] as num?)?.toInt() ?? 0;
                    final price = money(lineMap['price']);

                    await db.into(db.quoteItems).insert(
                          QuoteItemsCompanion.insert(
                            quoteId: qId,
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

        if (page >= res.totalPages || items.isEmpty) {
          hasMore = false;
        } else {
          page++;
        }
      }
    } catch (_) {
      // Network failure or degraded mode: gracefully ignore and rely on Drift cache
    }
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
        'subtotal': wireMoney(input.subtotal ?? 0),
        'discount': wireMoney(input.discount ?? 0),
        'total': wireMoney(input.total ?? 0),
        if (input.customerName != null) 'customerName': input.customerName,
        if (input.customerPhone != null) 'customerPhone': input.customerPhone,
        if (input.notes != null) 'notes': input.notes,
        if (input.validDays != null) 'validDays': input.validDays,
        'items': input.items
            .map((i) => {
                  if (i.productId != null) 'productId': i.productId,
                  'name': i.name,
                  'qty': i.qty,
                  'price': wireMoney(i.price),
                })
            .toList(),
      };

      final res = await apiClient.post('/api/v1/quotes', body: body, headers: idempotencyKey());
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final realId = (resMap['id'] ?? newId('q')) as String;
        final quoteNo = (resMap['quoteNo'] ?? resMap['quote_no'] ?? docNo('QT')) as String;
        final date = stampOrNull(resMap['date']) ?? DateTime.now();
        final validUntil = stampOrNull(resMap['validUntil'] ?? resMap['valid_until']) ??
            date.add(Duration(days: input.validDays ?? 30));
        final total = money(resMap['total'] ?? input.total);
        final status = (resMap['status'] ?? 'open') as String;

        final quoteRow = QuoteRow(
          id: realId,
          quoteNo: quoteNo,
          status: status,
          date: date,
          validUntil: validUntil,
          convertedAt: null,
          subtotal: resMap['subtotal'] != null ? money(resMap['subtotal']) : input.subtotal,
          discount: resMap['discount'] != null ? money(resMap['discount']) : input.discount,
          total: total,
          customerName: (resMap['customerName'] ?? input.customerName) as String?,
          customerPhone: (resMap['customerPhone'] ?? input.customerPhone) as String?,
          notes: (resMap['notes'] ?? input.notes) as String?,
          validDays: (resMap['validDays'] as num?)?.toInt() ?? input.validDays,
        );

        await db.into(db.quotes).insertOnConflictUpdate(quoteRow);
        await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(realId))).go();

        final rawItems = resMap['items'];
        if (rawItems is List && rawItems.isNotEmpty) {
          for (final line in rawItems) {
            if (line is Map) {
              final lineMap = Map<String, dynamic>.from(line);
              await db.into(db.quoteItems).insert(
                    QuoteItemsCompanion.insert(
                      quoteId: realId,
                      productId: Value(lineMap['productId'] as String?),
                      name: (lineMap['name'] ?? '') as String,
                      qty: (lineMap['qty'] as num?)?.toInt() ?? 1,
                      price: money(lineMap['price']),
                    ),
                  );
            }
          }
        } else {
          for (final item in input.items) {
            await db.into(db.quoteItems).insert(
                  QuoteItemsCompanion.insert(
                    quoteId: realId,
                    productId: Value(item.productId),
                    name: item.name,
                    qty: item.qty,
                    price: item.price,
                  ),
                );
          }
        }

        return quoteRow;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {
      // Offline fallback
    }

    return super.saveQuote(input);
  }

  @override
  Future<void> deleteQuote(String id) async {
    try {
      await apiClient.delete('/api/v1/quotes/$id', headers: idempotencyKey());
      await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(id))).go();
      await (db.delete(db.quotes)..where((t) => t.id.equals(id))).go();
      return;
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.deleteQuote(id);
  }

  @override
  Future<void> updateQuote(String id, QuotesCompanion patch) async {
    try {
      if (patch.status.present && patch.status.value == 'converted') {
        final res = await apiClient.post('/api/v1/quotes/$id/convert', headers: idempotencyKey());
        if (res is Map) {
          final resMap = Map<String, dynamic>.from(res);
          final status = (resMap['status'] ?? 'converted') as String;
          final convertedAt = stampOrNull(resMap['convertedAt'] ?? resMap['converted_at']) ?? DateTime.now();
          await (db.update(db.quotes)..where((t) => t.id.equals(id))).write(
            QuotesCompanion(
              status: Value(status),
              convertedAt: Value(convertedAt),
            ),
          );
          return;
        }
      }

      final body = <String, dynamic>{};
      if (patch.customerName.present) body['customerName'] = patch.customerName.value;
      if (patch.customerPhone.present) body['customerPhone'] = patch.customerPhone.value;
      if (patch.notes.present) body['notes'] = patch.notes.value;

      if (body.isNotEmpty) {
        final res = await apiClient.patch('/api/v1/quotes/$id', body: body, headers: idempotencyKey());
        if (res is Map) {
          await db.into(db.quotes).insertOnConflictUpdate(patch.copyWith(id: Value(id)));
          return;
        }
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    await super.updateQuote(id, patch);
  }

  @override
  Future<QuoteRow?> duplicateQuote(String id) async {
    try {
      final res = await apiClient.post('/api/v1/quotes/$id/duplicate', headers: idempotencyKey());
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        final newIdStr = (resMap['id'] ?? newId('q')) as String;
        final newQuoteNo = (resMap['quoteNo'] ?? resMap['quote_no'] ?? docNo('QT')) as String;
        final date = stampOrNull(resMap['date']) ?? DateTime.now();
        final validUntil = stampOrNull(resMap['validUntil'] ?? resMap['valid_until']) ?? date.add(const Duration(days: 30));
        final customerName = (resMap['customerName'] ?? resMap['customer']) as String?;
        final customerPhone = (resMap['customerPhone'] ?? resMap['customer_phone']) as String?;
        final total = money(resMap['total']);
        final status = (resMap['status'] ?? 'open') as String;
        final notes = (resMap['notes'] ?? resMap['note']) as String?;

        final newRow = QuoteRow(
          id: newIdStr,
          quoteNo: newQuoteNo,
          status: status,
          date: date,
          validUntil: validUntil,
          convertedAt: null,
          subtotal: resMap['subtotal'] != null ? money(resMap['subtotal']) : null,
          discount: resMap['discount'] != null ? money(resMap['discount']) : null,
          total: total,
          customerName: customerName,
          customerPhone: customerPhone,
          notes: notes,
          validDays: (resMap['validDays'] as num?)?.toInt(),
        );
        await db.into(db.quotes).insertOnConflictUpdate(newRow);

        final items = resMap['items'];
        if (items is List && items.isNotEmpty) {
          await (db.delete(db.quoteItems)..where((t) => t.quoteId.equals(newIdStr))).go();
          for (final line in items) {
            if (line is Map) {
              final lineMap = Map<String, dynamic>.from(line);
              await db.into(db.quoteItems).insert(
                    QuoteItemsCompanion.insert(
                      quoteId: newIdStr,
                      productId: Value(lineMap['productId'] as String?),
                      name: (lineMap['name'] ?? '') as String,
                      qty: (lineMap['qty'] as num?)?.toInt() ?? 1,
                      price: money(lineMap['price']),
                    ),
                  );
            }
          }
        } else {
          // If items not returned in server body, copy from local source
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
        }
        return newRow;
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    return super.duplicateQuote(id);
  }

  @override
  Future<int> purgeOldQuotes({int olderThanDays = 90}) async {
    try {
      final res = await apiClient.post('/api/v1/quotes/purge', body: {'olderThanDays': olderThanDays}, headers: idempotencyKey());
      if (res is Map) {
        final resMap = Map<String, dynamic>.from(res);
        if (resMap['queued'] == true || resMap['count'] != null) {
          // Also clean local Drift
          return await super.purgeOldQuotes(olderThanDays: olderThanDays);
        }
      }
    } on ApiException catch (e) {
      rethrowServerRefusal(e);
    } on ApiTimeoutException {
      // The server may have committed: never re-run the write on Drift (#183).
      rethrow;
    } catch (_) {}

    return super.purgeOldQuotes(olderThanDays: olderThanDays);
  }
}
