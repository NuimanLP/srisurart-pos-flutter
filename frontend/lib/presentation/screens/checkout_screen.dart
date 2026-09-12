// checkout_screen.dart — POS Checkout / Sales (port of pos/CheckoutScreen.jsx).
//
// Reproduces the JS screen behaviour for parity:
//  • LEFT: barcode/part-no entry (Enter to add) + name search + category filter
//    chips + product tile grid (tap to add; out-of-stock disabled).
//  • RIGHT: parked-bills strip, customer selector, mechanic selector (with
//    per-line PRICE OVERRIDE — only when a mechanic is attached; blocks below
//    cost), cart with qty +/- and remove, subtotal/discount/total, mechanic
//    delta indicator, payment method (เงินสด / โอน/QR / เครดิตช่าง), cash entry
//    + quick-cash + change, ⏸ พักบิล, 📋 บันทึกใบเสนอราคา, and CHECKOUT.
//  • saveSale → on success opens the thermal Receipt; on failure shows the Thai
//    error (e.g. 'สต็อกไม่พอ…').
//  • Park/resume re-validates stock (validateItems): drops missing/out-of-stock
//    lines, clamps over-stock lines, never keeps qty:0 lines. Resuming with a
//    non-empty cart auto-parks the current cart first (swap).
//  • LowStockAlert shown once per session as a dismissible banner.
//
// Cart state is CartCubit (presentation/blocs/cart_cubit.dart). All data
// goes through repository injection; no direct AppDatabase access.
//
// Cross-screen quote loading: QuotesManager (convert/edit) stages a quote in
// `PendingQuoteCubit` then navigates here. On mount we consume it,
// re-validate its items against current stock (the same validateItems used by
// park/resume), load them into the cart at the quoted prices + the quote
// discount, best-effort re-select the customer, then clear the provider —
// mirroring the JS screen's loadQuote/onQuoteLoaded effect.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../data/repositories/customers_repository.dart';
import '../../data/repositories/mechanics_repository.dart';
import '../../data/repositories/parked_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/quotes_repository.dart';
import '../../data/repositories/sales_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/aggregates.dart';
import '../blocs/cart_cubit.dart';
import '../blocs/pending_quote_cubit.dart';
import '../widgets/low_stock_alert.dart';
import '../widgets/money_text.dart';
import '../widgets/receipt_view.dart';
import '../widgets/tap_target.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

