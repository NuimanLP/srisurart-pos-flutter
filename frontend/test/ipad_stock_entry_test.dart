// iPad stock entry (owner about to key in the whole stock on an iPad, web
// build): the add-product / adjust-stock / create-PO forms at iPad sizes.
//
// - What the field shows is what is saved: "1,200" or "12.5" in a whole-number
//   field used to show on screen and save as 0 (double/int.tryParse → null).
// - A second tap on บันทึก while the first save is still running is ignored
//   (two products / two stock adjustments otherwise).
// - A refused save (duplicate part number, no connection) is said INSIDE the
//   dialog: the SnackBar sits under the dialog, and under the keyboard's
//   shrunken dialog it is not visible at all. The typed values stay.
// - Return/Next walks the text fields in form order (it used to stop on the
//   scan button / category dropdown and drop the keyboard).
// - Every text field of the stock dialogs stays visible above a 380 px
//   keyboard at portrait, landscape and split-view widths.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:srisurart_pos/core/errors/pos_exception.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/data/repositories/products_repository.dart';
import 'package:srisurart_pos/data/repositories/purchase_orders_repository.dart';
import 'package:srisurart_pos/domain/models/aggregates.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/products_screen.dart';
import 'package:srisurart_pos/presentation/screens/purchase_orders_screen.dart';
import 'package:srisurart_pos/presentation/widgets/ui_zoom.dart';

const _landscape = Size(1180, 820);
const _portrait = Size(820, 1180);
const _split = Size(507, 820);
const _keyboard = 380.0;

/// A products repository whose writes wait on [gate] (a slow network), and
/// that counts them. [failWith] makes add / update throw instead.
class _GatedProducts extends ProductsRepository {
  _GatedProducts(super.db);
  Completer<void>? gate;
  Object? failWith;
  Object? failCategory;
  int adds = 0;
  int adjusts = 0;

  @override
  Future<void> addCategory(String name) async {
    if (failCategory != null) throw failCategory!;
    return super.addCategory(name);
  }

  @override
  Future<ProductRow?> add(ProductsCompanion data) async {
    adds++;
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    return super.add(data);
  }

  @override
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async {
    adjusts++;
    if (gate != null) await gate!.future;
    return super.adjustStock(productId, delta, type, note);
  }
}

class _FailingAdjust extends ProductsRepository {
  _FailingAdjust(super.db, this.error);
  final Object error;
  @override
  Future<void> adjustStock(
    String productId,
    int delta,
    String type,
    String? note,
  ) async =>
      throw error;
}

class _RecordingPos extends PurchaseOrdersRepository {
  _RecordingPos(super.db);
  PoInput? saved;
  @override
  Future<PurchaseOrderRow> savePO(PoInput input) {
    saved = input;
    return super.savePO(input);
  }
}

/// The add-product form's category Row overflows a few px in the test font
/// (pre-existing, see keyboard_safe_dialogs_test.dart). Anything else fails.
void _allowCategoryOverflow(WidgetTester tester) {
  final e = tester.takeException();
  if (e == null) return;
  expect(e.toString(), contains('A RenderFlex overflowed by'));
}

Future<void> _pump(
  WidgetTester tester,
  AppDatabase db,
  Widget home, {
  Size screen = _landscape,
  ProductsRepository? products,
  PurchaseOrdersRepository? pos,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        ...repositoryProviders(db, useApiRepositories: false),
        if (products != null)
          RepositoryProvider<ProductsRepository>.value(value: products),
        if (pos != null)
          RepositoryProvider<PurchaseOrdersRepository>.value(value: pos),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
          BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
          BlocProvider<CartCubit>(create: (_) => CartCubit()),
        ],
        child: MaterialApp(
          builder: (context, child) => UiZoom(zoom: 1.0, child: child!),
          home: Scaffold(body: home),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(find.text('เพิ่มสินค้า'));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  _allowCategoryOverflow(tester);
  expect(find.text('เพิ่มสินค้าใหม่'), findsOneWidget);
}

/// The text field next to the form label [label] (a required label ends in
/// " *") in the open dialog: the first field under the label's nearest
/// Row/Column that holds one.
Finder _field(String label) {
  final labelF = find.descendant(
    of: find.byType(Dialog),
    matching: find.byWidgetPredicate((w) {
      if (w is! RichText) return false;
      final t = w.text.toPlainText();
      return t == label || t == '$label *';
    }),
  );
  final around = find.ancestor(
    of: labelF.first,
    matching: find.byWidgetPredicate((w) => w is Column || w is Row),
  );
  for (final e in around.evaluate()) {
    final f = find.descendant(
      of: find.byElementPredicate((x) => x == e),
      matching: find.byType(EditableText),
    );
    if (f.evaluate().isNotEmpty) return f.first;
  }
  throw StateError('no text field for "$label"');
}

/// Opens the adjust-stock dialog of the first product (icon or labelled
/// button, whichever the width shows; scrolled into view first).
Future<void> _openAdjust(WidgetTester tester) async {
  final icon = find.byTooltip('ปรับสต็อก');
  final target = icon.evaluate().isNotEmpty
      ? icon.first
      : find.text('ปรับสต็อก').first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  expect(find.text('ปรับสต็อก · Adjust Stock'), findsOneWidget);
}

String _text(WidgetTester tester, Finder f) =>
    tester.widget<EditableText>(f).controller.text;

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.ensureVisible(_field(label));
  await tester.enterText(_field(label), text);
  await tester.pump();
  _allowCategoryOverflow(tester);
}

