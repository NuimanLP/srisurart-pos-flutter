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
// Cart state is a StateNotifier defined IN THIS FILE (cartProvider). All data
// goes through the §4 repo providers; no direct AppDatabase access.
//
// NOTE (cross-screen quote loading): the JS screen accepted loadQuote/
// onQuoteLoaded props from QuotesManager. The Flutter router constructs
// `const CheckoutScreen()` with no args, so converting a quote into the cart is
// not wired here (QuotesScreen is a separate agent). Park/resume re-validation
// is fully self-contained.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/money.dart';
import '../../data/db/database.dart';
import '../../domain/models/aggregates.dart';
import '../providers/providers.dart';
import '../widgets/low_stock_alert.dart';
import '../widgets/receipt_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Cart line + cart StateNotifier (in-file UI state, per §4 allowance).
// ─────────────────────────────────────────────────────────────────────────────

/// One cart line. Mirrors the JS cart item shape (productId, partNo, name,
/// nameTH, price, originalPrice, cost, qty).
class CartLine {
  final String productId;
  final String? partNo;
  final String name;
  final String? nameTH;
  final double price;
  final double originalPrice;
  final double cost;
  final int qty;

  const CartLine({
    required this.productId,
    this.partNo,
    required this.name,
    this.nameTH,
    required this.price,
    required this.originalPrice,
    required this.cost,
    required this.qty,
  });

  CartLine copyWith({double? price, int? qty}) => CartLine(
        productId: productId,
        partNo: partNo,
        name: name,
        nameTH: nameTH,
        price: price ?? this.price,
        originalPrice: originalPrice,
        cost: cost,
        qty: qty ?? this.qty,
      );

  bool get overridden => price != originalPrice;
}

class CartNotifier extends Notifier<List<CartLine>> {
  @override
  List<CartLine> build() => const [];

  double get subtotal =>
      state.fold(0, (s, i) => s + i.price * i.qty);
  double get originalSubtotal =>
      state.fold(0, (s, i) => s + i.originalPrice * i.qty);
  double get mechanicDelta =>
      state.fold(0, (s, i) => s + (i.price - i.originalPrice) * i.qty);

  void clear() => state = const [];

  void setLines(List<CartLine> lines) => state = lines;

  /// Add one unit of [p]. Returns an error string when it would exceed stock,
  /// else null (mirrors JS addToCart's stock-cap warning).
  String? add(ProductRow p) {
    final existing =
        state.where((i) => i.productId == p.id).firstOrNull;
    final newQty = (existing?.qty ?? 0) + 1;
    if (newQty > p.stock) {
      return 'สต็อก "${p.name}" เหลือเพียง ${p.stock} ชิ้น';
    }
    if (existing != null) {
      state = [
        for (final i in state)
          i.productId == p.id ? i.copyWith(qty: newQty) : i
      ];
    } else {
      state = [
        ...state,
        CartLine(
          productId: p.id,
          partNo: p.partNo,
          name: p.name,
          nameTH: p.nameTH,
          price: p.price,
          originalPrice: p.price,
          cost: p.cost,
          qty: 1,
        ),
      ];
    }
    return null;
  }

  /// Set qty; qty<=0 removes the line. Returns an error when over stock.
  String? setQty(String productId, int qty, ProductRow? product) {
    if (qty <= 0) {
      state = state.where((i) => i.productId != productId).toList();
      return null;
    }
    if (product != null && qty > product.stock) {
      return 'สต็อก "${product.name}" เหลือเพียง ${product.stock} ชิ้น';
    }
    state = [
      for (final i in state)
        i.productId == productId ? i.copyWith(qty: qty) : i
    ];
    return null;
  }

  /// Price override — blocks below cost. Returns an error string when blocked.
  String? setPrice(String productId, double newPrice) {
    final item = state.where((i) => i.productId == productId).firstOrNull;
    if (item == null) return null;
    if (newPrice < item.cost) {
      return 'ราคา ฿$newPrice ต่ำกว่าทุน ฿${item.cost} — ห้ามขายต่ำกว่าทุน';
    }
    state = [
      for (final i in state)
        i.productId == productId ? i.copyWith(price: newPrice) : i
    ];
    return null;
  }