const _orange = Color(0xFFE8601C);
const _warnOrange = Color(0xFFD4820A);

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _barcodeCtrl = TextEditingController();
  final _custSearchCtrl = TextEditingController();
  final _mechSearchCtrl = TextEditingController();
  final _cashCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();

  String _search = '';
  String _filterZone = 'ทั้งหมด';
  CustomerRow? _selectedCustomer;
  String _custSearch = '';
  MechanicRow? _selectedMechanic;
  String _mechSearch = '';
  String? _editingPriceId;
  String _payMethod = 'เงินสด';
  double _discount = 0;
  bool _submitting = false;
  bool _parkedBusy = false;
  String? _priceWarning;
  bool _lowStockDismissed = false;
  bool _consumingPendingQuote = false;

  // The screen's 6 co-located data loads — each created once in
  // initState/its own targeted refresh method, never inline in build.
  late Future<List<ProductRow>> _productsFuture;
  late Future<List<CustomerRow>> _customersFuture;
  late Future<List<MechanicRow>> _mechanicsFuture;
  late Future<List<String>>
  _categoriesFuture; // truly one-shot, never refreshed
  late Future<List<ParkedSaleRow>> _parkedFuture;
  late Future<Map<String, String>> _catColorsFuture; // truly one-shot

  @override
  void initState() {
    super.initState();
    _productsFuture = context.read<ProductsRepository>().getAll();
    _customersFuture = context.read<CustomersRepository>().getCustomers();
    _mechanicsFuture = context.read<MechanicsRepository>().getMechanics();
    _categoriesFuture = context.read<ProductsRepository>().getCategories();
    _parkedFuture = context.read<ParkedRepository>().getParked();
    _catColorsFuture = _loadCatColors();
    // A quote staged by QuotesManager (convert/edit) is consumed once on mount.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeConsumePendingQuote();
    });
  }

  Future<Map<String, String>> _loadCatColors() async {
    final repo = context.read<ProductsRepository>();
    final cats = await repo.getCategories();
    final out = <String, String>{};
    for (final c in cats) {
      out[c] = await repo.catColor(c);
    }
    return out;
  }

  void _refreshParked() => setState(() {
    _parkedFuture = context.read<ParkedRepository>().getParked();
  });

  /// Reset the 3 loads a completed sale can change: stock (products), and
  /// the mechanic/customer stats a sale updates (credit balance, points).
  void _refreshAfterSale() {
    setState(() {
      _productsFuture = context.read<ProductsRepository>().getAll();
      _mechanicsFuture = context.read<MechanicsRepository>().getMechanics();
      _customersFuture = context.read<CustomersRepository>().getCustomers();
    });
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    _custSearchCtrl.dispose();
    _mechSearchCtrl.dispose();
    _cashCtrl.dispose();
    _discountCtrl.dispose();
    super.dispose();
  }

  /// Sync the discount field's visible text to [_discount], mirroring the JS
  /// controlled input `value={discount||''}` (0 shows as an empty field).
  void _syncDiscountText() {
    _discountCtrl.text = _discount == 0
        ? ''
        : (_discount == _discount.truncateToDouble()
              ? _discount.toInt().toString()
              : _discount.toString());
  }

  void _warn(String msg) {
    setState(() => _priceWarning = msg);
  }

  void _clearWarn() {
    if (_priceWarning != null) setState(() => _priceWarning = null);
  }

  CartCubit get _cart => context.read<CartCubit>();

  // ── Re-validate a saved item list against CURRENT stock. ──
  ({List<CartLine> safe, List<String> issues}) _validateItems(
    List<CartLine> items,
    List<ProductRow> fresh,
  ) {
    final issues = <String>[];
    final safe = <CartLine>[];
    for (final it in items) {
      final p = fresh.where((x) => x.id == it.productId).firstOrNull;
      if (p == null) {
        issues.add('${it.name}: ไม่พบในสต็อกแล้ว');
        continue;
      }
      if (p.stock <= 0) {
        issues.add('${p.name}: หมดสต็อก');
        continue;
      }
      if (p.stock < it.qty) {
        issues.add('${p.name}: ต้องการ ${it.qty} · เหลือ ${p.stock}');
        safe.add(it.copyWith(qty: p.stock));
        continue;
      }
      safe.add(it);
    }
    return (safe: safe, issues: issues);
  }

  // ── Consume a quote staged by QuotesManager (convert/edit). ──
  // Mirrors the JS loadQuote effect: re-validate the quote items against current
  // stock, load them (at the quoted prices) + the quote discount into the cart,
  // best-effort re-select the customer (quotes persist name/phone, not ids;
  // mechanic context is not stored on a quote), then clear the hand-off
  // provider. The provider is cleared up-front and guarded by a flag so a
  // rebuild or the build-time listener can never double-load.
  Future<void> _maybeConsumePendingQuote() async {
    if (_consumingPendingQuote) return;
    final pendingQuoteCubit = context.read<PendingQuoteCubit>();
    final pending = pendingQuoteCubit.state;
    if (pending == null) return;
    _consumingPendingQuote = true;
    pendingQuoteCubit.clear();
    final productsRepo = context.read<ProductsRepository>();
    final customersRepo = context.read<CustomersRepository>();
    try {
      final fresh = await productsRepo.getAll();
      // Build cart lines from the quote; pull partNo/nameTH/cost from the live
      // product. originalPrice = the quoted price, so no spurious override mark.
      final lines = <CartLine>[];
      for (final it in pending.items) {
        final p = fresh.where((x) => x.id == it.productId).firstOrNull;
        lines.add(
          CartLine(
            productId: it.productId ?? '',
            partNo: p?.partNo,
            name: it.name,
            nameTH: p?.nameTH,
            price: it.price,
            originalPrice: it.price,
            cost: p?.cost ?? 0,
            qty: it.qty,
          ),
        );
      }
      final res = _validateItems(lines, fresh);

      // Best-effort customer restore by phone (quotes store name+phone, not id).
      CustomerRow? cust;
      final phone = (pending.quote.customerPhone ?? '').trim();
      if (phone.isNotEmpty) {
        final customers = await customersRepo.getCustomers();
        cust = customers
            .where((c) => (c.phone ?? '').trim() == phone)
            .firstOrNull;
      }

      // Cart state is global (survives a teardown); load it before the mounted
      // guard so the items are never lost. Controllers/setState need mounted.
      _cart.setLines(res.safe);
      if (!mounted) return;
      _discount = pending.quote.discount ?? 0;
      _syncDiscountText();
      setState(() {
        if (cust != null) _selectedCustomer = cust;
        if (res.issues.isNotEmpty) {
          _priceWarning =
              'สต็อกเปลี่ยนแปลงตั้งแต่ออกใบเสนอ:\n${res.issues.join('\n')}';
        }
      });
    } finally {
      _consumingPendingQuote = false;
    }
  }

  // ── Cart state helpers ──
  void _clearSaleState() {
    _cart.clear();
    _cashCtrl.clear();
    _discount = 0;
    _syncDiscountText();
    setState(() {
      _selectedCustomer = null;
      _selectedMechanic = null;
      _payMethod = 'เงินสด';
    });
  }

  double get _subtotal => _cart.subtotal;
  double get _total =>
      (_subtotal - _discount) < 0 ? 0 : (_subtotal - _discount);

  ParkedInput _buildParkPayload(List<CartLine> cart) => ParkedInput(
    items: [
      for (final it in cart)
        SaleLineInput(
          productId: it.productId,
          name: it.name,
          qty: it.qty,
          price: it.price,
          partNo: it.partNo,
          nameTH: it.nameTH,
        ),
    ],
    discount: _discount,
    customerId: _selectedCustomer?.id,
    customerName: _selectedCustomer?.nameTH ?? '',
    mechanicId: _selectedMechanic?.id,
    mechanicName: _selectedMechanic?.nameTH ?? '',
    extra: {
      'total': _total,
      // Preserve the in-progress payment state so a resume restores it
      // instead of inheriting whatever is left over from the next cart.
      'paymentMethod': _payMethod,
      'cash': _cashCtrl.text,
      // Preserve per-line override context for an exact resume.
      'lines': [
        for (final it in cart)
          {
            'productId': it.productId,
            'partNo': it.partNo,
            'name': it.name,
            'nameTH': it.nameTH,
            'price': it.price,
            'originalPrice': it.originalPrice,
            'cost': it.cost,
            'qty': it.qty,
          },
      ],
    },
  );

  Future<void> _handlePark() async {
    if (_parkedBusy) return;
    final cart = _cart.state;
    if (cart.isEmpty) return;
    setState(() => _parkedBusy = true);
    try {
      await context.read<ParkedRepository>().parkSale(
        _buildParkPayload(cart),
      );
      if (!mounted) return;
      _refreshParked();
      _clearSaleState();
      _warn('⏸ พักบิลแล้ว — กดที่แถบด้านบนเพื่อเรียกคืน');
    } catch (e) {
      if (!mounted) return;
      _alert('พักบิลไม่สำเร็จ: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _parkedBusy = false);
    }
  }

  Future<void> _handleResume(ParkedSaleRow pk) async {
    if (_parkedBusy) return;
    setState(() => _parkedBusy = true);
    try {
      final parkedRepo = context.read<ParkedRepository>();
      final productsRepo = context.read<ProductsRepository>();
      final customersRepo = context.read<CustomersRepository>();
      final mechanicsRepo = context.read<MechanicsRepository>();

      final cart = _cart.state;
      final fresh = await productsRepo.getAll();
      if (!mounted) return;
      // Auto-park current cart first (swap) so nothing is lost — but tell
      // the cashier, so an in-progress cart doesn't just vanish silently.
      if (cart.isNotEmpty) {
        await parkedRepo.parkSale(_buildParkPayload(cart));
        if (!mounted) return;
        _warn('⏸ พักบิลปัจจุบันถูกพักอัตโนมัติก่อนเรียกคืนบิลนี้');
      }
      final lines = _decodeParkedLines(pk, fresh: fresh);
      final res = _validateItems(lines, fresh);
      final issues = [...res.issues];
      // CartCubit is global (survives a teardown of this screen) — load the
      // resumed lines now, before any further mounted-gated widget state, so
      // they're never lost even if the screen is torn down mid-resume.
      _cart.setLines(res.safe);

      final blob = _decodeBlob(pk);
      final discount = (blob['discount'] as num?)?.toDouble() ?? 0;
      final custId = blob['customerId'] as String?;
      final mechId = blob['mechanicId'] as String?;
      final payMethod = (blob['paymentMethod'] as String?) ?? 'เงินสด';
      final cash = (blob['cash'] as String?) ?? '';
      CustomerRow? cust;
      MechanicRow? mech;
      if (custId != null) {
        final all = await customersRepo.getCustomers();
        if (!mounted) return;
        cust = all.where((c) => c.id == custId).firstOrNull;
        if (cust == null) issues.add('ลูกค้าที่บันทึกไว้ถูกลบไปแล้ว');
      }
      if (mechId != null) {
        final all = await mechanicsRepo.getMechanics();
        if (!mounted) return;
        mech = all.where((m) => m.id == mechId).firstOrNull;
        if (mech == null) issues.add('ช่างที่บันทึกไว้ถูกลบไปแล้ว');
      }
      await parkedRepo.deleteParked(pk.id);
      if (!mounted) return;

      _refreshParked();
      _discount = discount;
      _syncDiscountText();
      _cashCtrl.text = cash;
      setState(() {
        _selectedCustomer = cust;
        _selectedMechanic = mech;
        _payMethod = payMethod;
        _priceWarning = issues.isNotEmpty
            ? 'ข้อมูลเปลี่ยนระหว่างพักบิล:\n${issues.join('\n')}'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      _alert('เรียกคืนบิลไม่สำเร็จ: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _parkedBusy = false);
    }
  }

  Future<void> _handleDeleteParked(ParkedSaleRow pk) async {
    if (_parkedBusy) return;
    final repo = context.read<ParkedRepository>();
    final lines = _decodeParkedLines(pk);
    final blob = _decodeBlob(pk);
    final total = (blob['total'] as num?)?.toDouble() ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('ลบบิลที่พัก (${lines.length} รายการ · ${baht(total)})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ลบ'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _parkedBusy = true);
    try {
      await repo.deleteParked(pk.id);
      if (!mounted) return;
      _refreshParked();
    } catch (e) {
      if (!mounted) return;
      _alert('ลบบิลที่พักไม่สำเร็จ: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _parkedBusy = false);
    }
  }

  Map<String, dynamic> _decodeBlob(ParkedSaleRow pk) {
    try {
      final decoded = jsonDecode(pk.payload);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// Decode parked lines, preferring the rich 'lines' blob (keeps override
  /// context) and falling back to the contract 'items' shape. [fresh], when
  /// given, backfills cost for the 'items' fallback (e.g. a legacy-imported
  /// parked bill) so the below-cost override guard still applies on resume.
  List<CartLine> _decodeParkedLines(
    ParkedSaleRow pk, {
    List<ProductRow>? fresh,
  }) {
    final blob = _decodeBlob(pk);
    final rich = blob['lines'];
    if (rich is List) {
      return [
        for (final l in rich)
          CartLine(
            productId: (l['productId'] ?? '').toString(),
            partNo: l['partNo'] as String?,
            name: (l['name'] ?? '').toString(),
            nameTH: l['nameTH'] as String?,
            price: (l['price'] as num?)?.toDouble() ?? 0,
            originalPrice:
                (l['originalPrice'] as num?)?.toDouble() ??
                (l['price'] as num?)?.toDouble() ??
                0,
            cost: (l['cost'] as num?)?.toDouble() ?? 0,
            qty: (l['qty'] as num?)?.toInt() ?? 0,
          ),
      ];
    }
    final items = blob['items'];
    if (items is List) {
      return [
        for (final l in items)
          CartLine(
            productId: (l['productId'] ?? '').toString(),
            partNo: l['partNo'] as String?,
            name: (l['name'] ?? '').toString(),
            nameTH: l['nameTH'] as String?,
            price: (l['price'] as num?)?.toDouble() ?? 0,
            originalPrice: (l['price'] as num?)?.toDouble() ?? 0,
            cost:
                fresh
                    ?.where((p) => p.id == (l['productId'] ?? '').toString())
                    .firstOrNull
                    ?.cost ??
                0,
            qty: (l['qty'] as num?)?.toInt() ?? 0,
          ),
      ];
    }
    return const [];
  }

  Future<void> _handleSaveQuote() async {
    final cart = _cart.state;
    if (cart.isEmpty) {
      _warn('ตะกร้าว่าง');
      return;
    }
    await context.read<QuotesRepository>().saveQuote(
      QuoteInput(
        subtotal: _subtotal,
        discount: _discount,
        total: _total,
        customerName: _selectedCustomer?.nameTH ?? '',
        customerPhone: _selectedCustomer?.phone ?? '',
        items: [
          for (final it in cart)
            QuoteLineInput(
              productId: it.productId,
              name: it.name,
              qty: it.qty,
              price: it.price,
            ),
        ],
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('บันทึกใบเสนอราคาแล้ว')));
  }

  Future<void> _handleCheckout() async {
    final salesRepo = context.read<SalesRepository>();
    final settingsRepo = context.read<SettingsRepository>();
    final customersRepo = context.read<CustomersRepository>();
    final cart = _cart.state;
    if (_submitting || cart.isEmpty) return;
    final subtotal = _subtotal;
    final total = _total;
    if (_discount > subtotal) {
      _alert('ส่วนลด ${baht(_discount)} เกินยอดรวม ${baht(subtotal)}');
      return;
    }
    final cash = double.tryParse(_cashCtrl.text.trim()) ?? 0;
    if (_payMethod == 'เงินสด' && cash < total) {
      _alert('รับเงินไม่ครบ');
      return;
    }
    // The counter's answer to 'ยืนยันขายเครดิต?', carried into SaleInput below.
    // It is a value rather than something the repository works out for itself
    // because consent cannot be re-derived: this screen tests the MechanicRow it
    // captured when its list loaded, and any later reader sees a different row
    // (a prior bill on this very screen moves it). See SaleInput.overrideCreditLimit.
    var overrideCreditLimit = false;
    if (_payMethod == 'เครดิตช่าง') {
      final m = _selectedMechanic;
      if (m == null) {
        _alert('ต้องเลือกช่างก่อนใช้เครดิต');
        return;
      }
      final newBal = m.creditBalance + total;
      if (newBal > m.creditLimit) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(
              'เกินวงเงินเครดิต! ยอดค้างใหม่ ${baht(newBal)} > วงเงิน ${baht(m.creditLimit)}\n\nยืนยันขายเครดิต?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('ยกเลิก'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('ยืนยัน'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        overrideCreditLimit = true;
      }
    }

    setState(() => _submitting = true);
    try {
      final mechanicDelta = round2(_cart.mechanicDelta);
      final sale = await salesRepo.saveSale(
        SaleInput(
          subtotal: subtotal,
          discount: _discount,
          total: total,
          paymentMethod: _payMethod,
          customerId: _selectedCustomer?.id,
          customerName: _selectedCustomer?.nameTH,
          mechanicId: _selectedMechanic?.id,
          mechanicName: _selectedMechanic?.nameTH,
          mechanicDelta: _selectedMechanic != null ? mechanicDelta : null,
          overrideCreditLimit: overrideCreditLimit,
          items: [
            for (final it in cart)
              SaleLineInput(
                productId: it.productId,
                name: it.name,
                qty: it.qty,
                price: it.price,
                partNo: it.partNo,
                nameTH: it.nameTH,
              ),
          ],
        ),
      );

      // Build receipt context from the just-completed sale (cart + cash/change).
      final receiptLines = [
        for (final it in cart)
          ReceiptLine(
            name: it.name,
            nameTH: it.nameTH,
            partNo: it.partNo,
            qty: it.qty,
            price: it.price,
          ),
      ];
      final settings = await settingsRepo.getSettings();
      // Re-fetch customer for updated point balance after the sale.
      int? custPoints;
      String? custName = _selectedCustomer?.nameTH;
      if (_selectedCustomer != null) {
        final all = await customersRepo.getCustomers();
        final c = all.where((x) => x.id == _selectedCustomer!.id).firstOrNull;
        custPoints = c?.points ?? _selectedCustomer!.points;
        custName = c?.nameTH ?? custName;
      }
      final change = _payMethod == 'เงินสด' && (cash - total) > 0
          ? (cash - total)
          : 0.0;
      final receiptData = ReceiptData(
        sale: sale,
        items: receiptLines,
        settings: settings,
        customerName: custName,
        customerPoints: custPoints,
        cashReceived: _payMethod == 'เงินสด'
            ? cash
            : (_payMethod == 'เครดิตช่าง' ? 0 : total),
        change: change,
      );

      // Reset sale state (mirrors JS post-checkout reset).
      _clearSaleState();
      if (!mounted) return;
      _refreshAfterSale();
      await showReceiptDialog(context, receiptData);
    } catch (e) {
      if (mounted) {
        setState(() {
          _productsFuture = context.read<ProductsRepository>().getAll();
        });
      }
      _alert('ขายไม่สำเร็จ: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _msg(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring('Exception: '.length) : s;
  }

  void _alert(String msg) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ตกลง'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.of(context).size.width >= AppBreakpoints.checkoutTwoPane;

    // Catch a quote staged while this screen is already alive; the initState
    // post-frame handles the normal fresh-build navigation case.
    return BlocListener<PendingQuoteCubit, QuoteWithItems?>(
      listener: (context, state) {
        if (state != null) _maybeConsumePendingQuote();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: FutureBuilder<List<ProductRow>>(
          future: _productsFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('โหลดสินค้าไม่สำเร็จ: ${snap.error}'));
            }
            final products = snap.data!;
            return Column(
              children: [
                _lowStockBanner(products),
                Expanded(
                  child: isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _leftPanel(products)),
                            const VerticalDivider(width: 1),
                            SizedBox(width: 400, child: _rightPanel(products)),
                          ],
                        )
                      : DefaultTabController(
                          length: 2,
                          child: Column(
                            children: [
                              const TabBar(
                                tabs: [
                                  Tab(text: 'สินค้า'),
                                  Tab(text: 'ตะกร้า'),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [
                                    _leftPanel(products),
                                    _rightPanel(products),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── LowStock banner (once per session) ──
  Widget _lowStockBanner(List<ProductRow> products) {
    if (lowStockShownThisSession || _lowStockDismissed) {
      return const SizedBox.shrink();
    }
    final buckets = lowStockBuckets(products);
    if (buckets.out.isEmpty && buckets.low.isEmpty) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<Map<String, String>>(
      future: _catColorsFuture,
      builder: (context, snap) {
        final catColors = snap.data ?? const <String, String>{};
        return LowStockBanner(
          outOfStock: buckets.out,
          lowStock: buckets.low,
          catColors: catColors,
          onClose: () {
            lowStockShownThisSession = true;
            setState(() => _lowStockDismissed = true);
          },
          onOrder: () {
            lowStockShownThisSession = true;
            setState(() => _lowStockDismissed = true);
            context.go(AppRoutes.purchaseOrders);
          },
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LEFT: products
  // ─────────────────────────────────────────────────────────────────────────
  Widget _leftPanel(List<ProductRow> products) {
    final q = _search.toLowerCase();
    final filtered = products.where((p) {
      final catOk = _filterZone == 'ทั้งหมด' || p.category == _filterZone;
      final searchOk =
          q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.nameTH.contains(q) ||
          p.partNo.toLowerCase().contains(q);
      return catOk && searchOk;
    }).toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FutureBuilder<Map<String, String>>(
      future: _catColorsFuture,
      builder: (context, catColorsSnap) {
        final catColors = catColorsSnap.data ?? const <String, String>{};
        return _leftPanelBody(products, filtered, catColors, isDark);
      },
    );
  }

  Widget _leftPanelBody(
    List<ProductRow> products,
    List<ProductRow> filtered,
    Map<String, String> catColors,
    bool isDark,
  ) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // ── Search area ──
          Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: TextField(
                    controller: _barcodeCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'สแกนบาร์โค้ด / รหัสอะไหล่',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      prefixIcon: Container(
                        padding: const EdgeInsets.all(10),
                        child: const Icon(
                          Icons.qr_code_scanner,
                          color: _orange,
                          size: 20,
                        ),
                      ),
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : AppColors.gray100.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: _orange,
                          width: 1.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _orange, width: 2),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _handleBarcode(products),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'ค้นหาชื่อสินค้า…',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                        size: 20,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : AppColors.gray100.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
              ],
            ),
          ),
          // ── Category chips ──
          FutureBuilder<List<String>>(
            future: _categoriesFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done ||
                  snap.hasError) {
                return const SizedBox(height: 8);
              }
              final all = ['ทั้งหมด', ...snap.data ?? const <String>[]];
              return SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final z in all)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _categoryChip(z, catColors),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          // ── Product grid ──
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search_off_rounded,
                          size: 56,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.2),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'ไม่พบสินค้า',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'ลองค้นหาด้วยคำอื่น หรือเปลี่ยนหมวดหมู่',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisExtent: 155,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) =>
                        _productTile(filtered[i], catColors),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _categoryChip(String name, Map<String, String> catColors) {
    final isSelected = _filterZone == name;
    final isAll = name == 'ทั้งหมด';
    final catColor = isAll
        ? _orange
        : (_parseColor(catColors[name]) ?? AppColors.navyLight);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => setState(() => _filterZone = name),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected ? catColor : catColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? catColor : catColor.withValues(alpha: 0.25),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Text(
              name,
              style: TextStyle(
                color: isSelected ? Colors.white : catColor,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _productTile(ProductRow p, Map<String, String> catColors) {
    final outOfStock = p.stock == 0;
    final catColor = _parseColor(catColors[p.category]) ?? AppColors.navyLight;
    final stockColor = p.stock == 0
        ? AppColors.error
        : (p.stock <= p.minStock ? _warnOrange : AppColors.successLight);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: outOfStock
              ? null
              : () {
                  final err = _cart.add(p);
                  if (err != null) _warn(err);
                },
          splashColor: _orange.withValues(alpha: 0.15),
          highlightColor: _orange.withValues(alpha: 0.05),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Product name
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.nameTH,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.partNo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: AppColors.steelBlue.withValues(alpha: 0.8),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            baht(p.price),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: _orange,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: stockColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: stockColor.withValues(alpha: 0.4),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              p.stock > 0 ? '${p.stock}' : 'หมด',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: stockColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Category badge — top right
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: catColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    p.category,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // Out-of-stock overlay
              if (outOfStock)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black : Colors.white).withValues(
                        alpha: 0.65,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.error,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'สินค้าหมด',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleBarcode(List<ProductRow> products) {
    final val = _barcodeCtrl.text.trim();
    if (val.isEmpty) return;
    final p = products
        .where((p) => p.partNo.toLowerCase() == val.toLowerCase())
        .firstOrNull;
    if (p != null) {
      final err = _cart.add(p);
      if (err != null) _warn(err);
      _barcodeCtrl.clear();
    } else {
      _alert('ไม่พบรหัส: $val');
      _barcodeCtrl.clear();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // RIGHT: cart + payment
  // ─────────────────────────────────────────────────────────────────────────
  Widget _rightPanel(List<ProductRow> products) {
    final cart = context.watch<CartCubit>().state;
    final mechanicDelta = _cart.mechanicDelta;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Theme.of(context).colorScheme.surfaceContainerLowest
            : const Color(0xFFF8F6F2),
        border: Border(
          left: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: ListView(
        children: [
          // Parked strip
          FutureBuilder<List<ParkedSaleRow>>(
            future: _parkedFuture,
            builder: (context, snap) {
              final parked = snap.data ?? const <ParkedSaleRow>[];
              return parked.isEmpty
                  ? const SizedBox.shrink()
                  : _parkedStrip(parked);
            },
          ),
          _customerSection(),
          _mechanicSection(),
          _cartSection(cart, products),
          _totalsSection(cart, mechanicDelta),
          _paymentSection(),
          _actionButtons(cart),
        ],
      ),
    );
  }

  Widget _section({required Widget child}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.12),
        ),
      ),
    ),
    child: child,
  );

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: _orange,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          t,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    ),
  );

  Widget _parkedStrip(List<ParkedSaleRow> parked) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _warnOrange.withValues(alpha: 0.08),
            _warnOrange.withValues(alpha: 0.03),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border(
          bottom: BorderSide(color: _warnOrange.withValues(alpha: 0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('⏸ บิลที่พัก (${parked.length})'),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemCount: parked.length,
              itemBuilder: (ctx, i) => _parkedChip(parked[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _parkedChip(ParkedSaleRow pk) {
    final lines = _decodeParkedLines(pk);
    final blob = _decodeBlob(pk);
    final total = (blob['total'] as num?)?.toDouble() ?? 0;
    final custName = (blob['customerName'] as String?)?.trim();
    final mechName = (blob['mechanicName'] as String?)?.trim();
    final firstName = lines.isNotEmpty ? lines.first.name : 'บิล';
    final title = (custName?.isNotEmpty == true)
        ? custName!
        : (mechName?.isNotEmpty == true ? mechName! : firstName);
    final suffix = lines.length > 1 ? ' +${lines.length - 1}' : '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _handleResume(pk),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _warnOrange.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color: _warnOrange.withValues(alpha: 0.08),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_long, size: 15, color: _warnOrange),
              const SizedBox(width: 6),
              Text(
                '$title$suffix',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                baht(total),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _warnOrange,
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _handleDeleteParked(pk),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Customer ──
  Widget _customerSection() {
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('ลูกค้า'),
          if (_selectedCustomer != null)
            _selectedChip(
              icon: Icons.person,
              title: _selectedCustomer!.nameTH,
              subtitle:
                  '${_selectedCustomer!.phone ?? ''} · ${_selectedCustomer!.points} แต้ม',
              onClear: () => setState(() => _selectedCustomer = null),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _custSearchCtrl,
                  decoration: InputDecoration(
                    hintText: 'ค้นหาลูกค้า / เบอร์โทร…',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                    prefixIcon: Icon(
                      Icons.person_search,
                      size: 18,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.3),
                      ),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (v) => setState(() => _custSearch = v),
                ),
                if (_custSearch.isNotEmpty)
                  FutureBuilder<List<CustomerRow>>(
                    future: _customersFuture,
                    builder: (context, snap) {
                      if (!snap.hasData) return const SizedBox.shrink();
                      final customers = snap.data!;
                      final q = _custSearch.toLowerCase();
                      final list = customers
                          .where(
                            (c) =>
                                c.name.toLowerCase().contains(q) ||
                                c.nameTH.contains(q) ||
                                (c.phone ?? '').contains(q) ||
                                c.code.toLowerCase().contains(q),
                          )
                          .take(4)
                          .toList();
                      if (list.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'ไม่พบลูกค้า',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        );
                      }
                      return Container(
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            for (final c in list)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  _custSearchCtrl.clear();
                                  setState(() {
                                    _selectedCustomer = c;
                                    _custSearch = '';
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 14,
                                        backgroundColor: AppColors.steelBlue
                                            .withValues(alpha: 0.15),
                                        child: Icon(
                                          Icons.person,
                                          size: 14,
                                          color: AppColors.steelBlue,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          c.nameTH,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        c.phone ?? '',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Mechanic ──
  Widget _mechanicSection() {
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('🔧 ช่าง (ปรับราคาช่าง)'),
          if (_selectedMechanic != null)
            _selectedChip(
              icon: Icons.build,
              title:
                  '${_selectedMechanic!.nameTH ?? _selectedMechanic!.name} (${_selectedMechanic!.code})',
              subtitle:
                  _selectedMechanic!.shopName ?? _selectedMechanic!.phone ?? '',
              highlight: true,
              onClear: () => setState(() => _selectedMechanic = null),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _mechSearchCtrl,
                  decoration: InputDecoration(
                    hintText: 'ค้นหาช่าง / ชื่อเล่น / เบอร์…',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                    prefixIcon: Icon(
                      Icons.build,
                      size: 18,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.3),
                      ),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (v) => setState(() => _mechSearch = v),
                ),
                if (_mechSearch.isNotEmpty)
                  FutureBuilder<List<MechanicRow>>(
                    future: _mechanicsFuture,
                    builder: (context, snap) {
                      if (!snap.hasData) return const SizedBox.shrink();
                      final mechanics = snap.data!;
                      final q = _mechSearch.toLowerCase();
                      final list = mechanics
                          .where(
                            (m) =>
                                (m.nameTH ?? '').contains(q) ||
                                (m.nickname ?? '').contains(q) ||
                                (m.phone ?? '').contains(q) ||
                                m.code.toLowerCase().contains(q) ||
                                (m.shopName ?? '').toLowerCase().contains(q),
                          )
                          .take(5)
                          .toList();
                      if (list.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'ไม่พบช่าง — เพิ่มในเมนู "ช่าง"',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        );
                      }
                      return Container(
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            for (final m in list)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  _mechSearchCtrl.clear();
                                  setState(() {
                                    _selectedMechanic = m;
                                    _mechSearch = '';
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 14,
                                        backgroundColor: _orange.withValues(
                                          alpha: 0.12,
                                        ),
                                        child: const Icon(
                                          Icons.build,
                                          size: 14,
                                          color: _orange,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          m.nameTH ?? m.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        m.shopName ?? m.phone ?? '',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _selectedChip({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onClear,
    bool highlight = false,
  }) {
    final accentColor = highlight ? _orange : AppColors.steelBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: highlight ? 0.08 : 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: accentColor.withValues(alpha: highlight ? 0.35 : 0.2),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: accentColor.withValues(alpha: 0.15),
            child: Icon(icon, size: 16, color: accentColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close, size: 14),
              onPressed: onClear,
            ),
          ),
        ],
      ),
    );
  }

  // ── Cart items ──
  Widget _cartSection(List<CartLine> cart, List<ProductRow> products) {
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _label('รายการสินค้า (${cart.length})')),
              if (_selectedMechanic != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'คลิกราคาเพื่อปรับ',
                      style: TextStyle(
                        color: _orange,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (cart.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: [
                  Icon(
                    Icons.shopping_cart_outlined,
                    size: 40,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.15),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'ยังไม่มีสินค้า',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'สแกนหรือเลือกสินค้าด้านซ้าย',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [for (final it in cart) _cartRow(it, products)],
              ),
            ),
          if (_priceWarning != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.error),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '⚠ $_priceWarning',
                      style: const TextStyle(
                        color: Color(0xFFFF8B7A),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _clearWarn,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Color(0xFFFF8B7A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cartRow(CartLine item, List<ProductRow> products) {
    final isEditing = _editingPriceId == item.productId;
    final product = products.where((p) => p.id == item.productId).firstOrNull;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (item.partNo != null)
                  Text(
                    item.partNo!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: AppColors.steelBlue.withValues(alpha: 0.7),
                    ),
                  ),
                const SizedBox(height: 3),
                _linePriceControl(item, isEditing),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // qty control — pill shape
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _qtyBtn(Icons.remove, () {
                  final err = _cart.setQty(
                    item.productId,
                    item.qty - 1,
                    product,
                  );
                  if (err != null) _warn(err);
                }),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 28),
                  child: Text(
                    '${item.qty}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                _qtyBtn(Icons.add, () {
                  final err = _cart.setQty(
                    item.productId,
                    item.qty + 1,
                    product,
                  );
                  if (err != null) _warn(err);
                }),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 65),
            child: MoneyText(
              item.price * item.qty,
              scaleDown: true,
              color: _orange,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linePriceControl(CartLine item, bool isEditing) {
    if (isEditing) {
      final ctrl = TextEditingController(text: item.price.toString());
      return SizedBox(
        width: 90,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _orange, width: 2),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _orange, width: 2),
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          ),
          onSubmitted: (v) => _commitPrice(item.productId, v),
          onTapOutside: (_) => _commitPrice(item.productId, ctrl.text),
        ),
      );
    }
    final mechSel = _selectedMechanic != null;
    final priceButton = OutlinedButton(
      onPressed: mechSel
          ? () => setState(() => _editingPriceId = item.productId)
          : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: const Size(0, 28),
        side: BorderSide(
          color: item.overridden ? _orange : Theme.of(context).dividerColor,
        ),
        backgroundColor: item.overridden
            ? _orange.withValues(alpha: 0.18)
            : null,
        foregroundColor: item.overridden
            ? _orange
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      ),
      child: Text(
        '${baht(item.price)}${item.overridden ? ' ✎' : ''}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
    if (!item.overridden) {
      return Align(alignment: Alignment.centerLeft, child: priceButton);
    }
    // Overridden: keep the "ปกติ ฿…" annotation + reset on a SECOND line so the
    // button and its annotation never have to share one line in the narrow
    // (~140–180dp) cart name column — the old single Row overflowed here.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        priceButton,
        const SizedBox(height: 2),
        Row(
          children: [
            Flexible(
              child: Text(
                'ปกติ ${baht(item.originalPrice)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  decoration: TextDecoration.lineThrough,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            TapTarget(
              onTap: () => _cart.resetPrice(item.productId),
              child: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  void _commitPrice(String productId, String value) {
    final p = double.tryParse(value) ?? 0;
    final err = _cart.setPrice(productId, p);
    setState(() => _editingPriceId = null);
    if (err != null) _warn(err);
  }

  // 30dp visual chip kept, but TapTarget gives it a ≥44dp hit area — these are
  // the most-tapped controls on a touch POS.
  Widget _qtyBtn(IconData icon, VoidCallback onTap) => TapTarget(
    onTap: onTap,
    child: Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: 16,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      ),
    ),
  );

  // ── Totals ──
  Widget _totalsSection(List<CartLine> cart, double mechanicDelta) {
    final subtotal = _subtotal;
    final total = _total;
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _totalRow('ยอดรวม', baht(subtotal)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ส่วนลด',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _discountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    prefixText: '฿',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.3),
                      ),
                    ),
                    hintText: '0',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (v) {
                    final raw = double.tryParse(v) ?? 0;
                    final d = raw < 0 ? 0.0 : (raw > subtotal ? subtotal : raw);
                    setState(() => _discount = d);
                    if (d != raw) {
                      _syncDiscountText();
                      _discountCtrl.selection = TextSelection.collapsed(
                        offset: _discountCtrl.text.length,
                      );
                    }
                  },
                ),
              ),
            ],
          ),
          if (_selectedMechanic != null && mechanicDelta.abs() > 0.01) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: mechanicDelta > 0
                    ? AppColors.successLight.withValues(alpha: 0.1)
                    : _warnOrange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: mechanicDelta > 0
                      ? AppColors.successLight.withValues(alpha: 0.25)
                      : _warnOrange.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    mechanicDelta > 0
                        ? '↑ ช่างได้ส่วนต่าง'
                        : '↓ เครดิตช่าง (ลดราคา)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: mechanicDelta > 0
                          ? const Color(0xFF2ECC71)
                          : _warnOrange,
                    ),
                  ),
                  Text(
                    '${mechanicDelta > 0 ? '+' : ''}${baht(mechanicDelta.abs())}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: mechanicDelta > 0
                          ? const Color(0xFF2ECC71)
                          : _warnOrange,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Grand total — navy gradient container
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.navyDeep, AppColors.navyMid],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: AppColors.navy.withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'รวมทั้งสิ้น',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                Text(
                  baht(total),
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String l, String r) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        l,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
      Text(
        r,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    ],
  );

  // ── Payment ──
  Widget _paymentSection() {
    final total = _total;
    final baseMethods = ['เงินสด', 'โอน/QR'];
    final methods = _selectedMechanic != null
        ? [...baseMethods, 'เครดิตช่าง']
        : baseMethods;

    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('ชำระเงิน'),
          // Segmented-control-style payment buttons
          Container(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                for (var i = 0; i < methods.length; i++)
                  Expanded(child: _payButton(methods[i], total)),
              ],
            ),
          ),
          if (_payMethod == 'เครดิตช่าง' && _selectedMechanic != null)
            _creditPanel(total),
          if (_payMethod == 'เงินสด') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _cashCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                hintText: 'รับเงิน ฿…',
                hintStyle: TextStyle(
                  fontSize: 20,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.3),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _orange, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final v in _quickCash(total))
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _quickBtn(v),
                    ),
                  ),
              ],
            ),
            _changeRow(total),
          ],
        ],
      ),
    );
  }

  Widget _payButton(String m, double total) {
    final isCredit = m == 'เครดิตช่าง';
    final active = _payMethod == m;
    final wouldExceed =
        isCredit &&
        _selectedMechanic != null &&
        (_selectedMechanic!.creditBalance + total) >
            _selectedMechanic!.creditLimit;
    final IconData icon = m == 'เงินสด'
        ? Icons.payments_outlined
        : m == 'โอน/QR'
        ? Icons.qr_code
        : Icons.credit_score;

    return GestureDetector(
      onTap: () => setState(() => _payMethod = m),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: active
              ? (isCredit ? _warnOrange : _orange)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: (isCredit ? _warnOrange : _orange).withValues(
                      alpha: 0.2,
                    ),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: active
                  ? Colors.white
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 3),
            Text(
              '$m${wouldExceed ? ' ⚠' : ''}',
              style: TextStyle(
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                fontSize: 11,
                color: active
                    ? Colors.white
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _creditPanel(double total) {
    final m = _selectedMechanic!;
    final after = m.creditBalance + total;
    final exceed = after > m.creditLimit;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _warnOrange.withValues(alpha: 0.07),
        border: Border.all(color: _warnOrange.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _creditRow('ยอดค้างเดิม', baht(m.creditBalance)),
          const SizedBox(height: 6),
          _creditRow('+ บิลนี้', baht(total)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Color(0x66D4820A),
                  style: BorderStyle.solid,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ยอดค้างหลังบิลนี้',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: _warnOrange,
                  ),
                ),
                Text(
                  baht(after),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: _warnOrange,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'วงเงิน ${baht(m.creditLimit)}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          if (exceed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '⚠ เกินวงเงินเครดิต!',
                style: TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _creditRow(String l, String r) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        l,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      Text(
        r,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    ],
  );

  List<num> _quickCash(double total) {
    final raw = <num>[
      total,
      (total / 100).ceil() * 100,
      (total / 500).ceil() * 500,
      1000,
    ];
    final seen = <num>{};
    final out = <num>[];
    for (final v in raw) {
      if (v >= total && !seen.contains(v)) {
        seen.add(v);
        out.add(v);
      }
    }
    return out.take(4).toList();
  }

  Widget _quickBtn(num v) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        _cashCtrl.text = v.toString();
        setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            baht(v),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ),
      ),
    ),
  );

  Widget _changeRow(double total) {
    final cash = double.tryParse(_cashCtrl.text.trim()) ?? 0;
    final change = cash - total;
    if (_cashCtrl.text.isEmpty || change < 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2ECC71).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF2ECC71).withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'เงินทอน',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF2ECC71),
            ),
          ),
          Text(
            baht(change),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: Color(0xFF2ECC71),
            ),
          ),
        ],
      ),
    );
  }

  // ── Action buttons ──
  Widget _actionButtons(List<CartLine> cart) {
    final empty = cart.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: empty ? null : _handlePark,
                  icon: const Icon(Icons.pause_circle_outline, size: 18),
                  label: const Text(
                    'พักบิล',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _warnOrange,
                    side: BorderSide(
                      color: _warnOrange.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: empty ? null : _handleSaveQuote,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text(
                    'ใบเสนอราคา',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF5B97F0),
                    side: BorderSide(
                      color: const Color(0xFF2A6FDB).withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Checkout button — gradient + glow
          SizedBox(
            width: double.infinity,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: (empty || _submitting)
                      ? [Colors.grey.shade400, Colors.grey.shade500]
                      : [_orange, AppColors.orangeDark],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: (empty || _submitting)
                    ? null
                    : [
                        BoxShadow(
                          color: _orange.withValues(alpha: 0.35),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: (empty || _submitting) ? null : _handleCheckout,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _submitting
                              ? Icons.hourglass_top
                              : Icons.check_circle,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _submitting
                              ? 'กำลังบันทึก…'
                              : 'ชำระเงิน  ${baht(_total)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            letterSpacing: 0.3,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color? _parseColor(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}
