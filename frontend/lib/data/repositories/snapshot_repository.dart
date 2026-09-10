// SnapshotRepository — backup / restore (db.js exportSnapshot / importSnapshot).
//
// Implementation owned by the **Snapshot service agent**.
//
// db.js methods ported (lines 596-672):
//  • exportSnapshot() → Map<String,dynamic> collecting EVERY store keyed by the
//    db.js sa_* key names (sa_products, sa_customers, …) plus sa_schema_version
//    (raw string) and a __meta block { version: BACKUP_FORMAT_VERSION (2),
//    schemaVersion, exportedAt, shopName, recordCounts:{…} }. This is the file
//    shape so a Flutter export can be restored by the legacy JS app and vice versa.
//  • importLegacyBackup(Map) → ATOMIC restore (mirrors saveSale): run inside
//    db.transaction(...), wiping + repopulating every table the file carries;
//    validate __meta is present (throw 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta'
//    when missing); treat a null store value as absent. Rolls back on any throw.
//    Any UNKNOWN sa_* store the file carries (added by a newer app version that
//    this build has no table for) is stashed verbatim in AppMeta under
//    [unknownStorePrefix] and re-emitted on the next export, matching db.js's
//    "carry every sa_* key the file holds" forward-compat guarantee.
//
// SHAPE NOTES (db.js → JS backup file → Drift):
//  • Each sale nests its items[] array (SaleItems rows) like the JS sale objects.
//    Same for sa_pos (PoItems), sa_quotes (QuoteItems), sa_returns (ReturnItems).
//  • sa_categories is an ARRAY OF NAMES ordered by position (CategoryRow.position).
//  • sa_cash_drawer is the single ACTIVE shift object (isActive == true) with an
//    entries[] array (DrawerEntries), or null if no active shift.
//  • sa_shift_history is the array of all OTHER (inactive) shift objects.
//  • sa_parked is an array of decoded parked-bill payload objects.
//  • Dates that db.js held as ISO strings are emitted as ISO strings on export
//    and parsed back to DateTime on import.

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/utils/ids.dart';
import '../db/database.dart';

class SnapshotRepository {
  final AppDatabase db;
  SnapshotRepository(this.db);

  // db.js BACKUP_FORMAT_VERSION (file-format version, NOT the schema counter).
  static const int backupFormatVersion = 2;

  // Every `sa_*` store this build has a hand-written import/export branch for
  // (mirrors db.js KNOWN = DB_KEYS_ALL + BACKUP_META_KEYS). Any `sa_*` key in a
  // backup file that is NOT in this set is an unknown store from a newer app
  // version: db.js carries it forward verbatim, so we persist it too (R-forwardcompat)
  // instead of silently dropping it. Stashed in AppMeta under [unknownStorePrefix].
  static const Set<String> _knownStoreKeys = {
    'sa_products',
    'sa_customers',
    'sa_sales',
    'sa_pos',
    'sa_settings',
    'sa_mechanics',
    'sa_quotes',
    'sa_returns',
    'sa_movements',
    'sa_suppliers',
    'sa_categories',
    'sa_credit_payments',
    'sa_cash_drawer',
    'sa_shift_history',
    'sa_parked',
    'sa_schema_version',
  };

  // AppMeta key namespace for carried-forward unknown `sa_*` stores. The raw
  // file value is stored JSON-encoded under '<prefix><sa_key>' so an export can
  // re-emit it unchanged and a newer-version backup round-trips without loss.
  // No '_' in the prefix on purpose — it's used in a SQL LIKE where '_' is a
  // single-char wildcard, and we want a literal-prefix match.
  static const String unknownStorePrefix = 'unknownstore:';

  // ── helpers ────────────────────────────────────────────────────────────────

  /// ISO-8601 string for a DateTime (matches JS `new Date().toISOString()`),
  /// or null when the source is null.
  static String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