  void resetPrice(String productId) {
    state = [
      for (final i in state)
        i.productId == productId
            ? i.copyWith(price: i.originalPrice)
            : i
    ];
  }
}

final cartProvider =
    NotifierProvider<CartNotifier, List<CartLine>>(CartNotifier.new);

// Reactive data providers (re-fetchable via ref.invalidate after a write).
final _productsProvider = FutureProvider.autoDispose<List<ProductRow>>(
    (ref) => ref.watch(productsRepoProvider).getAll());
final _customersProvider = FutureProvider.autoDispose<List<CustomerRow>>(
    (ref) => ref.watch(customersRepoProvider).getCustomers());
final _mechanicsProvider = FutureProvider.autoDispose<List<MechanicRow>>(
    (ref) => ref.watch(mechanicsRepoProvider).getMechanics());
final _categoriesProvider = FutureProvider.autoDispose<List<String>>(
    (ref) => ref.watch(productsRepoProvider).getCategories());
final _parkedProvider = FutureProvider.autoDispose<List<ParkedSaleRow>>(
    (ref) => ref.watch(parkedRepoProvider).getParked());
final _catColorsProvider = FutureProvider.autoDispose<Map<String, String>>(
    (ref) async {
  final repo = ref.watch(productsRepoProvider);
  final cats = await repo.getCategories();
  final out = <String, String>{};
  for (final c in cats) {
    out[c] = await repo.catColor(c);
  }
  return out;
});

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

