// CartCubit — checkout cart state. flutter_bloc port of CartNotifier
// (formerly in checkout_screen.dart). Self-contained: no repository/context
// dependency, pure synchronous mutations, every mutation creates a new List
// instance (so Cubit's `==` emit-skip never suppresses a rebuild). Validation
// methods (add/setQty/setPrice) return a String? error alongside emitting,
// mirroring the JS addToCart/setQty/setPrice stock/cost guards.

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/db/database.dart';

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

class CartCubit extends Cubit<List<CartLine>> {
  CartCubit() : super(const []);

  double get subtotal => state.fold(0, (s, i) => s + i.price * i.qty);
  double get originalSubtotal =>
      state.fold(0, (s, i) => s + i.originalPrice * i.qty);
  double get mechanicDelta =>
      state.fold(0, (s, i) => s + (i.price - i.originalPrice) * i.qty);

  void clear() => emit(const []);

  void setLines(List<CartLine> lines) => emit(lines);

  /// Add one unit of [p]. Returns an error string when it would exceed stock,
  /// else null (mirrors JS addToCart's stock-cap warning).
  String? add(ProductRow p) {
    final existing = state.where((i) => i.productId == p.id).firstOrNull;
    final newQty = (existing?.qty ?? 0) + 1;
    if (newQty > p.stock) {
      return 'สต็อก "${p.name}" เหลือเพียง ${p.stock} ชิ้น';
    }
    if (existing != null) {
      emit([
        for (final i in state)
          i.productId == p.id ? i.copyWith(qty: newQty) : i,
      ]);
    } else {
      emit([
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
      ]);
    }
    return null;
  }

  /// Set qty; qty<=0 removes the line. Returns an error when over stock.
  String? setQty(String productId, int qty, ProductRow? product) {
    if (qty <= 0) {
      emit(state.where((i) => i.productId != productId).toList());
      return null;
    }
    if (product != null && qty > product.stock) {
      return 'สต็อก "${product.name}" เหลือเพียง ${product.stock} ชิ้น';
    }
    emit([
      for (final i in state)
        i.productId == productId ? i.copyWith(qty: qty) : i,
    ]);
    return null;
  }

  /// Price override — blocks below cost. Returns an error string when blocked.
  String? setPrice(String productId, double newPrice) {
    final item = state.where((i) => i.productId == productId).firstOrNull;
    if (item == null) return null;
    if (newPrice < item.cost) {
      return 'ราคา ฿$newPrice ต่ำกว่าทุน ฿${item.cost} — ห้ามขายต่ำกว่าทุน';
    }
    emit([
      for (final i in state)
        i.productId == productId ? i.copyWith(price: newPrice) : i,
    ]);
    return null;
  }

  void resetPrice(String productId) {
    emit([
      for (final i in state)
        i.productId == productId ? i.copyWith(price: i.originalPrice) : i,
    ]);
  }
}
