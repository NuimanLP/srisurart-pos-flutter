// ApiReturnsRepository (#56) — the credit note is the server's document.
//
// As in the sales test, the mock answers with numbers the client's own
// arithmetic could not produce (stock 77 after putting 1 back on a shelf of 3),
// so any fallback to the Drift `createReturn` maths fails the test rather than
// passing it quietly.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:srisurart_pos/core/network/api_client.dart';
import 'package:srisurart_pos/core/network/api_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/api/api_returns_repository.dart';
import 'package:srisurart_pos/data/repositories/returns_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';

String _ok(Map<String, dynamic> data) =>
    jsonEncode({'status': 'success', 'data': data});

String _err(String code, String message) => jsonEncode({
  'status': 'error',
  'error': {'code': code, 'message': message},
});

void main() {
  late AppDatabase db;
  late List<http.Request> sent;

  ApiReturnsRepository repoWith(
    Future<http.Response> Function(http.Request req) handler,
  ) {
    final client = MockClient((req) async {
      sent.add(req);
      return handler(req);
    });
    return ApiReturnsRepository(
      api: ApiClient(baseUrl: 'http://server.test', httpClient: client),
      db: db,
      drift: ReturnsRepository(db),
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: 'tp1',
            partNo: 'TP-1',
            name: 'Brake Pad',
            nameTH: 'ผ้าเบรก',
            category: 'เบรก',
            brand: 'X',
            price: 100,
            cost: 60,
            stock: 3,
            minStock: 1,
          ),
        );
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: 'tc1',
            code: 'C-1',
            name: 'Somchai',
            nameTH: 'สมชาย',
            createdAt: '2026-01-01',
            points: const Value(50),
            totalSpend: const Value(500),
          ),
        );
    await db
        .into(db.mechanics)
        .insert(
          MechanicsCompanion.insert(
            id: 'tm1',
            code: 'M-1',
            name: 'Chang',
            createdAt: '2026-01-01',
            creditLimit: const Value(5000),
            creditBalance: const Value(500),
          ),
        );
    // The parent bill: FIVE pads sold. Returning one of them is a PARTIAL
    // return — no local count could ever conclude "void the bill".
    await db
        .into(db.sales)
        .insert(
          SaleRow(
            id: 'sale-1',
            receiptNo: 'RC-00042',
            subtotal: 500,
            discount: 0,
            total: 500,
            paymentMethod: 'เงินสด',
            customerId: 'tc1',
            customerName: 'สมชาย',
            mechanicId: 'tm1',
            mechanicName: 'ช่างเอ',
            mechanicDelta: null,
            pointsGranted: 50,
            date: DateTime(2026, 9, 1),
            voided: false,
            voidedAt: null,
            shiftId: null,
          ),
        );
    await db
        .into(db.saleItems)
        .insert(
          SaleItemsCompanion.insert(
            saleId: 'sale-1',
            productId: 'tp1',
            name: 'Brake Pad',
            qty: 5,
            price: 100,
          ),
        );
  });

  tearDown(() async => db.close());

  const oneBack = ReturnInput(
    saleId: 'sale-1',
    refundMethod: 'เงินสด',
    reason: 'ของชำรุด',
    items: [
      ReturnLineInput(
        productId: 'tp1',
        name: 'Brake Pad',
        qty: 1,
        price: 100,
        originalQty: 5,
      ),
    ],
  );

  Map<String, dynamic> creditNote({bool saleVoided = false}) => {
    'id': 'r-server',
    'cnNo': 'CN-00007',
    'saleId': 'sale-1',
    'receiptNo': 'RC-00042',
    // The server's own amounts — a client summing 1 × 100 would say 100.
    'refundSubtotal': '100.00',
    'refundDiscount': '12.50',
    'refundTotal': '87.50',
    'refundMethod': 'เงินสด',
    'reason': 'ของชำรุด',
    'customerId': 'tc1',
    'mechanicId': 'tm1',
    'mechanicName': 'ช่างเอ',
    'date': '2026-09-12T04:00:00.000Z',
    // No column for this on the client — must be dropped, not crash.
    'shiftId': 'shift-xyz',
    'items': [
      {
        'lineNo': 1,
        'productId': 'tp1',
        'name': 'Brake Pad',
        'qty': 1,
        'price': '100.00',
        'originalQty': 5,
        'costAtSale': '60.00',
      },
    ],
    // 77, not 3 + 1 = 4.
    'products': [
      {'id': 'tp1', 'stock': 77},
    ],
    'customerAfter': {'id': 'tc1', 'points': 11, 'totalSpend': '222.25'},
    'mechanicCreditBalanceAfter': '333.75',
    'saleVoided': saleVoided,
    // ── #82's two new fields ──
    // The restore row the server actually wrote: stockAfter 77 again, and
    // `type: 'return'` — never collapsed into a void's 'return'-looking row
    // (migration 1788652800003 separated them so reports stop double-counting).
    'movements': [
      {
        'id': 'mv-server-r1',
        'productId': 'tp1',
        'partNo': 'TP-1',
        'name': 'Brake Pad',
        'delta': 1,
        'type': 'return',
        'note': 'CN-00007',
        'stockAfter': 77,
        'date': '2026-09-12T04:00:00.000Z',
      },
    ],
    // Four totals reversed by the server. A client reversing ฿87.50 off the
    // seeded 500 could produce none of them.
    'mechanicAfter': {
      'id': 'tm1',
      'totalSales': '999.00',
      'totalDiscount': '8.50',
      'totalMarkup': '1.25',
      'creditBalance': '333.75',
    },
  };

  /// The same credit note from a server that has not shipped #82: no
  /// `movements`, no `mechanicAfter`.
  Map<String, dynamic> creditNotePre82() => creditNote()
    ..remove('movements')
    ..remove('mechanicAfter');

  test(
    'patches the credit note and every effect from the response only',
    () async {
      late Map<String, dynamic> body;
      final repo = repoWith((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          _ok(creditNote()),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final cn = await repo.createReturn(oneBack);

      // What `returns_screen.dart` prints on the note.
      expect(cn.id, 'r-server');
      expect(cn.cnNo, 'CN-00007');
      expect(cn.receiptNo, 'RC-00042');
      expect(cn.refundSubtotal, 100);
      expect(cn.refundDiscount, 12.5);
      expect(cn.refundTotal, 87.5);
      expect(cn.date, DateTime.parse('2026-09-12T04:00:00.000Z').toLocal());

      final rows = await db.select(db.returns).get();
      expect(rows, hasLength(1));
      expect(rows.single.refundTotal, 87.5);

      final items = await db.select(db.returnItems).get();
      expect(items, hasLength(1));
      expect(items.single.returnId, 'r-server');
      expect(items.single.qty, 1);
      expect(items.single.price, 100);
      expect(items.single.originalQty, 5);

      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 77, reason: 'server value; local maths would give 4');
      expect(p.updatedAt, isNull, reason: 'updatedAt is #55\'s sync cursor');

      final c = await (db.select(
        db.customers,
      )..where((t) => t.id.equals('tc1'))).getSingle();
      expect(c.points, 11); // not 50 - something
      expect(c.totalSpend, 222.25); // not 500 - 87.50

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('tm1'))).getSingle();
      expect(m.creditBalance, 333.75); // not 500, not 500 - 87.50
      // #82: the other three running totals the server reverses too.
      expect(m.totalSales, 999);
      expect(m.totalDiscount, 8.5);
      expect(m.totalMarkup, 1.25);
      // 🔴 The legacy alias of totalDiscount (#11) — the server never writes it.
      expect(m.totalCredit, 0);

      // #82: the stock log row the server wrote, copied verbatim.
      final mv = await db.select(db.movements).get();
      expect(mv, hasLength(1));
      expect(mv.single.id, 'mv-server-r1'); // the server's id, not newId('mv')
      expect(mv.single.type, 'return');
      expect(mv.single.delta, 1);
      expect(mv.single.stockAfter, 77, reason: 'server value; local maths says 4');
      expect(mv.single.note, 'CN-00007');
      expect(
        mv.single.date,
        DateTime.parse('2026-09-12T04:00:00.000Z').toLocal(),
      );

      // ── The wire ──
      expect(body['saleId'], 'sale-1');
      expect(body['refundMethod'], 'เงินสด');
      expect(body['reason'], 'ของชำรุด');
      final line = (body['items'] as List).single as Map<String, dynamic>;
      // 🔴 Sent verbatim: the bill decides the price, and a mismatch must be
      // refused by the server rather than silently "corrected" here.
      expect(line['price'], '100.00');
      expect(line['qty'], 1);
      expect(line['originalQty'], 5);
      // Server-owned document fields the client must never claim.
      expect(body.containsKey('cnNo'), isFalse);
      expect(body.containsKey('shiftId'), isFalse);

      final post = sent.single;
      expect(post.url.path, '/api/v1/returns');
      expect(post.headers['Idempotency-Key'], isNotNull);
    },
  );

  test(
    '#82 — a response WITHOUT movements or mechanicAfter leaves them stale, no throw',
    () async {
      // A server that predates #82. Absent is "stale", never "work it out here"
      // (ADR-0010 §3), and above all never an exception at the counter.
      await (db.update(db.mechanics)..where((t) => t.id.equals('tm1'))).write(
        const MechanicsCompanion(
          totalSales: Value(11.11),
          totalDiscount: Value(22.22),
          totalMarkup: Value(33.33),
        ),
      );

      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNotePre82()),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      final cn = await repo.createReturn(oneBack);
      expect(cn.cnNo, 'CN-00007');
      expect(cn.refundTotal, 87.5);

      expect(
        await db.select(db.movements).get(),
        isEmpty,
        reason: 'movements are not in the response and must not be synthesised',
      );

      final m = await (db.select(
        db.mechanics,
      )..where((t) => t.id.equals('tm1'))).getSingle();
      expect(m.totalSales, 11.11, reason: 'stale, not moved by local arithmetic');
      expect(m.totalDiscount, 22.22);
      expect(m.totalMarkup, 33.33);
      // The legacy `mechanicCreditBalanceAfter` is still there and still used.
      expect(m.creditBalance, 333.75);
    },
  );

  test(
    'AC5 — sales.voided follows the saleVoided FLAG, not a local quantity count',
    () async {
      // One pad back out of five: no count on this device could conclude "void".
      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNote(saleVoided: true)),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      final cn = await repo.createReturn(oneBack);

      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isTrue);
      // The void happened in the credit note's own transaction, so its server
      // timestamp is the honest one — not a local clock reading.
      expect(sale.voidedAt, cn.date);

      // Sanity: the local numbers really do say "partial".
      final sold = await db.select(db.saleItems).get();
      final back = await db.select(db.returnItems).get();
      expect(sold.single.qty, 5);
      expect(back.single.qty, 1);
    },
  );

  test(
    'a partial return leaves the bill standing when the flag says so',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          _ok(creditNote(saleVoided: false)),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );
      await repo.createReturn(oneBack);
      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isFalse);
      expect(sale.voidedAt, isNull);
    },
  );

  test(
    'a 409 RETURN_PRICE_MISMATCH throws Thai and writes nothing',
    () async {
      final repo = repoWith(
        (req) async => http.Response(
          // The server's own message is English; the resolver supplies the Thai.
          _err(
            'RETURN_PRICE_MISMATCH',
            'Line 1 did not sell at that price on this bill.',
          ),
          409,
          headers: {'content-type': 'application/json'},
        ),
      );

      Object? thrown;
      try {
        await repo.createReturn(oneBack);
      } catch (e) {
        thrown = e;
      }

      // Again on this repository: a plain Exception carrying a clean Thai
      // sentence — `returns_screen.dart:238` renders exactly this.
      expect(thrown, isA<Exception>());
      expect(thrown, isNot(isA<ApiException>()));
      expect(
        thrown.toString().replaceFirst('Exception: ', ''),
        'ราคาใบลดหนี้ไม่ตรงกับบิลขาย',
      );

      expect(await db.select(db.returns).get(), isEmpty);
      expect(await db.select(db.returnItems).get(), isEmpty);
      final p = await (db.select(
        db.products,
      )..where((t) => t.id.equals('tp1'))).getSingle();
      expect(p.stock, 3);
      final sale = await (db.select(
        db.sales,
      )..where((t) => t.id.equals('sale-1'))).getSingle();
      expect(sale.voided, isFalse);
    },
  );

  test('a rejected refund method surfaces its Thai sentence', () async {
    final repo = repoWith(
      (req) async => http.Response(
        _err(
          'REFUND_METHOD_NOT_ALLOWED',
          "Refund method 'หักจากเครดิต' needs a bill with a mechanic.",
        ),
        409,
        headers: {'content-type': 'application/json'},
      ),
    );

    Object? thrown;
    try {
      await repo.createReturn(oneBack);
    } catch (e) {
      thrown = e;
    }
    final msg = thrown.toString().replaceFirst('Exception: ', '');
    expect(msg, isNot(contains('ApiException')));
    // 🔴 Pinned to the message the counter ACTUALLY sees, which is not the
    // mapped Thai one. `ServerErrorResolver.resolve` prefers any server message
    // containing a Thai codepoint over its own canonical string
    // (`server_error_resolver.dart:59-63`), and this server message is an
    // English sentence with one Thai literal quoted inside it
    // (`returns.service.ts:178`) — so the resolver's
    // 'วิธีคืนเงินไม่ถูกต้องสำหรับบิลนี้' never fires. Asserting only
    // `contains('หักจากเครดิต')` passed on the English sentence and proved
    // nothing, which is why this is spelled out in full. Fixing it belongs to
    // #54 (tighten the heuristic to messages that START in Thai) or to the
    // server (stop quoting a Thai literal in an English message); when either
    // lands, this expectation becomes the canonical string and the test is the
    // thing that notices.
    expect(msg, "Refund method 'หักจากเครดิต' needs a bill with a mechanic.");
  });

  test('reads still come from Drift', () async {
    final repo = repoWith((req) async => http.Response('unexpected', 500));
    expect(await repo.getReturns(), isEmpty);
  });
}