Finder get _saveButton => find
    .descendant(of: find.byType(Dialog), matching: find.text('บันทึก'))
    .last;

Future<ProductRow?> _byPartNo(AppDatabase db, String partNo) =>
    (db.select(db.products)..where((t) => t.partNo.equals(partNo)))
        .getSingleOrNull();

void main() {
  setUpAll(() async {
    await initializeDateFormatting('th', null);
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('add-product: a typed "1,200" / "12.5" is saved as shown, '
      'never as a silent 0', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen());
      await _openAdd(tester);
      await _type(tester, 'รหัสสินค้า', 'IPAD-001');
      await _type(tester, 'ชื่อ (TH)', 'ผ้าเบรกหน้า');
      await _type(tester, 'สต็อก', '12.5');
      await _type(tester, 'สต็อกขั้นต่ำ', '2,0');
      await _type(tester, 'ราคาทุน ฿', '1,200');
      await _type(tester, 'ราคาขาย ฿ (รวม VAT)', '1,890.50');
      final shown = {
        'stock': _text(tester, _field('สต็อก')),
        'min': _text(tester, _field('สต็อกขั้นต่ำ')),
        'cost': _text(tester, _field('ราคาทุน ฿')),
        'price': _text(tester, _field('ราคาขาย ฿ (รวม VAT)')),
      };
      await tester.tap(_saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final p = await _byPartNo(db, 'IPAD-001');
      expect(p, isNotNull);
      // Whatever the field shows, the product holds that number.
      expect('${p!.stock}', shown['stock']);
      expect('${p.minStock}', shown['min']);
      expect(p.cost, double.parse(shown['cost']!));
      expect(p.price, double.parse(shown['price']!));
      // And the shown text is the number the owner meant, minus the comma.
      expect(p.cost, 1200);
      expect(p.price, 1890.5);
      await db.close();
    });
  });

  testWidgets('add-product: a second tap on บันทึก during a slow save adds '
      'nothing', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = _GatedProducts(db)..gate = Completer<void>();
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdd(tester);
      await _type(tester, 'รหัสสินค้า', 'IPAD-002');
      await _type(tester, 'ชื่อ (TH)', 'กรองน้ำมันเครื่อง');
      await tester.tap(_saveButton);
      await tester.pump();
      await tester.tap(_saveButton, warnIfMissed: false);
      await tester.pump();
      repo.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(repo.adds, 1);
      expect(
        await (db.select(db.products)
              ..where((t) => t.partNo.equals('IPAD-002')))
            .get(),
        hasLength(1),
      );
      await db.close();
    });
  });

  testWidgets('add-product: a refused save is shown inside the dialog and '
      'keeps what was typed', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    const msg = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ (ทดสอบ)';
    final repo = _GatedProducts(db)
      ..failWith = const PosException('NETWORK_ERROR', msg);
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdd(tester);
      await _type(tester, 'รหัสสินค้า', 'IPAD-003');
      await _type(tester, 'ชื่อ (TH)', 'หัวเทียน');
      await _type(tester, 'ราคาขาย ฿ (รวม VAT)', '120');
      await tester.tap(_saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('เพิ่มสินค้าใหม่'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text(msg)),
        findsOneWidget,
      );
      expect(_text(tester, _field('รหัสสินค้า')), 'IPAD-003');
      expect(_text(tester, _field('ชื่อ (TH)')), 'หัวเทียน');
      expect(_text(tester, _field('ราคาขาย ฿ (รวม VAT)')), '120');
      await db.close();
    });
  });

  testWidgets('add-product: a duplicate part number is shown inside the '
      'dialog', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen());
      final existing = (await db.select(db.products).get()).first;
      await _openAdd(tester);
      await _type(tester, 'รหัสสินค้า', existing.partNo);
      await _type(tester, 'ชื่อ (TH)', 'ซ้ำ');
      await tester.tap(_saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('รหัส "${existing.partNo}" มีอยู่แล้วในระบบ'),
        ),
        findsOneWidget,
      );
      await db.close();
    });
  });

  testWidgets('add-product: Return/Next walks the text fields in form order',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen());
      await _openAdd(tester);
      const order = [
        'รหัสสินค้า',
        'ชื่อ (EN)',
        'ชื่อ (TH)',
        'แบรนด์',
        'ใช้กับรถรุ่น',
        'สต็อก',
        'สต็อกขั้นต่ำ',
        'ราคาทุน ฿',
        'ค่าขนส่ง ฿',
        'ราคาขาย ฿ (รวม VAT)',
      ];
      await tester.tap(_field(order.first));
      await tester.pump();
      for (var i = 0; i < order.length - 1; i++) {
        final here = tester.widget<EditableText>(_field(order[i]));
        expect(here.focusNode.hasFocus, isTrue, reason: order[i]);
        expect(here.textInputAction, TextInputAction.next, reason: order[i]);
        await tester.testTextInput.receiveAction(TextInputAction.next);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        _allowCategoryOverflow(tester);
        final next = _field(order[i + 1]);
        expect(
          tester.widget<EditableText>(next).focusNode.hasFocus,
          isTrue,
          reason: 'Next from ${order[i]} should land on ${order[i + 1]}',
        );
        // ...and the field it lands on is scrolled into the form's view
        // (the price box sits below the fold).
        final body = tester.getRect(find
            .ancestor(of: next, matching: find.byType(SingleChildScrollView))
            .first);
        final r = tester.getRect(next);
        expect(r.top >= body.top && r.bottom <= body.bottom, isTrue,
            reason: '${order[i + 1]} $r outside the form view $body');
      }
      await db.close();
    });
  });

  testWidgets('add-product: whole-number keyboards for stock, decimal for '
      'money', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen());
      await _openAdd(tester);
      for (final l in ['สต็อก', 'สต็อกขั้นต่ำ']) {
        expect(
          tester.widget<EditableText>(_field(l)).keyboardType,
          TextInputType.number,
          reason: l,
        );
      }
      for (final l in ['ราคาทุน ฿', 'ค่าขนส่ง ฿', 'ราคาขาย ฿ (รวม VAT)']) {
        expect(
          tester.widget<EditableText>(_field(l)).keyboardType,
          const TextInputType.numberWithOptions(decimal: true),
          reason: l,
        );
      }
      await db.close();
    });
  });

  testWidgets('adjust stock: a second tap on บันทึก during a slow save does '
      'not adjust twice', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = _GatedProducts(db)..gate = Completer<void>();
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdjust(tester);
      await tester.tap(find.byKey(const Key('adjust-step-5')));
      await tester.pump();
      await tester.tap(_saveButton);
      await tester.pump();
      await tester.tap(_saveButton, warnIfMissed: false);
      await tester.pump();
      repo.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(repo.adjusts, 1);
      await db.close();
    });
  });

  testWidgets('adjust stock: a refused save is shown inside the dialog',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    const msg = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ (ทดสอบ)';
    final repo = _FailingAdjust(db, const PosException('NETWORK_ERROR', msg));
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdjust(tester);
      await tester.tap(find.byKey(const Key('adjust-step-1')));
      await tester.pump();
      await tester.tap(_saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('ปรับสต็อก · Adjust Stock'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text(msg)),
        findsOneWidget,
      );
      // Pressable again for the retry (same parked key on the API build).
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(of: _saveButton, matching: find.byType(FilledButton)),
            )
            .onPressed,
        isNotNull,
      );
      await db.close();
    });
  });

  testWidgets('create PO: a typed "2.5" qty is not silently saved as 1',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final pos = _RecordingPos(db);
    await tester.runAsync(() async {
      await (db.update(db.products)..where((t) => t.id.equals('p2')))
          .write(const ProductsCompanion(stock: Value(3)));
      await _pump(
        tester,
        db,
        const PurchaseOrdersScreen(prefill: PoPrefill(supplier: 'NGK Thailand')),
        pos: pos,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final qty = _field('จำนวน');
      await tester.ensureVisible(qty);
      await tester.enterText(qty, '2.5');
      await tester.pump();
      final shown = _text(tester, qty);
      await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pos.saved, isNotNull);
      expect('${pos.saved!.items.single.qty}', shown);
      await db.close();
    });
  });

  // ── Review fixes (PR #829) ────────────────────────────────────────────

  testWidgets('create PO: a "1.2.3" or "." cost is never saved as ฿0',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final pos = _RecordingPos(db);
    await tester.runAsync(() async {
      await (db.update(db.products)..where((t) => t.id.equals('p2')))
          .write(const ProductsCompanion(stock: Value(3)));
      await _pump(tester, db,
          const PurchaseOrdersScreen(prefill: PoPrefill(supplier: 'NGK Thailand')),
          pos: pos);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final cost = _field('ราคาทุน ฿');
      await tester.ensureVisible(cost);
      await tester.enterText(cost, '1.2.3');
      await tester.pump();
      final shown = _text(tester, cost);
      await tester.enterText(cost, '.');
      await tester.pump();
      // "." is not a cost: nothing may be saved.
      await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pos.saved, isNull, reason: '"." saved as a cost');
      // Back to the text the filter kept for "1.2.3": saved exactly as shown.
      await tester.enterText(cost, shown);
      await tester.pump();
      await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pos.saved, isNotNull);
      expect(pos.saved!.items.single.cost, double.parse(shown));
      await db.close();
    });
  });

  testWidgets('create PO: a blank qty is not saved as 1', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final pos = _RecordingPos(db);
    await tester.runAsync(() async {
      await (db.update(db.products)..where((t) => t.id.equals('p2')))
          .write(const ProductsCompanion(stock: Value(3)));
      await _pump(tester, db,
          const PurchaseOrdersScreen(prefill: PoPrefill(supplier: 'NGK Thailand')),
          pos: pos);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final qty = _field('จำนวน');
      await tester.ensureVisible(qty);
      await tester.enterText(qty, '');
      await tester.pump();
      await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pos.saved, isNull);
      expect(find.text('กรอกจำนวนและราคาทุนให้ครบทุกรายการ'), findsOneWidget);
      await db.close();
    });
  });

  testWidgets('create PO: adding a listed part again shows the new qty that '
      'is saved', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final pos = _RecordingPos(db);
    await tester.runAsync(() async {
      await (db.update(db.products)..where((t) => t.id.equals('p2')))
          .write(const ProductsCompanion(stock: Value(3)));
      final p2 = await (db.select(db.products)
            ..where((t) => t.id.equals('p2')))
          .getSingle();
      await _pump(tester, db,
          const PurchaseOrdersScreen(prefill: PoPrefill(supplier: 'NGK Thailand')),
          pos: pos);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final search = _field('เพิ่มสินค้า · Add Items');
      await tester.enterText(search, p2.partNo);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final shown = _text(tester, _field('จำนวน'));
      await tester.tap(find.text('บันทึกใบสั่งซื้อ'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(pos.saved, isNotNull);
      expect('${pos.saved!.items.single.qty}', shown);
      await db.close();
    });
  });

  for (final label in ['สต็อก', 'สต็อกขั้นต่ำ']) {
    testWidgets('add-product: a blank $label is not saved as a default',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pump(tester, db, const ProductsScreen());
        await _openAdd(tester);
        await _type(tester, 'รหัสสินค้า', 'IPAD-BLANK');
        await _type(tester, 'ชื่อ (TH)', 'ว่าง');
        await _type(tester, label, '');
        await tester.tap(_saveButton);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        _allowCategoryOverflow(tester);
        expect(await _byPartNo(db, 'IPAD-BLANK'), isNull);
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('กรุณากรอกจำนวนสต็อกและสต็อกขั้นต่ำ'),
          ),
          findsOneWidget,
        );
        await db.close();
      });
    });
  }

  testWidgets('add-product: a missing part number is said inside the dialog, '
      'and typing clears it', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen());
      await _openAdd(tester);
      await _type(tester, 'ชื่อ (TH)', 'ไม่มีรหัส');
      await tester.tap(_saveButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      _allowCategoryOverflow(tester);
      final inDialog = find.descendant(
        of: find.byType(Dialog),
        matching: find.text('กรุณากรอกรหัสสินค้า'),
      );
      expect(inDialog, findsOneWidget);
      await _type(tester, 'รหัสสินค้า', 'X');
      expect(inDialog, findsNothing);
      await db.close();
    });
  });

  testWidgets('add-product: a refused new category is said inside the dialog',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    const msg = 'เพิ่มประเภทไม่ได้ (ทดสอบ)';
    final repo = _GatedProducts(db)
      ..failCategory = const PosException('NETWORK_ERROR', msg);
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdd(tester);
      final newCat = find.descendant(
        of: find.byType(Dialog),
        matching: find.widgetWithText(TextField, 'ใหม่…'),
      );
      await tester.enterText(newCat, 'ช่วงล่าง');
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.widgetWithIcon(IconButton, Icons.add),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      _allowCategoryOverflow(tester);
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text(msg)),
        findsOneWidget,
      );
      await db.close();
    });
  });

  testWidgets('adjust stock: editing the amount clears the refusal',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    const msg = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ (ทดสอบ)';
    final repo = _FailingAdjust(db, const PosException('NETWORK_ERROR', msg));
    await tester.runAsync(() async {
      await _pump(tester, db, const ProductsScreen(), products: repo);
      await _openAdjust(tester);
      await tester.tap(find.byKey(const Key('adjust-step-1')));
      await tester.pump();
      await tester.tap(_saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text(msg), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(EditableText),
        ).first,
        '+2',
      );
      await tester.pump();
      expect(find.text(msg), findsNothing);
      await db.close();
    });
  });

  // iPad portrait (820 wide, ~735 beside the nav rail): the nine-column table
  // pushed ปรับสต็อก / แก้ไข off the right edge — every row needed a sideways
  // swipe. Below the tablet/desktop boundary the product list is the card
  // list, whose actions are on screen.
  for (final size in [_portrait, const Size(735, 1180)]) {
    testWidgets('iPad portrait ${size.width.toInt()} wide: ปรับสต็อก and '
        'แก้ไข are on screen without a sideways scroll', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pump(tester, db, const ProductsScreen(), screen: size);
        for (final label in ['ปรับสต็อก', 'แก้ไข']) {
          final f = find.text(label);
          expect(f, findsWidgets, reason: label);
          final r = tester.getRect(f.first);
          expect(r.right, lessThanOrEqualTo(size.width), reason: '$label $r');
        }
        await db.close();
      });
    });
  }

  // Every text field of the stock dialogs, at each iPad layout: tap it, the
  // keyboard comes up, and the field is still on screen and inside the
  // dialog's scroll body.
  for (final (name, size) in [
    ('landscape', _landscape),
    ('portrait', _portrait),
    ('split view', _split),
  ]) {
    Future<void> everyFieldAboveKeyboard(
      WidgetTester tester,
      Future<void> Function() open,
    ) async {
      final count = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byType(EditableText),
          )
          .evaluate()
          .length;
      expect(count, greaterThan(0));
      for (var i = 0; i < count; i++) {
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        _allowCategoryOverflow(tester);
        final f = find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(EditableText),
            )
            .at(i);
        if (!tester.widget<EditableText>(f).readOnly &&
            tester.widget<EditableText>(f).focusNode.canRequestFocus) {
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          _allowCategoryOverflow(tester);
          await tester.tap(f, warnIfMissed: false);
          await tester.pump();
          tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          _allowCategoryOverflow(tester);
          if (!tester.widget<EditableText>(f).focusNode.hasFocus) continue;
          final r = tester.getRect(f);
          final visibleBottom = size.height - _keyboard;
          expect(r.top, greaterThanOrEqualTo(0), reason: 'field $i $r');
          expect(r.bottom, lessThanOrEqualTo(visibleBottom),
              reason: 'field $i $r');
        }
      }
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      _allowCategoryOverflow(tester);
    }

    testWidgets('$name ${size.width.toInt()}x${size.height.toInt()}: every '
        'add-product field stays above the keyboard', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pump(tester, db, const ProductsScreen(), screen: size);
        await _openAdd(tester);
        await everyFieldAboveKeyboard(tester, () async {});
        await db.close();
      });
    });

    testWidgets('$name ${size.width.toInt()}x${size.height.toInt()}: every '
        'adjust-stock field stays above the keyboard', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.runAsync(() async {
        await _pump(tester, db, const ProductsScreen(), screen: size);
        await _openAdjust(tester);
        await everyFieldAboveKeyboard(tester, () async {});
        await db.close();
      });
    });
  }
}