  /// Parse an ISO/date value coming from a legacy backup file into a DateTime.
  /// Returns null for null/empty. Tolerates both ISO strings and millis ints.
  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) {
      if (v.isEmpty) return null;
      return DateTime.tryParse(v);
    }
    return null;
  }

  static int _asInt(dynamic v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static double _asDouble(dynamic v, [double fallback = 0]) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static String _asStr(dynamic v, [String fallback = '']) =>
      v == null ? fallback : v.toString();

  static String? _asNullableStr(dynamic v) => v?.toString();

  /// Null-preserving double — distinguishes "absent" from 0, which matters for
  /// costAtSale (ADR-0008: a missing cost is unknown, not free).
  static double? _asNullableDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return false;
  }

  // ── EXPORT ───────────────────────────────────────────────────────────────

  /// Collects every store into one JSON-safe map with a __meta block.
  /// Keyed by the db.js sa_* key names for cross-compatibility with the JS app.
  Future<Map<String, dynamic>> exportSnapshot() async {
    // ── products (sa_products) ──
    final productRows = await db.select(db.products).get();
    final products = productRows
        .map(
          (p) => <String, dynamic>{
            'id': p.id,
            'partNo': p.partNo,
            'name': p.name,
            'nameTH': p.nameTH,
            'category': p.category,
            'brand': p.brand,
            'price': p.price,
            'cost': p.cost,
            'stock': p.stock,
            'minStock': p.minStock,
            if (p.compat != null) 'compat': p.compat,
            if (p.zone != null) 'zone': p.zone,
            if (p.updatedAt != null) 'updatedAt': _iso(p.updatedAt),
          },
        )
        .toList();

    // ── customers (sa_customers) ──
    final customerRows = await db.select(db.customers).get();
    final customers = customerRows
        .map(
          (c) => <String, dynamic>{
            'id': c.id,
            'code': c.code,
            'name': c.name,
            'nameTH': c.nameTH,
            if (c.phone != null) 'phone': c.phone,
            if (c.address != null) 'address': c.address,
            'points': c.points,
            'totalSpend': c.totalSpend,
            'createdAt': c.createdAt,
            if (c.updatedAt != null) 'updatedAt': _iso(c.updatedAt),
            if (c.deletedAt != null) 'deletedAt': _iso(c.deletedAt),
          },
        )
        .toList();

    // ── sales (sa_sales) with nested items[] ──
    final saleRows = await (db.select(
      db.sales,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final saleItemRows = await db.select(db.saleItems).get();
    final saleItemsBySale = <String, List<SaleItemRow>>{};
    for (final it in saleItemRows) {
      (saleItemsBySale[it.saleId] ??= []).add(it);
    }
    final sales = saleRows
        .map(
          (s) => <String, dynamic>{
            'id': s.id,
            'receiptNo': s.receiptNo,
            'subtotal': s.subtotal,
            'discount': s.discount,
            'total': s.total,
            'paymentMethod': s.paymentMethod,
            if (s.customerId != null) 'customerId': s.customerId,
            if (s.customerName != null) 'customerName': s.customerName,
            if (s.mechanicId != null) 'mechanicId': s.mechanicId,
            if (s.mechanicName != null) 'mechanicName': s.mechanicName,
            if (s.mechanicDelta != null) 'mechanicDelta': s.mechanicDelta,
            'pointsGranted': s.pointsGranted,
            'date': _iso(s.date),
            'voided': s.voided,
            if (s.voidedAt != null) 'voidedAt': _iso(s.voidedAt),
            'items': (saleItemsBySale[s.id] ?? const [])
                .map(
                  (it) => <String, dynamic>{
                    'productId': it.productId,
                    if (it.partNo != null) 'partNo': it.partNo,
                    'name': it.name,
                    if (it.nameTH != null) 'nameTH': it.nameTH,
                    'qty': it.qty,
                    'price': it.price,
                    // JS backups carried `cost` on the line; keep the round-trip
                    // lossless so historical profit survives export/import.
                    if (it.costAtSale != null) 'cost': it.costAtSale,
                  },
                )
                .toList(),
          },
        )
        .toList();

    // ── purchase orders (sa_pos) with nested items[] ──
    final poRows = await (db.select(
      db.purchaseOrders,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
    final poItemRows = await db.select(db.poItems).get();
    final poItemsByPo = <String, List<PoItemRow>>{};
    for (final it in poItemRows) {
      (poItemsByPo[it.poId] ??= []).add(it);
    }
    final purchaseOrders = poRows
        .map(
          (po) => <String, dynamic>{
            'id': po.id,
            'poNo': po.poNo,
            'supplier': po.supplier,
            'status': po.status,
            'createdAt': _iso(po.createdAt),
            if (po.receivedAt != null) 'receivedAt': _iso(po.receivedAt),
            if (po.cancelledAt != null) 'cancelledAt': _iso(po.cancelledAt),
            'items': (poItemsByPo[po.id] ?? const [])
                .map(
                  (it) => <String, dynamic>{
                    'partNo': it.partNo,
                    'name': it.name,
                    'qty': it.qty,
                    'cost': it.cost,
                  },
                )
                .toList(),
          },
        )
        .toList();

    // ── settings (sa_settings) as a single object ──
    final settingsData = await (db.select(
      db.settingsRow,
    )..where((t) => t.id.equals(0))).getSingleOrNull();
    final Map<String, dynamic>? settings = settingsData == null
        ? null
        : <String, dynamic>{
            'shopName': settingsData.shopName,
            'shopNameEN': settingsData.shopNameEN,
            'taxRate': settingsData.taxRate,
            'quoteValidDays': settingsData.quoteValidDays,
            if (settingsData.address != null) 'address': settingsData.address,
            if (settingsData.phone != null) 'phone': settingsData.phone,
            if (settingsData.cashierName != null)
              'cashierName': settingsData.cashierName,
            if (settingsData.taxId != null) 'taxId': settingsData.taxId,
            if (settingsData.branchNo != null)
              'branchNo': settingsData.branchNo,
            if (settingsData.updatedAt != null)
              'updatedAt': _iso(settingsData.updatedAt),
          };

    // ── mechanics (sa_mechanics) ──
    final mechanicRows = await db.select(db.mechanics).get();
    final mechanics = mechanicRows
        .map(
          (m) => <String, dynamic>{
            'id': m.id,
            'code': m.code,
            'name': m.name,
            if (m.nameTH != null) 'nameTH': m.nameTH,
            if (m.nickname != null) 'nickname': m.nickname,
            if (m.shopName != null) 'shopName': m.shopName,
            if (m.phone != null) 'phone': m.phone,
            if (m.note != null) 'note': m.note,
            'creditLimit': m.creditLimit,
            'creditBalance': m.creditBalance,
            'totalSales': m.totalSales,
            'totalCredit': m.totalCredit,
            'totalDiscount': m.totalDiscount,
            'totalMarkup': m.totalMarkup,
            'createdAt': m.createdAt,
            if (m.updatedAt != null) 'updatedAt': _iso(m.updatedAt),
            if (m.deletedAt != null) 'deletedAt': _iso(m.deletedAt),
          },
        )
        .toList();

    // ── quotes (sa_quotes) with nested items[] ──
    final quoteRows = await (db.select(
      db.quotes,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final quoteItemRows = await db.select(db.quoteItems).get();
    final quoteItemsByQuote = <String, List<QuoteItemRow>>{};
    for (final it in quoteItemRows) {
      (quoteItemsByQuote[it.quoteId] ??= []).add(it);
    }
    final quotes = quoteRows
        .map(
          (q) => <String, dynamic>{
            'id': q.id,
            'quoteNo': q.quoteNo,
            'status': q.status,
            'date': _iso(q.date),
            'validUntil': _iso(q.validUntil),
            if (q.convertedAt != null) 'convertedAt': _iso(q.convertedAt),
            if (q.subtotal != null) 'subtotal': q.subtotal,
            if (q.discount != null) 'discount': q.discount,
            if (q.total != null) 'total': q.total,
            if (q.customerName != null) 'customerName': q.customerName,
            if (q.customerPhone != null) 'customerPhone': q.customerPhone,
            if (q.notes != null) 'notes': q.notes,
            if (q.validDays != null) 'validDays': q.validDays,
            'items': (quoteItemsByQuote[q.id] ?? const [])
                .map(
                  (it) => <String, dynamic>{
                    if (it.productId != null) 'productId': it.productId,
                    'name': it.name,
                    'qty': it.qty,
                    'price': it.price,
                  },
                )
                .toList(),
          },
        )
        .toList();

    // ── returns (sa_returns) with nested items[] ──
    final returnRows = await (db.select(
      db.returns,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final returnItemRows = await db.select(db.returnItems).get();
    final returnItemsByReturn = <String, List<ReturnItemRow>>{};
    for (final it in returnItemRows) {
      (returnItemsByReturn[it.returnId] ??= []).add(it);
    }
    final returns = returnRows
        .map(
          (r) => <String, dynamic>{
            'id': r.id,
            'cnNo': r.cnNo,
            'saleId': r.saleId,
            'receiptNo': r.receiptNo,
            'refundSubtotal': r.refundSubtotal,
            'refundDiscount': r.refundDiscount,
            'refundTotal': r.refundTotal,
            'refundMethod': r.refundMethod,
            'reason': r.reason,
            if (r.customerId != null) 'customerId': r.customerId,
            if (r.mechanicId != null) 'mechanicId': r.mechanicId,
            if (r.mechanicName != null) 'mechanicName': r.mechanicName,
            'date': _iso(r.date),
            'items': (returnItemsByReturn[r.id] ?? const [])
                .map(
                  (it) => <String, dynamic>{
                    'productId': it.productId,
                    'name': it.name,
                    'qty': it.qty,
                    'price': it.price,
                    if (it.originalQty != null) 'originalQty': it.originalQty,
                  },
                )
                .toList(),
          },
        )
        .toList();

    // ── movements (sa_movements) ──
    final movementRows = await (db.select(
      db.movements,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final movements = movementRows
        .map(
          (m) => <String, dynamic>{
            'id': m.id,
            'productId': m.productId,
            'partNo': m.partNo,
            'name': m.name,
            'delta': m.delta,
            'type': m.type,
            if (m.note != null) 'note': m.note,
            'stockAfter': m.stockAfter,
            'date': _iso(m.date),
          },
        )
        .toList();

    // ── suppliers (sa_suppliers) ──
    final supplierRows = await db.select(db.suppliers).get();
    final suppliers = supplierRows
        .map(
          (s) => <String, dynamic>{
            'id': s.id,
            'productId': s.productId,
            'name': s.name,
            'unitCost': s.unitCost,
            'freight': s.freight,
          },
        )
        .toList();

    // ── categories (sa_categories) — array of names ordered by position ──
    final categoryRows = await (db.select(
      db.categories,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();
    final categories = categoryRows.map((c) => c.name).toList();

    // ── credit payments (sa_credit_payments) ──
    final cpRows = await (db.select(
      db.creditPayments,
    )..orderBy([(t) => OrderingTerm.desc(t.date)])).get();
    final creditPayments = cpRows
        .map(
          (p) => <String, dynamic>{
            'id': p.id,
            'receiptNo': p.receiptNo,
            'mechanicId': p.mechanicId,
            'amount': p.amount,
            'date': _iso(p.date),
            if (p.note != null) 'note': p.note,
          },
        )
        .toList();

    // ── shifts: active → sa_cash_drawer object; rest → sa_shift_history array ──
    final shiftRows = await db.select(db.shifts).get();
    final entryRows = await db.select(db.drawerEntries).get();
    final entriesByShift = <String, List<DrawerEntryRow>>{};
    for (final e in entryRows) {
      (entriesByShift[e.shiftId] ??= []).add(e);
    }
    Map<String, dynamic> shiftToJson(ShiftRow s) {
      final entries =
          (entriesByShift[s.id] ?? const <DrawerEntryRow>[]).toList()..sort(
            (a, b) => b.createdAt.compareTo(a.createdAt),
          ); // newest first
      return <String, dynamic>{
        'date': s.dateStr,
        'startingCash': s.startingCash,
        'openedAt': _iso(s.openedAt),
        'closedAt': _iso(s.closedAt),
        'physicalCash': s.physicalCash,
        if (s.autoArchived) 'autoArchived': true,
        if (s.archivedAt != null) 'archivedAt': _iso(s.archivedAt),
        'entries': entries
            .map(
              (e) => <String, dynamic>{
                'id': e.id,
                'type': e.type,
                'amount': e.amount,
                'note': e.note ?? '',
                'createdAt': _iso(e.createdAt),
              },
            )
            .toList(),
      };
    }

    Map<String, dynamic>? cashDrawer;
    final history = <Map<String, dynamic>>[];
    // Active shift is the single isActive == true row (sa_cash_drawer);
    // every other shift goes to sa_shift_history (newest openedAt first).
    final inactive = shiftRows.where((s) => !s.isActive).toList()
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    for (final s in shiftRows) {
      if (s.isActive && cashDrawer == null) {
        cashDrawer = shiftToJson(s);
      }
    }
    for (final s in inactive) {
      history.add(shiftToJson(s));
    }

    // ── parked (sa_parked) — array of decoded payload objects ──
    final parkedRows = await (db.select(
      db.parkedSales,
    )..orderBy([(t) => OrderingTerm.desc(t.parkedAt)])).get();
    final parked = parkedRows.map((p) {
      try {
        final decoded = jsonDecode(p.payload);
        if (decoded is Map<String, dynamic>) return decoded;
        return <String, dynamic>{
          'id': p.id,
          'parkedAt': _iso(p.parkedAt),
          'payload': decoded,
        };
      } catch (_) {
        return <String, dynamic>{
          'id': p.id,
          'parkedAt': _iso(p.parkedAt),
          'payload': p.payload,
        };
      }
    }).toList();

    // ── schema version (raw string, from AppMeta 'schema_version') ──
    final schemaMeta = await (db.select(
      db.appMeta,
    )..where((t) => t.key.equals('schema_version'))).getSingleOrNull();
    final schemaVersionStr = schemaMeta?.value ?? '2';
    final schemaVersionInt = int.tryParse(schemaVersionStr) ?? 1;

    // ── assemble file, mirroring db.js shape ──
    final data = <String, dynamic>{
      'sa_products': products,
      'sa_customers': customers,
      'sa_sales': sales,
      'sa_pos': purchaseOrders,
      'sa_settings': ?settings,
      'sa_mechanics': mechanics,
      'sa_quotes': quotes,
      'sa_returns': returns,
      'sa_movements': movements,
      'sa_suppliers': suppliers,
      'sa_categories': categories,
      'sa_credit_payments': creditPayments,
      // db.js writes sa_cash_drawer only when an active shift exists; null/absent
      // otherwise. We emit the key with null so recordCounts.cashDrawer reads 0.
      'sa_cash_drawer': cashDrawer,
      'sa_shift_history': history,
      'sa_parked': parked,
      // raw string, never JSON-parsed (BACKUP_META_KEYS in db.js)
      'sa_schema_version': schemaVersionStr,
    };

    // ── carried-forward unknown sa_* stores (from a newer-version backup) ──
    // Re-emit any unknown store stashed in AppMeta on a prior import, so the
    // round-trip matches db.js's "carry EVERY sa_* key the file holds" guarantee.
    // Only fills keys not already produced above (typed tables win).
    final unknownMeta = await (db.select(
      db.appMeta,
    )..where((t) => t.key.like('$unknownStorePrefix%'))).get();
    for (final row in unknownMeta) {
      final saKey = row.key.substring(unknownStorePrefix.length);
      if (saKey.isEmpty || data.containsKey(saKey)) continue;
      try {
        data[saKey] = jsonDecode(row.value);
      } catch (_) {
        // Unparseable blob: emit the raw string rather than drop the store.
        data[saKey] = row.value;
      }
    }

    // ── recordCounts (db.js labels) ──
    final recordCounts = <String, int>{
      'products': products.length,
      'customers': customers.length,
      'sales': sales.length,
      'purchaseOrders': purchaseOrders.length,
      'movements': movements.length,
      'suppliers': suppliers.length,
      'mechanics': mechanics.length,
      'quotes': quotes.length,
      'returns': returns.length,
      'creditPayments': creditPayments.length,
      'shiftHistory': history.length,
      'parked': parked.length,
      'categories': categories.length,
      'cashDrawer': cashDrawer != null ? 1 : 0,
    };

    data['__meta'] = <String, dynamic>{
      'version': backupFormatVersion,
      'schemaVersion': schemaVersionInt,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'shopName': settings?['shopName'] ?? 'ศรีสุราษฎร์เจริญยนต์',
      'recordCounts': recordCounts,
    };

    return data;
  }

  // ── IMPORT ───────────────────────────────────────────────────────────────

  /// Atomic restore from a legacy/JS-shaped backup map. Throws the Thai
  /// 'ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta' error when __meta is missing.
  ///
  /// Mirrors db.js importSnapshot: a single Drift transaction wipes the known
  /// tables and repopulates from each sa_* array. A thrown error inside the
  /// transaction rolls everything back (the idiomatic snapshot/rollback).
  /// A null / absent store value is treated as "skip" (never as data).
  Future<void> importLegacyBackup(Map<String, dynamic> data) async {
    if (data['__meta'] == null) {
      throw Exception('ไฟล์สำรองไม่ถูกต้อง — ไม่พบข้อมูล __meta');
    }

    List<Map<String, dynamic>> asList(dynamic v) {
      if (v == null) return const [];
      if (v is List) {
        return v
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
      return const [];
    }

    // Legacy zone → category migration map (matches db.js getProducts()).
    const zoneMap = {
      'Engine': 'เครื่องยนต์',
      'Electrical': 'ไฟฟ้า',
      'Oils': 'น้ำมัน',
      'Brakes': 'เบรก',
      'Body': 'ตัวถัง',
    };

    await db.transaction(() async {
      // ── 1. Wipe known tables (children before parents for FK refs) ──
      await db.delete(db.saleItems).go();
      await db.delete(db.poItems).go();
      await db.delete(db.quoteItems).go();
      await db.delete(db.returnItems).go();
      await db.delete(db.drawerEntries).go();
      await db.delete(db.sales).go();
      await db.delete(db.purchaseOrders).go();
      await db.delete(db.quotes).go();
      await db.delete(db.returns).go();
      await db.delete(db.shifts).go();
      await db.delete(db.products).go();
      await db.delete(db.customers).go();
      await db.delete(db.mechanics).go();
      await db.delete(db.movements).go();
      await db.delete(db.suppliers).go();
      await db.delete(db.categories).go();
      await db.delete(db.creditPayments).go();
      await db.delete(db.parkedSales).go();

      // ── 2. Products (zone → category migration) ──
      for (final p in asList(data['sa_products'])) {
        final category = p['category'] != null
            ? _asStr(p['category'])
            : (zoneMap[_asStr(p['zone'])] ??
                  (p['zone'] != null ? _asStr(p['zone']) : 'เครื่องยนต์'));
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: _asStr(p['id']),
                partNo: _asStr(p['partNo']),
                name: _asStr(p['name']),
                nameTH: _asStr(p['nameTH']),
                category: category,
                brand: _asStr(p['brand']),
                price: _asDouble(p['price']),
                cost: _asDouble(p['cost']),
                stock: _asInt(p['stock']),
                minStock: _asInt(p['minStock']),
                compat: Value(_asNullableStr(p['compat'])),
                updatedAt: Value(_parseDate(p['updatedAt'])),
              ),
            );
      }

      // ── 3. Customers ──
      for (final c in asList(data['sa_customers'])) {
        await db
            .into(db.customers)
            .insert(
              CustomersCompanion.insert(
                id: _asStr(c['id']),
                code: _asStr(c['code']),
                name: _asStr(c['name']),
                nameTH: _asStr(c['nameTH']),
                phone: Value(_asNullableStr(c['phone'])),
                address: Value(_asNullableStr(c['address'])),
                points: Value(_asInt(c['points'])),
                totalSpend: Value(_asDouble(c['totalSpend'])),
                createdAt: _asStr(c['createdAt']),
                updatedAt: Value(_parseDate(c['updatedAt'])),
                deletedAt: Value(_parseDate(c['deletedAt'])),
              ),
            );
      }

      // ── 4. Mechanics ──
      for (final m in asList(data['sa_mechanics'])) {
        await db
            .into(db.mechanics)
            .insert(
              MechanicsCompanion.insert(
                id: _asStr(m['id']),
                code: _asStr(m['code']),
                name: _asStr(m['name']),
                nameTH: Value(_asNullableStr(m['nameTH'])),
                nickname: Value(_asNullableStr(m['nickname'])),
                shopName: Value(_asNullableStr(m['shopName'])),
                phone: Value(_asNullableStr(m['phone'])),
                note: Value(_asNullableStr(m['note'])),
                creditLimit: Value(_asDouble(m['creditLimit'])),
                creditBalance: Value(_asDouble(m['creditBalance'])),
                totalSales: Value(_asDouble(m['totalSales'])),
                totalCredit: Value(_asDouble(m['totalCredit'])),
                totalDiscount: Value(_asDouble(m['totalDiscount'])),
                totalMarkup: Value(_asDouble(m['totalMarkup'])),
                createdAt: _asStr(m['createdAt']),
                updatedAt: Value(_parseDate(m['updatedAt'])),
                deletedAt: Value(_parseDate(m['deletedAt'])),
              ),
            );
      }

      // ── 5. Sales + nested items ──
      for (final s in asList(data['sa_sales'])) {
        await db
            .into(db.sales)
            .insert(
              SalesCompanion.insert(
                id: _asStr(s['id']),
                receiptNo: _asStr(s['receiptNo']),
                subtotal: _asDouble(s['subtotal']),
                discount: Value(_asDouble(s['discount'])),
                total: _asDouble(s['total']),
                paymentMethod: _asStr(s['paymentMethod']),
                customerId: Value(_asNullableStr(s['customerId'])),
                customerName: Value(_asNullableStr(s['customerName'])),
                mechanicId: Value(_asNullableStr(s['mechanicId'])),
                mechanicName: Value(_asNullableStr(s['mechanicName'])),
                mechanicDelta: Value(
                  s['mechanicDelta'] == null
                      ? null
                      : _asDouble(s['mechanicDelta']),
                ),
                pointsGranted: Value(_asInt(s['pointsGranted'])),
                date: _parseDate(s['date']) ?? DateTime.now(),
                voided: Value(_asBool(s['voided'])),
                voidedAt: Value(_parseDate(s['voidedAt'])),
              ),
            );
        for (final it in asList(s['items'])) {
          await db
              .into(db.saleItems)
              .insert(
                SaleItemsCompanion.insert(
                  saleId: _asStr(s['id']),
                  productId: _asStr(it['productId']),
                  partNo: Value(_asNullableStr(it['partNo'])),
                  name: _asStr(it['name']),
                  nameTH: Value(_asNullableStr(it['nameTH'])),
                  qty: _asInt(it['qty']),
                  price: _asDouble(it['price']),
                  // JS backups may carry the cost at sale time — keep it rather
                  // than falling back to today's products.cost (ADR-0008).
                  costAtSale: Value(_asNullableDouble(it['cost'])),
                ),
              );
        }
      }

      // ── 6. Purchase orders + nested items ──
      for (final po in asList(data['sa_pos'])) {
        await db
            .into(db.purchaseOrders)
            .insert(
              PurchaseOrdersCompanion.insert(
                id: _asStr(po['id']),
                poNo: _asStr(po['poNo']),
                supplier: _asStr(po['supplier']),
                status: Value(_asStr(po['status'], 'open')),
                createdAt: _parseDate(po['createdAt']) ?? DateTime.now(),
                receivedAt: Value(_parseDate(po['receivedAt'])),
                cancelledAt: Value(_parseDate(po['cancelledAt'])),
              ),
            );
        for (final it in asList(po['items'])) {
          await db
              .into(db.poItems)
              .insert(
                PoItemsCompanion.insert(
                  poId: _asStr(po['id']),
                  partNo: _asStr(it['partNo']),
                  name: _asStr(it['name']),
                  qty: _asInt(it['qty']),
                  cost: _asDouble(it['cost']),
                ),
              );
        }
      }

      // ── 7. Quotes + nested items ──
      for (final q in asList(data['sa_quotes'])) {
        await db
            .into(db.quotes)
            .insert(
              QuotesCompanion.insert(
                id: _asStr(q['id']),
                quoteNo: _asStr(q['quoteNo']),
                status: Value(_asStr(q['status'], 'open')),
                date: _parseDate(q['date']) ?? DateTime.now(),
                validUntil: _parseDate(q['validUntil']) ?? DateTime.now(),
                convertedAt: Value(_parseDate(q['convertedAt'])),
                subtotal: Value(
                  q['subtotal'] == null ? null : _asDouble(q['subtotal']),
                ),
                discount: Value(
                  q['discount'] == null ? null : _asDouble(q['discount']),
                ),
                total: Value(q['total'] == null ? null : _asDouble(q['total'])),
                customerName: Value(_asNullableStr(q['customerName'])),
                customerPhone: Value(_asNullableStr(q['customerPhone'])),
                notes: Value(_asNullableStr(q['notes'])),
                validDays: Value(
                  q['validDays'] == null ? null : _asInt(q['validDays']),
                ),
              ),
            );
        for (final it in asList(q['items'])) {
          await db
              .into(db.quoteItems)
              .insert(
                QuoteItemsCompanion.insert(
                  quoteId: _asStr(q['id']),
                  productId: Value(_asNullableStr(it['productId'])),
                  name: _asStr(it['name']),
                  qty: _asInt(it['qty']),
                  price: _asDouble(it['price']),
                ),
              );
        }
      }

      // ── 8. Returns + nested items ──
      for (final r in asList(data['sa_returns'])) {
        await db
            .into(db.returns)
            .insert(
              ReturnsCompanion.insert(
                id: _asStr(r['id']),
                cnNo: _asStr(r['cnNo']),
                saleId: _asStr(r['saleId']),
                receiptNo: _asStr(r['receiptNo']),
                refundSubtotal: _asDouble(r['refundSubtotal']),
                refundDiscount: _asDouble(r['refundDiscount']),
                refundTotal: _asDouble(r['refundTotal']),
                refundMethod: _asStr(r['refundMethod']),
                reason: Value(_asStr(r['reason'])),
                customerId: Value(_asNullableStr(r['customerId'])),
                mechanicId: Value(_asNullableStr(r['mechanicId'])),
                mechanicName: Value(_asNullableStr(r['mechanicName'])),
                date: _parseDate(r['date']) ?? DateTime.now(),
              ),
            );
        for (final it in asList(r['items'])) {
          await db
              .into(db.returnItems)
              .insert(
                ReturnItemsCompanion.insert(
                  returnId: _asStr(r['id']),
                  productId: _asStr(it['productId']),
                  name: _asStr(it['name']),
                  qty: _asInt(it['qty']),
                  price: _asDouble(it['price']),
                  originalQty: Value(
                    it['originalQty'] == null
                        ? null
                        : _asInt(it['originalQty']),
                  ),
                ),
              );
        }
      }

      // ── 9. Movements ──
      for (final m in asList(data['sa_movements'])) {
        await db
            .into(db.movements)
            .insert(
              MovementsCompanion.insert(
                id: _asStr(m['id']),
                productId: _asStr(m['productId']),
                partNo: _asStr(m['partNo']),
                name: _asStr(m['name']),
                delta: _asInt(m['delta']),
                type: _asStr(m['type']),
                note: Value(_asNullableStr(m['note'])),
                stockAfter: _asInt(m['stockAfter']),
                date: _parseDate(m['date']) ?? DateTime.now(),
              ),
            );
      }

      // ── 10. Suppliers ──
      for (final s in asList(data['sa_suppliers'])) {
        await db
            .into(db.suppliers)
            .insert(
              SuppliersCompanion.insert(
                id: _asStr(s['id']),
                productId: _asStr(s['productId']),
                name: _asStr(s['name']),
                unitCost: _asDouble(s['unitCost']),
                freight: Value(_asDouble(s['freight'])),
              ),
            );
      }

      // ── 11. Categories (array of names → preserve order in position) ──
      final cats = data['sa_categories'];
      if (cats is List) {
        for (var i = 0; i < cats.length; i++) {
          final name = cats[i];
          if (name == null) continue;
          await db
              .into(db.categories)
              .insert(
                CategoriesCompanion.insert(name: name.toString(), position: i),
              );
        }
      }

      // ── 12. Credit payments ──
      for (final p in asList(data['sa_credit_payments'])) {
        await db
            .into(db.creditPayments)
            .insert(
              CreditPaymentsCompanion.insert(
                id: _asStr(p['id']),
                receiptNo: _asStr(p['receiptNo']),
                mechanicId: _asStr(p['mechanicId']),
                amount: _asDouble(p['amount']),
                date: _parseDate(p['date']) ?? DateTime.now(),
                note: Value(_asNullableStr(p['note'])),
              ),
            );
      }

      // ── 13. Active shift (sa_cash_drawer) → Shift isActive=true + entries ──
      final cd = data['sa_cash_drawer'];
      if (cd is Map) {
        final shift = cd.cast<String, dynamic>();
        // A JS snapshot's shifts carry no id at all, so the importer issues
        // one by the same rule as openShift (schema v3: shift ids are TEXT and
        // are no longer invented by the database).
        final shiftId = newId('sh');
        await db
            .into(db.shifts)
            .insert(
              ShiftsCompanion.insert(
                id: shiftId,
                dateStr: _asStr(shift['date']),
                startingCash: _asDouble(shift['startingCash']),
                openedAt: _parseDate(shift['openedAt']) ?? DateTime.now(),
                closedAt: Value(_parseDate(shift['closedAt'])),
                physicalCash: Value(
                  shift['physicalCash'] == null
                      ? null
                      : _asDouble(shift['physicalCash']),
                ),
                isActive: const Value(true),
                autoArchived: Value(_asBool(shift['autoArchived'])),
                archivedAt: Value(_parseDate(shift['archivedAt'])),
              ),
            );
        for (final e in asList(shift['entries'])) {
          await db
              .into(db.drawerEntries)
              .insert(
                DrawerEntriesCompanion.insert(
                  id: _asStr(e['id'], newId('de')),
                  shiftId: shiftId,
                  type: _asStr(e['type']),
                  amount: _asDouble(e['amount']),
                  note: Value(_asNullableStr(e['note'])),
                  createdAt: _parseDate(e['createdAt']) ?? DateTime.now(),
                ),
              );
        }
      }

      // ── 14. Shift history (sa_shift_history) → inactive Shifts + entries ──
      for (final shift in asList(data['sa_shift_history'])) {
        final shiftId = newId('sh');
        await db
            .into(db.shifts)
            .insert(
              ShiftsCompanion.insert(
                id: shiftId,
                dateStr: _asStr(shift['date']),
                startingCash: _asDouble(shift['startingCash']),
                openedAt: _parseDate(shift['openedAt']) ?? DateTime.now(),
                closedAt: Value(_parseDate(shift['closedAt'])),
                physicalCash: Value(
                  shift['physicalCash'] == null
                      ? null
                      : _asDouble(shift['physicalCash']),
                ),
                isActive: const Value(false),
                autoArchived: Value(_asBool(shift['autoArchived'])),
                archivedAt: Value(_parseDate(shift['archivedAt'])),
              ),
            );
        for (final e in asList(shift['entries'])) {
          await db
              .into(db.drawerEntries)
              .insert(
                DrawerEntriesCompanion.insert(
                  id: _asStr(e['id'], newId('de')),
                  shiftId: shiftId,
                  type: _asStr(e['type']),
                  amount: _asDouble(e['amount']),
                  note: Value(_asNullableStr(e['note'])),
                  createdAt: _parseDate(e['createdAt']) ?? DateTime.now(),
                ),
              );
        }
      }

      // ── 15. Parked (sa_parked) — re-encode each payload object as JSON ──
      for (final p in asList(data['sa_parked'])) {
        final id = _asStr(p['id'], newId('pk'));
        final parkedAt = _parseDate(p['parkedAt']) ?? DateTime.now();
        await db
            .into(db.parkedSales)
            .insert(
              ParkedSalesCompanion.insert(
                id: id,
                parkedAt: parkedAt,
                payload: jsonEncode(p),
              ),
            );
      }

      // ── 16. Settings (singleton id=0) — patch if present ──
      final settings = data['sa_settings'];
      if (settings is Map) {
        final s = settings.cast<String, dynamic>();
        await (db.update(db.settingsRow)..where((t) => t.id.equals(0))).write(
          SettingsRowCompanion(
            shopName: Value(_asStr(s['shopName'])),
            shopNameEN: Value(_asStr(s['shopNameEN'])),
            taxRate: Value(_asDouble(s['taxRate'], 7)),
            quoteValidDays: Value(_asInt(s['quoteValidDays'], 30)),
            address: Value(_asNullableStr(s['address'])),
            phone: Value(_asNullableStr(s['phone'])),
            cashierName: Value(_asNullableStr(s['cashierName'])),
            taxId: Value(_asNullableStr(s['taxId'])),
            branchNo: Value(_asNullableStr(s['branchNo'])),
            updatedAt: Value(_parseDate(s['updatedAt'])),
          ),
        );
      }

      // ── 17. Schema version (raw string) into AppMeta ──
      final sv = data['sa_schema_version'];
      if (sv != null) {
        await db
            .into(db.appMeta)
            .insertOnConflictUpdate(
              AppMetaCompanion.insert(
                key: 'schema_version',
                value: sv.toString(),
              ),
            );
      }

      // ── 18. Carry forward any UNKNOWN sa_* store the file holds ──
      // db.js writes every sa_* key the backup carries, including stores a newer
      // app version added that this build has no table for. We can't materialise
      // those into typed tables, so we stash each one verbatim (JSON-encoded) in
      // AppMeta so a later export re-emits it and the backup round-trips losslessly.
      // First clear any previously-carried unknowns (the wipe in step 1 only
      // touched typed tables, not AppMeta), so an omitted key doesn't linger.
      await (db.delete(
        db.appMeta,
      )..where((t) => t.key.like('$unknownStorePrefix%'))).go();
      for (final entry in data.entries) {
        final k = entry.key;
        if (k == '__meta') continue;
        if (!k.startsWith('sa_')) continue;
        if (_knownStoreKeys.contains(k)) continue;
        // A null value is treated as "absent" (mirrors db.js: never write "null").
        if (entry.value == null) continue;
        await db
            .into(db.appMeta)
            .insertOnConflictUpdate(
              AppMetaCompanion.insert(
                key: '$unknownStorePrefix$k',
                value: jsonEncode(entry.value),
              ),
            );
      }
    });
  }
}