const _orange = Color(0xFFE8601C);
const _warnOrange = Color(0xFFD4820A);

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _barcodeCtrl = TextEditingController();
  final _custSearchCtrl = TextEditingController();
  final _mechSearchCtrl = TextEditingController();
  final _cashCtrl = TextEditingController();

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
  String? _priceWarning;
  bool _lowStockDismissed = false;

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    _custSearchCtrl.dispose();
    _mechSearchCtrl.dispose();
    _cashCtrl.dispose();
    super.dispose();
  }

  void _warn(String msg) {
    setState(() => _priceWarning = msg);
  }

  void _clearWarn() {
    if (_priceWarning != null) setState(() => _priceWarning = null);
  }

  CartNotifier get _cart => ref.read(cartProvider.notifier);

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

  // ── Cart state helpers ──
  void _clearSaleState() {
    _cart.clear();
    _cashCtrl.clear();
    setState(() {
      _discount = 0;
      _selectedCustomer = null;
      _selectedMechanic = null;
      _payMethod = 'เงินสด';
    });
  }

  double get _subtotal => _cart.subtotal;
  double get _total => (_subtotal - _discount) < 0 ? 0 : (_subtotal - _discount);

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
            )
        ],
        discount: _discount,
        customerId: _selectedCustomer?.id,
        customerName: _selectedCustomer?.nameTH ?? '',
        mechanicId: _selectedMechanic?.id,
        mechanicName: _selectedMechanic?.nameTH ?? '',
        extra: {
          'total': _total,
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
              }
          ],
        },
      );

  Future<void> _handlePark() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    await ref.read(parkedRepoProvider).parkSale(_buildParkPayload(cart));
    ref.invalidate(_parkedProvider);
    _clearSaleState();
    _warn('⏸ พักบิลแล้ว — กดที่แถบด้านบนเพื่อเรียกคืน');
  }

  Future<void> _handleResume(ParkedSaleRow pk) async {
    final cart = ref.read(cartProvider);
    final fresh = await ref.read(productsRepoProvider).getAll();
    // Auto-park current cart first (swap) so nothing is lost.
    if (cart.isNotEmpty) {
      await ref.read(parkedRepoProvider).parkSale(_buildParkPayload(cart));
    }
    final lines = _decodeParkedLines(pk);
    final res = _validateItems(lines, fresh);
    _cart.setLines(res.safe);

    final blob = _decodeBlob(pk);
    final discount = (blob['discount'] as num?)?.toDouble() ?? 0;
    final custId = blob['customerId'] as String?;
    final mechId = blob['mechanicId'] as String?;
    CustomerRow? cust;
    MechanicRow? mech;
    if (custId != null) {
      final all = await ref.read(customersRepoProvider).getCustomers();
      cust = all.where((c) => c.id == custId).firstOrNull;
    }
    if (mechId != null) {
      final all = await ref.read(mechanicsRepoProvider).getMechanics();
      mech = all.where((m) => m.id == mechId).firstOrNull;
    }
    await ref.read(parkedRepoProvider).deleteParked(pk.id);
    ref.invalidate(_parkedProvider);
    if (!mounted) return;
    setState(() {
      _discount = discount;
      _selectedCustomer = cust;
      _selectedMechanic = mech;
      _priceWarning = res.issues.isNotEmpty
          ? 'สต็อกเปลี่ยนระหว่างพักบิล:\n${res.issues.join('\n')}'
          : _priceWarning;
    });
  }

  Future<void> _handleDeleteParked(ParkedSaleRow pk) async {
    final lines = _decodeParkedLines(pk);
    final blob = _decodeBlob(pk);
    final total = (blob['total'] as num?)?.toDouble() ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
            'ลบบิลที่พัก (${lines.length} รายการ · ${baht(total)})?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('ยกเลิก')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ลบ')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(parkedRepoProvider).deleteParked(pk.id);
    ref.invalidate(_parkedProvider);
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
  /// context) and falling back to the contract 'items' shape.
  List<CartLine> _decodeParkedLines(ParkedSaleRow pk) {
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
            originalPrice: (l['originalPrice'] as num?)?.toDouble() ??
                (l['price'] as num?)?.toDouble() ??
                0,
            cost: (l['cost'] as num?)?.toDouble() ?? 0,
            qty: (l['qty'] as num?)?.toInt() ?? 0,
          )
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
            cost: 0,
            qty: (l['qty'] as num?)?.toInt() ?? 0,
          )
      ];
    }
    return const [];
  }

  Future<void> _handleSaveQuote() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      _warn('ตะกร้าว่าง');
      return;
    }
    await ref.read(quotesRepoProvider).saveQuote(QuoteInput(
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
                  price: it.price)
          ],
        ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('บันทึกใบเสนอราคาแล้ว')),
    );
  }

  Future<void> _handleCheckout() async {
    final cart = ref.read(cartProvider);
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
                'เกินวงเงินเครดิต! ยอดค้างใหม่ ${baht(newBal)} > วงเงิน ${baht(m.creditLimit)}\n\nยืนยันขายเครดิต?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('ยกเลิก')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('ยืนยัน')),
            ],
          ),
        );
        if (ok != true) return;
      }
    }

    setState(() => _submitting = true);
    try {
      final mechanicDelta = round2(_cart.mechanicDelta);
      final sale = await ref.read(salesRepoProvider).saveSale(SaleInput(
            subtotal: subtotal,
            discount: _discount,
            total: total,
            paymentMethod: _payMethod,
            customerId: _selectedCustomer?.id,
            customerName: _selectedCustomer?.nameTH,
            mechanicId: _selectedMechanic?.id,
            mechanicName: _selectedMechanic?.nameTH,
            mechanicDelta: _selectedMechanic != null ? mechanicDelta : null,
            items: [
              for (final it in cart)
                SaleLineInput(
                  productId: it.productId,
                  name: it.name,
                  qty: it.qty,
                  price: it.price,
                  partNo: it.partNo,
                  nameTH: it.nameTH,
                )
            ],
          ));

      // Build receipt context from the just-completed sale (cart + cash/change).
      final receiptLines = [
        for (final it in cart)
          ReceiptLine(
              name: it.name,
              nameTH: it.nameTH,
              partNo: it.partNo,
              qty: it.qty,
              price: it.price)
      ];
      final settings = await ref.read(settingsRepoProvider).getSettings();
      // Re-fetch customer for updated point balance after the sale.
      int? custPoints;
      String? custName = _selectedCustomer?.nameTH;
      if (_selectedCustomer != null) {
        final all = await ref.read(customersRepoProvider).getCustomers();
        final c =
            all.where((x) => x.id == _selectedCustomer!.id).firstOrNull;
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
      ref.invalidate(_productsProvider);
      ref.invalidate(_mechanicsProvider);
      ref.invalidate(_customersProvider);

      if (!mounted) return;
      await showReceiptDialog(context, receiptData);
    } catch (e) {
      ref.invalidate(_productsProvider);
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
              onPressed: () => Navigator.pop(ctx), child: const Text('ตกลง')),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(_productsProvider);
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('โหลดสินค้าไม่สำเร็จ: $e')),
        data: (products) {
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
                            const TabBar(tabs: [
                              Tab(text: 'สินค้า'),
                              Tab(text: 'ตะกร้า'),
                            ]),
                            Expanded(
                              child: TabBarView(children: [
                                _leftPanel(products),
                                _rightPanel(products),
                              ]),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
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
    return LowStockBanner(
      outOfStock: buckets.out,
      lowStock: buckets.low,
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
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LEFT: products
  // ─────────────────────────────────────────────────────────────────────────
  Widget _leftPanel(List<ProductRow> products) {
    final q = _search.toLowerCase();
    final filtered = products.where((p) {
      final catOk = _filterZone == 'ทั้งหมด' || p.category == _filterZone;
      final searchOk = q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.nameTH.contains(q) ||
          p.partNo.toLowerCase().contains(q);
      return catOk && searchOk;
    }).toList();

    final catsAsync = ref.watch(_categoriesProvider);
    final catColors = ref.watch(_catColorsProvider).asData?.value ?? const {};

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // Search row
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: TextField(
                    controller: _barcodeCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '🔍 สแกนบาร์โค้ด / รหัสอะไหล่ (Enter)',
                      border: OutlineInputBorder(),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: _orange, width: 2),
                      ),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _handleBarcode(products),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'ค้นหาชื่อสินค้า…',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
              ],
            ),
          ),
          // Category chips
          catsAsync.when(
            loading: () => const SizedBox(height: 8),
            error: (_, _) => const SizedBox(height: 8),
            data: (cats) {
              final all = ['ทั้งหมด', ...cats];
              return SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    for (final z in all)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(z),
                          selected: _filterZone == z,
                          onSelected: (_) => setState(() => _filterZone = z),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          // Product grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(14),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisExtent: 150,
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

  Widget _productTile(ProductRow p, Map<String, String> catColors) {
    final outOfStock = p.stock == 0;
    final catColor = _parseColor(catColors[p.category]) ?? AppColors.navyLight;
    final stockColor = p.stock == 0
        ? AppColors.error
        : (p.stock <= p.minStock ? _warnOrange : AppColors.successLight);
    return Opacity(
      opacity: outOfStock ? 0.35 : 1,
      child: InkWell(
        onTap: outOfStock
            ? null
            : () {
                final err = _cart.add(p);
                if (err != null) _warn(err);
              },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: catColor,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(p.category,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 6),
              Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
              Text(p.nameTH,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7))),
              Text(p.partNo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11, color: _orange)),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(baht(p.price),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            color: _orange)),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(p.stock > 0 ? '${p.stock} ชิ้น' : 'หมด',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: stockColor)),
                  ),
                ],
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
    final cart = ref.watch(cartProvider);
    final parkedAsync = ref.watch(_parkedProvider);
    final mechanicDelta = _cart.mechanicDelta;

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: ListView(
        children: [
          // Parked strip
          parkedAsync.maybeWhen(
            data: (parked) =>
                parked.isEmpty ? const SizedBox.shrink() : _parkedStrip(parked),
            orElse: () => const SizedBox.shrink(),
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
                  color:
                      Theme.of(context).dividerColor.withValues(alpha: 0.4))),
        ),
        child: child,
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7))),
      );

  Widget _parkedStrip(List<ParkedSaleRow> parked) {
    return Container(
      color: _warnOrange.withValues(alpha: 0.07),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('⏸ บิลที่พัก · Parked (${parked.length})'),
          for (final pk in parked) _parkedRow(pk),
        ],
      ),
    );
  }

  Widget _parkedRow(ParkedSaleRow pk) {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _handleResume(pk),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: _warnOrange.withValues(alpha: 0.45)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text('$title$suffix',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    Text('${_hhmm(pk.parkedAt)} · ${baht(total)}',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'ลบบิลที่พัก',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _handleDeleteParked(pk),
          ),
        ],
      ),
    );
  }

  // ── Customer ──
  Widget _customerSection() {
    final custAsync = ref.watch(_customersProvider);
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('ลูกค้า · Customer'),
          if (_selectedCustomer != null)
            _selectedChip(
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
                  decoration: const InputDecoration(
                    hintText: 'ค้นหาลูกค้า / เบอร์โทร…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _custSearch = v),
                ),
                if (_custSearch.isNotEmpty)
                  custAsync.maybeWhen(
                    data: (customers) {
                      final q = _custSearch.toLowerCase();
                      final list = customers
                          .where((c) =>
                              c.name.toLowerCase().contains(q) ||
                              c.nameTH.contains(q) ||
                              (c.phone ?? '').contains(q) ||
                              c.code.toLowerCase().contains(q))
                          .take(4)
                          .toList();
                      if (list.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('ไม่พบลูกค้า',
                              style: TextStyle(fontSize: 12)),
                        );
                      }
                      return Column(
                        children: [
                          for (final c in list)
                            ListTile(
                              dense: true,
                              title: Text(c.nameTH),
                              trailing: Text(c.phone ?? '',
                                  style: const TextStyle(fontSize: 11)),
                              onTap: () {
                                _custSearchCtrl.clear();
                                setState(() {
                                  _selectedCustomer = c;
                                  _custSearch = '';
                                });
                              },
                            ),
                        ],
                      );
                    },
                    orElse: () => const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Mechanic ──
  Widget _mechanicSection() {
    final mechAsync = ref.watch(_mechanicsProvider);
    return _section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('🔧 ช่าง · Mechanic (ถ้ามี — เพื่อปรับราคาช่าง)'),
          if (_selectedMechanic != null)
            _selectedChip(
              title: '🔧 ${_selectedMechanic!.nameTH ?? _selectedMechanic!.name} (${_selectedMechanic!.code})',
              subtitle: _selectedMechanic!.shopName ??
                  _selectedMechanic!.phone ??
                  '',
              highlight: true,
              onClear: () => setState(() => _selectedMechanic = null),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _mechSearchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'ค้นหาช่าง / ชื่อเล่น / เบอร์…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _mechSearch = v),
                ),
                if (_mechSearch.isNotEmpty)
                  mechAsync.maybeWhen(
                    data: (mechanics) {
                      final q = _mechSearch.toLowerCase();
                      final list = mechanics
                          .where((m) =>
                              (m.nameTH ?? '').contains(q) ||
                              (m.nickname ?? '').contains(q) ||
                              (m.phone ?? '').contains(q) ||
                              m.code.toLowerCase().contains(q) ||
                              (m.shopName ?? '').toLowerCase().contains(q))
                          .take(5)
                          .toList();
                      if (list.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('ไม่พบช่าง — เพิ่มในเมนู "ช่าง"',
                              style: TextStyle(fontSize: 12)),
                        );
                      }
                      return Column(
                        children: [
                          for (final m in list)
                            ListTile(
                              dense: true,
                              title: Text('🔧 ${m.nameTH ?? m.name}'),
                              trailing: Text(m.shopName ?? m.phone ?? '',
                                  style: const TextStyle(fontSize: 11)),
                              onTap: () {
                                _mechSearchCtrl.clear();
                                setState(() {
                                  _selectedMechanic = m;
                                  _mechSearch = '';
                                });
                              },
                            ),
                        ],
                      );
                    },
                    orElse: () => const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _selectedChip({
    required String title,
    required String subtitle,
    required VoidCallback onClear,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: highlight
            ? _orange.withValues(alpha: 0.15)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: highlight
            ? Border.all(color: _orange.withValues(alpha: 0.4))
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
                if (subtitle.isNotEmpty)
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7))),
              ],
            ),
          ),
          IconButton(
              icon: const Icon(Icons.close, size: 18), onPressed: onClear),
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
              Expanded(child: _label('รายการสินค้า · Items (${cart.length})')),
              if (_selectedMechanic != null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text('· คลิกราคาเพื่อปรับ',
                      style: TextStyle(
                          color: _orange,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          if (cart.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('ยังไม่มีสินค้า\nสแกนหรือเลือกสินค้าด้านซ้าย',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5))),
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
                    child: Text('⚠ $_priceWarning',
                        style: const TextStyle(
                            color: Color(0xFFFF8B7A),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  InkWell(
                    onTap: _clearWarn,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.close,
                          size: 16, color: Color(0xFFFF8B7A)),
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
    final product =
        products.where((p) => p.id == item.productId).firstOrNull;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                if (item.partNo != null)
                  Text(item.partNo!,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: _orange)),
                const SizedBox(height: 4),
                _linePriceControl(item, isEditing),
              ],
            ),
          ),
          // qty control
          Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _qtyBtn(Icons.remove, () {
                    final err = _cart.setQty(
                        item.productId, item.qty - 1, product);
                    if (err != null) _warn(err);
                  }),
                  Container(
                    width: 28,
                    alignment: Alignment.center,
                    child: Text('${item.qty}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  _qtyBtn(Icons.add, () {
                    final err = _cart.setQty(
                        item.productId, item.qty + 1, product);
                    if (err != null) _warn(err);
                  }),
                ],
              ),
            ],
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(baht(item.price * item.qty),
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: _orange)),
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
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
          ],
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _orange, width: 2)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _orange, width: 2)),
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          ),
          onSubmitted: (v) => _commitPrice(item.productId, v),
          onTapOutside: (_) => _commitPrice(item.productId, ctrl.text),
        ),
      );
    }
    final mechSel = _selectedMechanic != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton(
          onPressed: mechSel
              ? () => setState(() => _editingPriceId = item.productId)
              : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            minimumSize: const Size(0, 28),
            side: BorderSide(
                color: item.overridden ? _orange : Theme.of(context).dividerColor,
                style: item.overridden ? BorderStyle.solid : BorderStyle.solid),
            backgroundColor: item.overridden
                ? _orange.withValues(alpha: 0.18)
                : null,
            foregroundColor: item.overridden
                ? _orange
                : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
          child: Text('${baht(item.price)}${item.overridden ? ' ✎' : ''}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
        ),
        if (item.overridden) ...[
          const SizedBox(width: 6),
          Text('ปกติ ${baht(item.originalPrice)}',
              style: TextStyle(
                  fontSize: 11,
                  decoration: TextDecoration.lineThrough,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5))),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _cart.resetPrice(item.productId),
          ),
        ],
      ],
    );
  }

  void _commitPrice(String productId, String value) {
    final p = double.tryParse(value) ?? 0;
    final err = _cart.setPrice(productId, p);
    setState(() => _editingPriceId = null);
    if (err != null) _warn(err);
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 18),
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
              Text('ส่วนลด',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7))),
              SizedBox(
                width: 110,
                child: TextField(
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  textAlign: TextAlign.right,
                  decoration: const InputDecoration(
                    prefixText: '฿',
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '0',
                  ),
                  onChanged: (v) {
                    final raw = double.tryParse(v) ?? 0;
                    final d = raw < 0 ? 0.0 : (raw > subtotal ? subtotal : raw);
                    setState(() => _discount = d);
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
                    ? AppColors.successLight.withValues(alpha: 0.12)
                    : _warnOrange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: mechanicDelta > 0
                        ? AppColors.successLight.withValues(alpha: 0.3)
                        : _warnOrange.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                      mechanicDelta > 0
                          ? '↑ ช่างได้ส่วนต่าง'
                          : '↓ เครดิตช่าง (ลดราคา)',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: mechanicDelta > 0
                              ? const Color(0xFF2ECC71)
                              : _warnOrange)),
                  Text(
                      '${mechanicDelta > 0 ? '+' : ''}${baht(mechanicDelta.abs())}',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: mechanicDelta > 0
                              ? const Color(0xFF2ECC71)
                              : _warnOrange)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: Theme.of(context).dividerColor, width: 2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('รวมทั้งสิ้น',
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
                Text(baht(total),
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _orange)),
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
          Text(l,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7))),
          Text(r,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
          _label('ชำระเงิน · Payment'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in methods) _payButton(m, total),
            ],
          ),
          if (_payMethod == 'เครดิตช่าง' && _selectedMechanic != null)
            _creditPanel(total),
          if (_payMethod == 'เงินสด') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _cashCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
              ],
              textAlign: TextAlign.right,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                hintText: 'รับเงิน ฿…',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final v in _quickCash(total)) _quickBtn(v)],
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
    final wouldExceed = isCredit &&
        _selectedMechanic != null &&
        (_selectedMechanic!.creditBalance + total) >
            _selectedMechanic!.creditLimit;
    final Color border = isCredit ? _warnOrange : Theme.of(context).dividerColor;
    return OutlinedButton(
      onPressed: () => setState(() => _payMethod = m),
      style: OutlinedButton.styleFrom(
        backgroundColor: active
            ? (isCredit ? _warnOrange : Theme.of(context).colorScheme.surfaceContainerHigh)
            : null,
        foregroundColor: active
            ? (isCredit ? Colors.white : Theme.of(context).colorScheme.onSurface)
            : (isCredit ? _warnOrange : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
        side: BorderSide(color: border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Text(
          '${isCredit ? '🔧 ' : ''}$m${wouldExceed ? ' ⚠' : ''}',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
    );
  }

  Widget _creditPanel(double total) {
    final m = _selectedMechanic!;
    final after = m.creditBalance + total;
    final exceed = after > m.creditLimit;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _warnOrange.withValues(alpha: 0.1),
        border: Border.all(color: _warnOrange.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
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
                      style: BorderStyle.solid)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('ยอดค้างหลังบิลนี้',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: _warnOrange)),
                Text(baht(after),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: _warnOrange)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text('วงเงิน ${baht(m.creditLimit)}',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5))),
          if (exceed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('⚠ เกินวงเงินเครดิต!',
                  style: TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }

  Widget _creditRow(String l, String r) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7))),
          Text(r,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7))),
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

  Widget _quickBtn(num v) => InkWell(
        onTap: () {
          _cashCtrl.text = v.toString();
          setState(() {});
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(baht(v),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      );

  Widget _changeRow(double total) {
    final cash = double.tryParse(_cashCtrl.text.trim()) ?? 0;
    final change = cash - total;
    if (_cashCtrl.text.isEmpty || change < 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          const Text('เงินทอน: ',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          Text(baht(change),
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: Color(0xFF2ECC71))),
        ],
      ),
    );
  }

  // ── Action buttons ──
  Widget _actionButtons(List<CartLine> cart) {
    final empty = cart.isEmpty;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: empty ? null : _handlePark,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE0A33C),
                    side: const BorderSide(color: _warnOrange, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('⏸ พักบิล',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: empty ? null : _handleSaveQuote,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF5B97F0),
                    side: const BorderSide(color: Color(0xFF2A6FDB), width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('📋 บันทึกใบเสนอราคา',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (empty || _submitting) ? null : _handleCheckout,
              style: FilledButton.styleFrom(
                backgroundColor: _orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _submitting
                    ? '⏳ กำลังบันทึก…'
                    : '✓ ชำระเงิน · CHECKOUT — ${baht(_total)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 19,
                    letterSpacing: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── helpers ──
  String _hhmm(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }
}

Color? _parseColor(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}
