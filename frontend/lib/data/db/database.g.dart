// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ProductsTable extends Products
    with TableInfo<$ProductsTable, ProductRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProductsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _partNoMeta = const VerificationMeta('partNo');
  @override
  late final GeneratedColumn<String> partNo = GeneratedColumn<String>(
    'part_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameTHMeta = const VerificationMeta('nameTH');
  @override
  late final GeneratedColumn<String> nameTH = GeneratedColumn<String>(
    'name_t_h',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _brandMeta = const VerificationMeta('brand');
  @override
  late final GeneratedColumn<String> brand = GeneratedColumn<String>(
    'brand',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<double> price = GeneratedColumn<double>(
    'price',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _costMeta = const VerificationMeta('cost');
  @override
  late final GeneratedColumn<double> cost = GeneratedColumn<double>(
    'cost',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stockMeta = const VerificationMeta('stock');
  @override
  late final GeneratedColumn<int> stock = GeneratedColumn<int>(
    'stock',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _minStockMeta = const VerificationMeta(
    'minStock',
  );
  @override
  late final GeneratedColumn<int> minStock = GeneratedColumn<int>(
    'min_stock',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _compatMeta = const VerificationMeta('compat');
  @override
  late final GeneratedColumn<String> compat = GeneratedColumn<String>(
    'compat',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _zoneMeta = const VerificationMeta('zone');
  @override
  late final GeneratedColumn<String> zone = GeneratedColumn<String>(
    'zone',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _offlineOkMeta = const VerificationMeta(
    'offlineOk',
  );
  @override
  late final GeneratedColumn<bool> offlineOk = GeneratedColumn<bool>(
    'offline_ok',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("offline_ok" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    partNo,
    name,
    nameTH,
    category,
    brand,
    price,
    cost,
    stock,
    minStock,
    compat,
    zone,
    updatedAt,
    offlineOk,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'products';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProductRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('part_no')) {
      context.handle(
        _partNoMeta,
        partNo.isAcceptableOrUnknown(data['part_no']!, _partNoMeta),
      );
    } else if (isInserting) {
      context.missing(_partNoMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_t_h')) {
      context.handle(
        _nameTHMeta,
        nameTH.isAcceptableOrUnknown(data['name_t_h']!, _nameTHMeta),
      );
    } else if (isInserting) {
      context.missing(_nameTHMeta);
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('brand')) {
      context.handle(
        _brandMeta,
        brand.isAcceptableOrUnknown(data['brand']!, _brandMeta),
      );
    } else if (isInserting) {
      context.missing(_brandMeta);
    }
    if (data.containsKey('price')) {
      context.handle(
        _priceMeta,
        price.isAcceptableOrUnknown(data['price']!, _priceMeta),
      );
    } else if (isInserting) {
      context.missing(_priceMeta);
    }
    if (data.containsKey('cost')) {
      context.handle(
        _costMeta,
        cost.isAcceptableOrUnknown(data['cost']!, _costMeta),
      );
    } else if (isInserting) {
      context.missing(_costMeta);
    }
    if (data.containsKey('stock')) {
      context.handle(
        _stockMeta,
        stock.isAcceptableOrUnknown(data['stock']!, _stockMeta),
      );
    } else if (isInserting) {
      context.missing(_stockMeta);
    }
    if (data.containsKey('min_stock')) {
      context.handle(
        _minStockMeta,
        minStock.isAcceptableOrUnknown(data['min_stock']!, _minStockMeta),
      );
    } else if (isInserting) {
      context.missing(_minStockMeta);
    }
    if (data.containsKey('compat')) {
      context.handle(
        _compatMeta,
        compat.isAcceptableOrUnknown(data['compat']!, _compatMeta),
      );
    }
    if (data.containsKey('zone')) {
      context.handle(
        _zoneMeta,
        zone.isAcceptableOrUnknown(data['zone']!, _zoneMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('offline_ok')) {
      context.handle(
        _offlineOkMeta,
        offlineOk.isAcceptableOrUnknown(data['offline_ok']!, _offlineOkMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProductRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProductRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      partNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_no'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameTH: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_t_h'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      )!,
      brand: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}brand'],
      )!,
      price: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}price'],
      )!,
      cost: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost'],
      )!,
      stock: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stock'],
      )!,
      minStock: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}min_stock'],
      )!,
      compat: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}compat'],
      ),
      zone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}zone'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
      offlineOk: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}offline_ok'],
      )!,
    );
  }

  @override
  $ProductsTable createAlias(String alias) {
    return $ProductsTable(attachedDatabase, alias);
  }
}

class ProductRow extends DataClass implements Insertable<ProductRow> {
  final String id;
  final String partNo;
  final String name;
  final String nameTH;
  final String category;
  final String brand;
  final double price;
  final double cost;
  final int stock;
  final int minStock;
  final String? compat;
  final String? zone;
  final DateTime? updatedAt;

  /// Schema v3 (ADR-0010): may this line be sold while the client is degraded?
  /// Written ONLY from a server response — never derived here. Defaults to
  /// false so an unknown product is not sellable offline.
  final bool offlineOk;
  const ProductRow({
    required this.id,
    required this.partNo,
    required this.name,
    required this.nameTH,
    required this.category,
    required this.brand,
    required this.price,
    required this.cost,
    required this.stock,
    required this.minStock,
    this.compat,
    this.zone,
    this.updatedAt,
    required this.offlineOk,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['part_no'] = Variable<String>(partNo);
    map['name'] = Variable<String>(name);
    map['name_t_h'] = Variable<String>(nameTH);
    map['category'] = Variable<String>(category);
    map['brand'] = Variable<String>(brand);
    map['price'] = Variable<double>(price);
    map['cost'] = Variable<double>(cost);
    map['stock'] = Variable<int>(stock);
    map['min_stock'] = Variable<int>(minStock);
    if (!nullToAbsent || compat != null) {
      map['compat'] = Variable<String>(compat);
    }
    if (!nullToAbsent || zone != null) {
      map['zone'] = Variable<String>(zone);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    map['offline_ok'] = Variable<bool>(offlineOk);
    return map;
  }

  ProductsCompanion toCompanion(bool nullToAbsent) {
    return ProductsCompanion(
      id: Value(id),
      partNo: Value(partNo),
      name: Value(name),
      nameTH: Value(nameTH),
      category: Value(category),
      brand: Value(brand),
      price: Value(price),
      cost: Value(cost),
      stock: Value(stock),
      minStock: Value(minStock),
      compat: compat == null && nullToAbsent
          ? const Value.absent()
          : Value(compat),
      zone: zone == null && nullToAbsent ? const Value.absent() : Value(zone),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      offlineOk: Value(offlineOk),
    );
  }

  factory ProductRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProductRow(
      id: serializer.fromJson<String>(json['id']),
      partNo: serializer.fromJson<String>(json['partNo']),
      name: serializer.fromJson<String>(json['name']),
      nameTH: serializer.fromJson<String>(json['nameTH']),
      category: serializer.fromJson<String>(json['category']),
      brand: serializer.fromJson<String>(json['brand']),
      price: serializer.fromJson<double>(json['price']),
      cost: serializer.fromJson<double>(json['cost']),
      stock: serializer.fromJson<int>(json['stock']),
      minStock: serializer.fromJson<int>(json['minStock']),
      compat: serializer.fromJson<String?>(json['compat']),
      zone: serializer.fromJson<String?>(json['zone']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      offlineOk: serializer.fromJson<bool>(json['offlineOk']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'partNo': serializer.toJson<String>(partNo),
      'name': serializer.toJson<String>(name),
      'nameTH': serializer.toJson<String>(nameTH),
      'category': serializer.toJson<String>(category),
      'brand': serializer.toJson<String>(brand),
      'price': serializer.toJson<double>(price),
      'cost': serializer.toJson<double>(cost),
      'stock': serializer.toJson<int>(stock),
      'minStock': serializer.toJson<int>(minStock),
      'compat': serializer.toJson<String?>(compat),
      'zone': serializer.toJson<String?>(zone),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'offlineOk': serializer.toJson<bool>(offlineOk),
    };
  }

  ProductRow copyWith({
    String? id,
    String? partNo,
    String? name,
    String? nameTH,
    String? category,
    String? brand,
    double? price,
    double? cost,
    int? stock,
    int? minStock,
    Value<String?> compat = const Value.absent(),
    Value<String?> zone = const Value.absent(),
    Value<DateTime?> updatedAt = const Value.absent(),
    bool? offlineOk,
  }) => ProductRow(
    id: id ?? this.id,
    partNo: partNo ?? this.partNo,
    name: name ?? this.name,
    nameTH: nameTH ?? this.nameTH,
    category: category ?? this.category,
    brand: brand ?? this.brand,
    price: price ?? this.price,
    cost: cost ?? this.cost,
    stock: stock ?? this.stock,
    minStock: minStock ?? this.minStock,
    compat: compat.present ? compat.value : this.compat,
    zone: zone.present ? zone.value : this.zone,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    offlineOk: offlineOk ?? this.offlineOk,
  );
  ProductRow copyWithCompanion(ProductsCompanion data) {
    return ProductRow(
      id: data.id.present ? data.id.value : this.id,
      partNo: data.partNo.present ? data.partNo.value : this.partNo,
      name: data.name.present ? data.name.value : this.name,
      nameTH: data.nameTH.present ? data.nameTH.value : this.nameTH,
      category: data.category.present ? data.category.value : this.category,
      brand: data.brand.present ? data.brand.value : this.brand,
      price: data.price.present ? data.price.value : this.price,
      cost: data.cost.present ? data.cost.value : this.cost,
      stock: data.stock.present ? data.stock.value : this.stock,
      minStock: data.minStock.present ? data.minStock.value : this.minStock,
      compat: data.compat.present ? data.compat.value : this.compat,
      zone: data.zone.present ? data.zone.value : this.zone,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      offlineOk: data.offlineOk.present ? data.offlineOk.value : this.offlineOk,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProductRow(')
          ..write('id: $id, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('category: $category, ')
          ..write('brand: $brand, ')
          ..write('price: $price, ')
          ..write('cost: $cost, ')
          ..write('stock: $stock, ')
          ..write('minStock: $minStock, ')
          ..write('compat: $compat, ')
          ..write('zone: $zone, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('offlineOk: $offlineOk')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    partNo,
    name,
    nameTH,
    category,
    brand,
    price,
    cost,
    stock,
    minStock,
    compat,
    zone,
    updatedAt,
    offlineOk,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProductRow &&
          other.id == this.id &&
          other.partNo == this.partNo &&
          other.name == this.name &&
          other.nameTH == this.nameTH &&
          other.category == this.category &&
          other.brand == this.brand &&
          other.price == this.price &&
          other.cost == this.cost &&
          other.stock == this.stock &&
          other.minStock == this.minStock &&
          other.compat == this.compat &&
          other.zone == this.zone &&
          other.updatedAt == this.updatedAt &&
          other.offlineOk == this.offlineOk);
}

class ProductsCompanion extends UpdateCompanion<ProductRow> {
  final Value<String> id;
  final Value<String> partNo;
  final Value<String> name;
  final Value<String> nameTH;
  final Value<String> category;
  final Value<String> brand;
  final Value<double> price;
  final Value<double> cost;
  final Value<int> stock;
  final Value<int> minStock;
  final Value<String?> compat;
  final Value<String?> zone;
  final Value<DateTime?> updatedAt;
  final Value<bool> offlineOk;
  final Value<int> rowid;
  const ProductsCompanion({
    this.id = const Value.absent(),
    this.partNo = const Value.absent(),
    this.name = const Value.absent(),
    this.nameTH = const Value.absent(),
    this.category = const Value.absent(),
    this.brand = const Value.absent(),
    this.price = const Value.absent(),
    this.cost = const Value.absent(),
    this.stock = const Value.absent(),
    this.minStock = const Value.absent(),
    this.compat = const Value.absent(),
    this.zone = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.offlineOk = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProductsCompanion.insert({
    required String id,
    required String partNo,
    required String name,
    required String nameTH,
    required String category,
    required String brand,
    required double price,
    required double cost,
    required int stock,
    required int minStock,
    this.compat = const Value.absent(),
    this.zone = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.offlineOk = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       partNo = Value(partNo),
       name = Value(name),
       nameTH = Value(nameTH),
       category = Value(category),
       brand = Value(brand),
       price = Value(price),
       cost = Value(cost),
       stock = Value(stock),
       minStock = Value(minStock);
  static Insertable<ProductRow> custom({
    Expression<String>? id,
    Expression<String>? partNo,
    Expression<String>? name,
    Expression<String>? nameTH,
    Expression<String>? category,
    Expression<String>? brand,
    Expression<double>? price,
    Expression<double>? cost,
    Expression<int>? stock,
    Expression<int>? minStock,
    Expression<String>? compat,
    Expression<String>? zone,
    Expression<DateTime>? updatedAt,
    Expression<bool>? offlineOk,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (partNo != null) 'part_no': partNo,
      if (name != null) 'name': name,
      if (nameTH != null) 'name_t_h': nameTH,
      if (category != null) 'category': category,
      if (brand != null) 'brand': brand,
      if (price != null) 'price': price,
      if (cost != null) 'cost': cost,
      if (stock != null) 'stock': stock,
      if (minStock != null) 'min_stock': minStock,
      if (compat != null) 'compat': compat,
      if (zone != null) 'zone': zone,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (offlineOk != null) 'offline_ok': offlineOk,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProductsCompanion copyWith({
    Value<String>? id,
    Value<String>? partNo,
    Value<String>? name,
    Value<String>? nameTH,
    Value<String>? category,
    Value<String>? brand,
    Value<double>? price,
    Value<double>? cost,
    Value<int>? stock,
    Value<int>? minStock,
    Value<String?>? compat,
    Value<String?>? zone,
    Value<DateTime?>? updatedAt,
    Value<bool>? offlineOk,
    Value<int>? rowid,
  }) {
    return ProductsCompanion(
      id: id ?? this.id,
      partNo: partNo ?? this.partNo,
      name: name ?? this.name,
      nameTH: nameTH ?? this.nameTH,
      category: category ?? this.category,
      brand: brand ?? this.brand,
      price: price ?? this.price,
      cost: cost ?? this.cost,
      stock: stock ?? this.stock,
      minStock: minStock ?? this.minStock,
      compat: compat ?? this.compat,
      zone: zone ?? this.zone,
      updatedAt: updatedAt ?? this.updatedAt,
      offlineOk: offlineOk ?? this.offlineOk,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (partNo.present) {
      map['part_no'] = Variable<String>(partNo.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameTH.present) {
      map['name_t_h'] = Variable<String>(nameTH.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (brand.present) {
      map['brand'] = Variable<String>(brand.value);
    }
    if (price.present) {
      map['price'] = Variable<double>(price.value);
    }
    if (cost.present) {
      map['cost'] = Variable<double>(cost.value);
    }
    if (stock.present) {
      map['stock'] = Variable<int>(stock.value);
    }
    if (minStock.present) {
      map['min_stock'] = Variable<int>(minStock.value);
    }
    if (compat.present) {
      map['compat'] = Variable<String>(compat.value);
    }
    if (zone.present) {
      map['zone'] = Variable<String>(zone.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (offlineOk.present) {
      map['offline_ok'] = Variable<bool>(offlineOk.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProductsCompanion(')
          ..write('id: $id, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('category: $category, ')
          ..write('brand: $brand, ')
          ..write('price: $price, ')
          ..write('cost: $cost, ')
          ..write('stock: $stock, ')
          ..write('minStock: $minStock, ')
          ..write('compat: $compat, ')
          ..write('zone: $zone, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('offlineOk: $offlineOk, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CategoriesTable extends Categories
    with TableInfo<$CategoriesTable, CategoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [name, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'categories';
  @override
  VerificationContext validateIntegrity(
    Insertable<CategoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  CategoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CategoryRow(
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $CategoriesTable createAlias(String alias) {
    return $CategoriesTable(attachedDatabase, alias);
  }
}

class CategoryRow extends DataClass implements Insertable<CategoryRow> {
  final String name;
  final int position;
  const CategoryRow({required this.name, required this.position});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['position'] = Variable<int>(position);
    return map;
  }

  CategoriesCompanion toCompanion(bool nullToAbsent) {
    return CategoriesCompanion(name: Value(name), position: Value(position));
  }

  factory CategoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CategoryRow(
      name: serializer.fromJson<String>(json['name']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'position': serializer.toJson<int>(position),
    };
  }

  CategoryRow copyWith({String? name, int? position}) =>
      CategoryRow(name: name ?? this.name, position: position ?? this.position);
  CategoryRow copyWithCompanion(CategoriesCompanion data) {
    return CategoryRow(
      name: data.name.present ? data.name.value : this.name,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CategoryRow(')
          ..write('name: $name, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CategoryRow &&
          other.name == this.name &&
          other.position == this.position);
}

class CategoriesCompanion extends UpdateCompanion<CategoryRow> {
  final Value<String> name;
  final Value<int> position;
  final Value<int> rowid;
  const CategoriesCompanion({
    this.name = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CategoriesCompanion.insert({
    required String name,
    required int position,
    this.rowid = const Value.absent(),
  }) : name = Value(name),
       position = Value(position);
  static Insertable<CategoryRow> custom({
    Expression<String>? name,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CategoriesCompanion copyWith({
    Value<String>? name,
    Value<int>? position,
    Value<int>? rowid,
  }) {
    return CategoriesCompanion(
      name: name ?? this.name,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CategoriesCompanion(')
          ..write('name: $name, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CustomersTable extends Customers
    with TableInfo<$CustomersTable, CustomerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CustomersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameTHMeta = const VerificationMeta('nameTH');
  @override
  late final GeneratedColumn<String> nameTH = GeneratedColumn<String>(
    'name_t_h',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _phoneMeta = const VerificationMeta('phone');
  @override
  late final GeneratedColumn<String> phone = GeneratedColumn<String>(
    'phone',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pointsMeta = const VerificationMeta('points');
  @override
  late final GeneratedColumn<int> points = GeneratedColumn<int>(
    'points',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalSpendMeta = const VerificationMeta(
    'totalSpend',
  );
  @override
  late final GeneratedColumn<double> totalSpend = GeneratedColumn<double>(
    'total_spend',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    code,
    name,
    nameTH,
    phone,
    address,
    points,
    totalSpend,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'customers';
  @override
  VerificationContext validateIntegrity(
    Insertable<CustomerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_t_h')) {
      context.handle(
        _nameTHMeta,
        nameTH.isAcceptableOrUnknown(data['name_t_h']!, _nameTHMeta),
      );
    } else if (isInserting) {
      context.missing(_nameTHMeta);
    }
    if (data.containsKey('phone')) {
      context.handle(
        _phoneMeta,
        phone.isAcceptableOrUnknown(data['phone']!, _phoneMeta),
      );
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    }
    if (data.containsKey('points')) {
      context.handle(
        _pointsMeta,
        points.isAcceptableOrUnknown(data['points']!, _pointsMeta),
      );
    }
    if (data.containsKey('total_spend')) {
      context.handle(
        _totalSpendMeta,
        totalSpend.isAcceptableOrUnknown(data['total_spend']!, _totalSpendMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CustomerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CustomerRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameTH: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_t_h'],
      )!,
      phone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phone'],
      ),
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      ),
      points: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}points'],
      )!,
      totalSpend: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total_spend'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $CustomersTable createAlias(String alias) {
    return $CustomersTable(attachedDatabase, alias);
  }
}

class CustomerRow extends DataClass implements Insertable<CustomerRow> {
  final String id;
  final String code;
  final String name;
  final String nameTH;
  final String? phone;
  final String? address;
  final int points;
  final double totalSpend;
  final String createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  const CustomerRow({
    required this.id,
    required this.code,
    required this.name,
    required this.nameTH,
    this.phone,
    this.address,
    required this.points,
    required this.totalSpend,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['code'] = Variable<String>(code);
    map['name'] = Variable<String>(name);
    map['name_t_h'] = Variable<String>(nameTH);
    if (!nullToAbsent || phone != null) {
      map['phone'] = Variable<String>(phone);
    }
    if (!nullToAbsent || address != null) {
      map['address'] = Variable<String>(address);
    }
    map['points'] = Variable<int>(points);
    map['total_spend'] = Variable<double>(totalSpend);
    map['created_at'] = Variable<String>(createdAt);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  CustomersCompanion toCompanion(bool nullToAbsent) {
    return CustomersCompanion(
      id: Value(id),
      code: Value(code),
      name: Value(name),
      nameTH: Value(nameTH),
      phone: phone == null && nullToAbsent
          ? const Value.absent()
          : Value(phone),
      address: address == null && nullToAbsent
          ? const Value.absent()
          : Value(address),
      points: Value(points),
      totalSpend: Value(totalSpend),
      createdAt: Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory CustomerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CustomerRow(
      id: serializer.fromJson<String>(json['id']),
      code: serializer.fromJson<String>(json['code']),
      name: serializer.fromJson<String>(json['name']),
      nameTH: serializer.fromJson<String>(json['nameTH']),
      phone: serializer.fromJson<String?>(json['phone']),
      address: serializer.fromJson<String?>(json['address']),
      points: serializer.fromJson<int>(json['points']),
      totalSpend: serializer.fromJson<double>(json['totalSpend']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'code': serializer.toJson<String>(code),
      'name': serializer.toJson<String>(name),
      'nameTH': serializer.toJson<String>(nameTH),
      'phone': serializer.toJson<String?>(phone),
      'address': serializer.toJson<String?>(address),
      'points': serializer.toJson<int>(points),
      'totalSpend': serializer.toJson<double>(totalSpend),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  CustomerRow copyWith({
    String? id,
    String? code,
    String? name,
    String? nameTH,
    Value<String?> phone = const Value.absent(),
    Value<String?> address = const Value.absent(),
    int? points,
    double? totalSpend,
    String? createdAt,
    Value<DateTime?> updatedAt = const Value.absent(),
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => CustomerRow(
    id: id ?? this.id,
    code: code ?? this.code,
    name: name ?? this.name,
    nameTH: nameTH ?? this.nameTH,
    phone: phone.present ? phone.value : this.phone,
    address: address.present ? address.value : this.address,
    points: points ?? this.points,
    totalSpend: totalSpend ?? this.totalSpend,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  CustomerRow copyWithCompanion(CustomersCompanion data) {
    return CustomerRow(
      id: data.id.present ? data.id.value : this.id,
      code: data.code.present ? data.code.value : this.code,
      name: data.name.present ? data.name.value : this.name,
      nameTH: data.nameTH.present ? data.nameTH.value : this.nameTH,
      phone: data.phone.present ? data.phone.value : this.phone,
      address: data.address.present ? data.address.value : this.address,
      points: data.points.present ? data.points.value : this.points,
      totalSpend: data.totalSpend.present
          ? data.totalSpend.value
          : this.totalSpend,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CustomerRow(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('phone: $phone, ')
          ..write('address: $address, ')
          ..write('points: $points, ')
          ..write('totalSpend: $totalSpend, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    code,
    name,
    nameTH,
    phone,
    address,
    points,
    totalSpend,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomerRow &&
          other.id == this.id &&
          other.code == this.code &&
          other.name == this.name &&
          other.nameTH == this.nameTH &&
          other.phone == this.phone &&
          other.address == this.address &&
          other.points == this.points &&
          other.totalSpend == this.totalSpend &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class CustomersCompanion extends UpdateCompanion<CustomerRow> {
  final Value<String> id;
  final Value<String> code;
  final Value<String> name;
  final Value<String> nameTH;
  final Value<String?> phone;
  final Value<String?> address;
  final Value<int> points;
  final Value<double> totalSpend;
  final Value<String> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const CustomersCompanion({
    this.id = const Value.absent(),
    this.code = const Value.absent(),
    this.name = const Value.absent(),
    this.nameTH = const Value.absent(),
    this.phone = const Value.absent(),
    this.address = const Value.absent(),
    this.points = const Value.absent(),
    this.totalSpend = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CustomersCompanion.insert({
    required String id,
    required String code,
    required String name,
    required String nameTH,
    this.phone = const Value.absent(),
    this.address = const Value.absent(),
    this.points = const Value.absent(),
    this.totalSpend = const Value.absent(),
    required String createdAt,
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       code = Value(code),
       name = Value(name),
       nameTH = Value(nameTH),
       createdAt = Value(createdAt);
  static Insertable<CustomerRow> custom({
    Expression<String>? id,
    Expression<String>? code,
    Expression<String>? name,
    Expression<String>? nameTH,
    Expression<String>? phone,
    Expression<String>? address,
    Expression<int>? points,
    Expression<double>? totalSpend,
    Expression<String>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (code != null) 'code': code,
      if (name != null) 'name': name,
      if (nameTH != null) 'name_t_h': nameTH,
      if (phone != null) 'phone': phone,
      if (address != null) 'address': address,
      if (points != null) 'points': points,
      if (totalSpend != null) 'total_spend': totalSpend,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CustomersCompanion copyWith({
    Value<String>? id,
    Value<String>? code,
    Value<String>? name,
    Value<String>? nameTH,
    Value<String?>? phone,
    Value<String?>? address,
    Value<int>? points,
    Value<double>? totalSpend,
    Value<String>? createdAt,
    Value<DateTime?>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return CustomersCompanion(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      nameTH: nameTH ?? this.nameTH,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      points: points ?? this.points,
      totalSpend: totalSpend ?? this.totalSpend,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameTH.present) {
      map['name_t_h'] = Variable<String>(nameTH.value);
    }
    if (phone.present) {
      map['phone'] = Variable<String>(phone.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (points.present) {
      map['points'] = Variable<int>(points.value);
    }
    if (totalSpend.present) {
      map['total_spend'] = Variable<double>(totalSpend.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CustomersCompanion(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('phone: $phone, ')
          ..write('address: $address, ')
          ..write('points: $points, ')
          ..write('totalSpend: $totalSpend, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MechanicsTable extends Mechanics
    with TableInfo<$MechanicsTable, MechanicRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MechanicsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameTHMeta = const VerificationMeta('nameTH');
  @override
  late final GeneratedColumn<String> nameTH = GeneratedColumn<String>(
    'name_t_h',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nicknameMeta = const VerificationMeta(
    'nickname',
  );
  @override
  late final GeneratedColumn<String> nickname = GeneratedColumn<String>(
    'nickname',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shopNameMeta = const VerificationMeta(
    'shopName',
  );
  @override
  late final GeneratedColumn<String> shopName = GeneratedColumn<String>(
    'shop_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _phoneMeta = const VerificationMeta('phone');
  @override
  late final GeneratedColumn<String> phone = GeneratedColumn<String>(
    'phone',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _creditLimitMeta = const VerificationMeta(
    'creditLimit',
  );
  @override
  late final GeneratedColumn<double> creditLimit = GeneratedColumn<double>(
    'credit_limit',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _creditBalanceMeta = const VerificationMeta(
    'creditBalance',
  );
  @override
  late final GeneratedColumn<double> creditBalance = GeneratedColumn<double>(
    'credit_balance',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalSalesMeta = const VerificationMeta(
    'totalSales',
  );
  @override
  late final GeneratedColumn<double> totalSales = GeneratedColumn<double>(
    'total_sales',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalCreditMeta = const VerificationMeta(
    'totalCredit',
  );
  @override
  late final GeneratedColumn<double> totalCredit = GeneratedColumn<double>(
    'total_credit',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalDiscountMeta = const VerificationMeta(
    'totalDiscount',
  );
  @override
  late final GeneratedColumn<double> totalDiscount = GeneratedColumn<double>(
    'total_discount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalMarkupMeta = const VerificationMeta(
    'totalMarkup',
  );
  @override
  late final GeneratedColumn<double> totalMarkup = GeneratedColumn<double>(
    'total_markup',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    code,
    name,
    nameTH,
    nickname,
    shopName,
    phone,
    note,
    creditLimit,
    creditBalance,
    totalSales,
    totalCredit,
    totalDiscount,
    totalMarkup,
    createdAt,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mechanics';
  @override
  VerificationContext validateIntegrity(
    Insertable<MechanicRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_t_h')) {
      context.handle(
        _nameTHMeta,
        nameTH.isAcceptableOrUnknown(data['name_t_h']!, _nameTHMeta),
      );
    }
    if (data.containsKey('nickname')) {
      context.handle(
        _nicknameMeta,
        nickname.isAcceptableOrUnknown(data['nickname']!, _nicknameMeta),
      );
    }
    if (data.containsKey('shop_name')) {
      context.handle(
        _shopNameMeta,
        shopName.isAcceptableOrUnknown(data['shop_name']!, _shopNameMeta),
      );
    }
    if (data.containsKey('phone')) {
      context.handle(
        _phoneMeta,
        phone.isAcceptableOrUnknown(data['phone']!, _phoneMeta),
      );
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('credit_limit')) {
      context.handle(
        _creditLimitMeta,
        creditLimit.isAcceptableOrUnknown(
          data['credit_limit']!,
          _creditLimitMeta,
        ),
      );
    }
    if (data.containsKey('credit_balance')) {
      context.handle(
        _creditBalanceMeta,
        creditBalance.isAcceptableOrUnknown(
          data['credit_balance']!,
          _creditBalanceMeta,
        ),
      );
    }
    if (data.containsKey('total_sales')) {
      context.handle(
        _totalSalesMeta,
        totalSales.isAcceptableOrUnknown(data['total_sales']!, _totalSalesMeta),
      );
    }
    if (data.containsKey('total_credit')) {
      context.handle(
        _totalCreditMeta,
        totalCredit.isAcceptableOrUnknown(
          data['total_credit']!,
          _totalCreditMeta,
        ),
      );
    }
    if (data.containsKey('total_discount')) {
      context.handle(
        _totalDiscountMeta,
        totalDiscount.isAcceptableOrUnknown(
          data['total_discount']!,
          _totalDiscountMeta,
        ),
      );
    }
    if (data.containsKey('total_markup')) {
      context.handle(
        _totalMarkupMeta,
        totalMarkup.isAcceptableOrUnknown(
          data['total_markup']!,
          _totalMarkupMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MechanicRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MechanicRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameTH: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_t_h'],
      ),
      nickname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nickname'],
      ),
      shopName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shop_name'],
      ),
      phone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phone'],
      ),
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      creditLimit: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}credit_limit'],
      )!,
      creditBalance: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}credit_balance'],
      )!,
      totalSales: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total_sales'],
      )!,
      totalCredit: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total_credit'],
      )!,
      totalDiscount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total_discount'],
      )!,
      totalMarkup: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total_markup'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $MechanicsTable createAlias(String alias) {
    return $MechanicsTable(attachedDatabase, alias);
  }
}

class MechanicRow extends DataClass implements Insertable<MechanicRow> {
  final String id;
  final String code;
  final String name;
  final String? nameTH;
  final String? nickname;
  final String? shopName;
  final String? phone;
  final String? note;
  final double creditLimit;
  final double creditBalance;
  final double totalSales;
  final double totalCredit;
  final double totalDiscount;
  final double totalMarkup;
  final String createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  const MechanicRow({
    required this.id,
    required this.code,
    required this.name,
    this.nameTH,
    this.nickname,
    this.shopName,
    this.phone,
    this.note,
    required this.creditLimit,
    required this.creditBalance,
    required this.totalSales,
    required this.totalCredit,
    required this.totalDiscount,
    required this.totalMarkup,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['code'] = Variable<String>(code);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || nameTH != null) {
      map['name_t_h'] = Variable<String>(nameTH);
    }
    if (!nullToAbsent || nickname != null) {
      map['nickname'] = Variable<String>(nickname);
    }
    if (!nullToAbsent || shopName != null) {
      map['shop_name'] = Variable<String>(shopName);
    }
    if (!nullToAbsent || phone != null) {
      map['phone'] = Variable<String>(phone);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['credit_limit'] = Variable<double>(creditLimit);
    map['credit_balance'] = Variable<double>(creditBalance);
    map['total_sales'] = Variable<double>(totalSales);
    map['total_credit'] = Variable<double>(totalCredit);
    map['total_discount'] = Variable<double>(totalDiscount);
    map['total_markup'] = Variable<double>(totalMarkup);
    map['created_at'] = Variable<String>(createdAt);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  MechanicsCompanion toCompanion(bool nullToAbsent) {
    return MechanicsCompanion(
      id: Value(id),
      code: Value(code),
      name: Value(name),
      nameTH: nameTH == null && nullToAbsent
          ? const Value.absent()
          : Value(nameTH),
      nickname: nickname == null && nullToAbsent
          ? const Value.absent()
          : Value(nickname),
      shopName: shopName == null && nullToAbsent
          ? const Value.absent()
          : Value(shopName),
      phone: phone == null && nullToAbsent
          ? const Value.absent()
          : Value(phone),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      creditLimit: Value(creditLimit),
      creditBalance: Value(creditBalance),
      totalSales: Value(totalSales),
      totalCredit: Value(totalCredit),
      totalDiscount: Value(totalDiscount),
      totalMarkup: Value(totalMarkup),
      createdAt: Value(createdAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory MechanicRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MechanicRow(
      id: serializer.fromJson<String>(json['id']),
      code: serializer.fromJson<String>(json['code']),
      name: serializer.fromJson<String>(json['name']),
      nameTH: serializer.fromJson<String?>(json['nameTH']),
      nickname: serializer.fromJson<String?>(json['nickname']),
      shopName: serializer.fromJson<String?>(json['shopName']),
      phone: serializer.fromJson<String?>(json['phone']),
      note: serializer.fromJson<String?>(json['note']),
      creditLimit: serializer.fromJson<double>(json['creditLimit']),
      creditBalance: serializer.fromJson<double>(json['creditBalance']),
      totalSales: serializer.fromJson<double>(json['totalSales']),
      totalCredit: serializer.fromJson<double>(json['totalCredit']),
      totalDiscount: serializer.fromJson<double>(json['totalDiscount']),
      totalMarkup: serializer.fromJson<double>(json['totalMarkup']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'code': serializer.toJson<String>(code),
      'name': serializer.toJson<String>(name),
      'nameTH': serializer.toJson<String?>(nameTH),
      'nickname': serializer.toJson<String?>(nickname),
      'shopName': serializer.toJson<String?>(shopName),
      'phone': serializer.toJson<String?>(phone),
      'note': serializer.toJson<String?>(note),
      'creditLimit': serializer.toJson<double>(creditLimit),
      'creditBalance': serializer.toJson<double>(creditBalance),
      'totalSales': serializer.toJson<double>(totalSales),
      'totalCredit': serializer.toJson<double>(totalCredit),
      'totalDiscount': serializer.toJson<double>(totalDiscount),
      'totalMarkup': serializer.toJson<double>(totalMarkup),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  MechanicRow copyWith({
    String? id,
    String? code,
    String? name,
    Value<String?> nameTH = const Value.absent(),
    Value<String?> nickname = const Value.absent(),
    Value<String?> shopName = const Value.absent(),
    Value<String?> phone = const Value.absent(),
    Value<String?> note = const Value.absent(),
    double? creditLimit,
    double? creditBalance,
    double? totalSales,
    double? totalCredit,
    double? totalDiscount,
    double? totalMarkup,
    String? createdAt,
    Value<DateTime?> updatedAt = const Value.absent(),
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => MechanicRow(
    id: id ?? this.id,
    code: code ?? this.code,
    name: name ?? this.name,
    nameTH: nameTH.present ? nameTH.value : this.nameTH,
    nickname: nickname.present ? nickname.value : this.nickname,
    shopName: shopName.present ? shopName.value : this.shopName,
    phone: phone.present ? phone.value : this.phone,
    note: note.present ? note.value : this.note,
    creditLimit: creditLimit ?? this.creditLimit,
    creditBalance: creditBalance ?? this.creditBalance,
    totalSales: totalSales ?? this.totalSales,
    totalCredit: totalCredit ?? this.totalCredit,
    totalDiscount: totalDiscount ?? this.totalDiscount,
    totalMarkup: totalMarkup ?? this.totalMarkup,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  MechanicRow copyWithCompanion(MechanicsCompanion data) {
    return MechanicRow(
      id: data.id.present ? data.id.value : this.id,
      code: data.code.present ? data.code.value : this.code,
      name: data.name.present ? data.name.value : this.name,
      nameTH: data.nameTH.present ? data.nameTH.value : this.nameTH,
      nickname: data.nickname.present ? data.nickname.value : this.nickname,
      shopName: data.shopName.present ? data.shopName.value : this.shopName,
      phone: data.phone.present ? data.phone.value : this.phone,
      note: data.note.present ? data.note.value : this.note,
      creditLimit: data.creditLimit.present
          ? data.creditLimit.value
          : this.creditLimit,
      creditBalance: data.creditBalance.present
          ? data.creditBalance.value
          : this.creditBalance,
      totalSales: data.totalSales.present
          ? data.totalSales.value
          : this.totalSales,
      totalCredit: data.totalCredit.present
          ? data.totalCredit.value
          : this.totalCredit,
      totalDiscount: data.totalDiscount.present
          ? data.totalDiscount.value
          : this.totalDiscount,
      totalMarkup: data.totalMarkup.present
          ? data.totalMarkup.value
          : this.totalMarkup,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MechanicRow(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('nickname: $nickname, ')
          ..write('shopName: $shopName, ')
          ..write('phone: $phone, ')
          ..write('note: $note, ')
          ..write('creditLimit: $creditLimit, ')
          ..write('creditBalance: $creditBalance, ')
          ..write('totalSales: $totalSales, ')
          ..write('totalCredit: $totalCredit, ')
          ..write('totalDiscount: $totalDiscount, ')
          ..write('totalMarkup: $totalMarkup, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    code,
    name,
    nameTH,
    nickname,
    shopName,
    phone,
    note,
    creditLimit,
    creditBalance,
    totalSales,
    totalCredit,
    totalDiscount,
    totalMarkup,
    createdAt,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MechanicRow &&
          other.id == this.id &&
          other.code == this.code &&
          other.name == this.name &&
          other.nameTH == this.nameTH &&
          other.nickname == this.nickname &&
          other.shopName == this.shopName &&
          other.phone == this.phone &&
          other.note == this.note &&
          other.creditLimit == this.creditLimit &&
          other.creditBalance == this.creditBalance &&
          other.totalSales == this.totalSales &&
          other.totalCredit == this.totalCredit &&
          other.totalDiscount == this.totalDiscount &&
          other.totalMarkup == this.totalMarkup &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class MechanicsCompanion extends UpdateCompanion<MechanicRow> {
  final Value<String> id;
  final Value<String> code;
  final Value<String> name;
  final Value<String?> nameTH;
  final Value<String?> nickname;
  final Value<String?> shopName;
  final Value<String?> phone;
  final Value<String?> note;
  final Value<double> creditLimit;
  final Value<double> creditBalance;
  final Value<double> totalSales;
  final Value<double> totalCredit;
  final Value<double> totalDiscount;
  final Value<double> totalMarkup;
  final Value<String> createdAt;
  final Value<DateTime?> updatedAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const MechanicsCompanion({
    this.id = const Value.absent(),
    this.code = const Value.absent(),
    this.name = const Value.absent(),
    this.nameTH = const Value.absent(),
    this.nickname = const Value.absent(),
    this.shopName = const Value.absent(),
    this.phone = const Value.absent(),
    this.note = const Value.absent(),
    this.creditLimit = const Value.absent(),
    this.creditBalance = const Value.absent(),
    this.totalSales = const Value.absent(),
    this.totalCredit = const Value.absent(),
    this.totalDiscount = const Value.absent(),
    this.totalMarkup = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MechanicsCompanion.insert({
    required String id,
    required String code,
    required String name,
    this.nameTH = const Value.absent(),
    this.nickname = const Value.absent(),
    this.shopName = const Value.absent(),
    this.phone = const Value.absent(),
    this.note = const Value.absent(),
    this.creditLimit = const Value.absent(),
    this.creditBalance = const Value.absent(),
    this.totalSales = const Value.absent(),
    this.totalCredit = const Value.absent(),
    this.totalDiscount = const Value.absent(),
    this.totalMarkup = const Value.absent(),
    required String createdAt,
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       code = Value(code),
       name = Value(name),
       createdAt = Value(createdAt);
  static Insertable<MechanicRow> custom({
    Expression<String>? id,
    Expression<String>? code,
    Expression<String>? name,
    Expression<String>? nameTH,
    Expression<String>? nickname,
    Expression<String>? shopName,
    Expression<String>? phone,
    Expression<String>? note,
    Expression<double>? creditLimit,
    Expression<double>? creditBalance,
    Expression<double>? totalSales,
    Expression<double>? totalCredit,
    Expression<double>? totalDiscount,
    Expression<double>? totalMarkup,
    Expression<String>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (code != null) 'code': code,
      if (name != null) 'name': name,
      if (nameTH != null) 'name_t_h': nameTH,
      if (nickname != null) 'nickname': nickname,
      if (shopName != null) 'shop_name': shopName,
      if (phone != null) 'phone': phone,
      if (note != null) 'note': note,
      if (creditLimit != null) 'credit_limit': creditLimit,
      if (creditBalance != null) 'credit_balance': creditBalance,
      if (totalSales != null) 'total_sales': totalSales,
      if (totalCredit != null) 'total_credit': totalCredit,
      if (totalDiscount != null) 'total_discount': totalDiscount,
      if (totalMarkup != null) 'total_markup': totalMarkup,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MechanicsCompanion copyWith({
    Value<String>? id,
    Value<String>? code,
    Value<String>? name,
    Value<String?>? nameTH,
    Value<String?>? nickname,
    Value<String?>? shopName,
    Value<String?>? phone,
    Value<String?>? note,
    Value<double>? creditLimit,
    Value<double>? creditBalance,
    Value<double>? totalSales,
    Value<double>? totalCredit,
    Value<double>? totalDiscount,
    Value<double>? totalMarkup,
    Value<String>? createdAt,
    Value<DateTime?>? updatedAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return MechanicsCompanion(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      nameTH: nameTH ?? this.nameTH,
      nickname: nickname ?? this.nickname,
      shopName: shopName ?? this.shopName,
      phone: phone ?? this.phone,
      note: note ?? this.note,
      creditLimit: creditLimit ?? this.creditLimit,
      creditBalance: creditBalance ?? this.creditBalance,
      totalSales: totalSales ?? this.totalSales,
      totalCredit: totalCredit ?? this.totalCredit,
      totalDiscount: totalDiscount ?? this.totalDiscount,
      totalMarkup: totalMarkup ?? this.totalMarkup,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameTH.present) {
      map['name_t_h'] = Variable<String>(nameTH.value);
    }
    if (nickname.present) {
      map['nickname'] = Variable<String>(nickname.value);
    }
    if (shopName.present) {
      map['shop_name'] = Variable<String>(shopName.value);
    }
    if (phone.present) {
      map['phone'] = Variable<String>(phone.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (creditLimit.present) {
      map['credit_limit'] = Variable<double>(creditLimit.value);
    }
    if (creditBalance.present) {
      map['credit_balance'] = Variable<double>(creditBalance.value);
    }
    if (totalSales.present) {
      map['total_sales'] = Variable<double>(totalSales.value);
    }
    if (totalCredit.present) {
      map['total_credit'] = Variable<double>(totalCredit.value);
    }
    if (totalDiscount.present) {
      map['total_discount'] = Variable<double>(totalDiscount.value);
    }
    if (totalMarkup.present) {
      map['total_markup'] = Variable<double>(totalMarkup.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MechanicsCompanion(')
          ..write('id: $id, ')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('nickname: $nickname, ')
          ..write('shopName: $shopName, ')
          ..write('phone: $phone, ')
          ..write('note: $note, ')
          ..write('creditLimit: $creditLimit, ')
          ..write('creditBalance: $creditBalance, ')
          ..write('totalSales: $totalSales, ')
          ..write('totalCredit: $totalCredit, ')
          ..write('totalDiscount: $totalDiscount, ')
          ..write('totalMarkup: $totalMarkup, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SalesTable extends Sales with TableInfo<$SalesTable, SaleRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SalesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiptNoMeta = const VerificationMeta(
    'receiptNo',
  );
  @override
  late final GeneratedColumn<String> receiptNo = GeneratedColumn<String>(
    'receipt_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subtotalMeta = const VerificationMeta(
    'subtotal',
  );
  @override
  late final GeneratedColumn<double> subtotal = GeneratedColumn<double>(
    'subtotal',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _discountMeta = const VerificationMeta(
    'discount',
  );
  @override
  late final GeneratedColumn<double> discount = GeneratedColumn<double>(
    'discount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalMeta = const VerificationMeta('total');
  @override
  late final GeneratedColumn<double> total = GeneratedColumn<double>(
    'total',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paymentMethodMeta = const VerificationMeta(
    'paymentMethod',
  );
  @override
  late final GeneratedColumn<String> paymentMethod = GeneratedColumn<String>(
    'payment_method',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _customerIdMeta = const VerificationMeta(
    'customerId',
  );
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
    'customer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _customerNameMeta = const VerificationMeta(
    'customerName',
  );
  @override
  late final GeneratedColumn<String> customerName = GeneratedColumn<String>(
    'customer_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mechanicIdMeta = const VerificationMeta(
    'mechanicId',
  );
  @override
  late final GeneratedColumn<String> mechanicId = GeneratedColumn<String>(
    'mechanic_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mechanicNameMeta = const VerificationMeta(
    'mechanicName',
  );
  @override
  late final GeneratedColumn<String> mechanicName = GeneratedColumn<String>(
    'mechanic_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mechanicDeltaMeta = const VerificationMeta(
    'mechanicDelta',
  );
  @override
  late final GeneratedColumn<double> mechanicDelta = GeneratedColumn<double>(
    'mechanic_delta',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pointsGrantedMeta = const VerificationMeta(
    'pointsGranted',
  );
  @override
  late final GeneratedColumn<int> pointsGranted = GeneratedColumn<int>(
    'points_granted',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _voidedMeta = const VerificationMeta('voided');
  @override
  late final GeneratedColumn<bool> voided = GeneratedColumn<bool>(
    'voided',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("voided" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _voidedAtMeta = const VerificationMeta(
    'voidedAt',
  );
  @override
  late final GeneratedColumn<DateTime> voidedAt = GeneratedColumn<DateTime>(
    'voided_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shiftIdMeta = const VerificationMeta(
    'shiftId',
  );
  @override
  late final GeneratedColumn<String> shiftId = GeneratedColumn<String>(
    'shift_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    receiptNo,
    subtotal,
    discount,
    total,
    paymentMethod,
    customerId,
    customerName,
    mechanicId,
    mechanicName,
    mechanicDelta,
    pointsGranted,
    date,
    voided,
    voidedAt,
    shiftId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sales';
  @override
  VerificationContext validateIntegrity(
    Insertable<SaleRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('receipt_no')) {
      context.handle(
        _receiptNoMeta,
        receiptNo.isAcceptableOrUnknown(data['receipt_no']!, _receiptNoMeta),
      );
    } else if (isInserting) {
      context.missing(_receiptNoMeta);
    }
    if (data.containsKey('subtotal')) {
      context.handle(
        _subtotalMeta,
        subtotal.isAcceptableOrUnknown(data['subtotal']!, _subtotalMeta),
      );
    } else if (isInserting) {
      context.missing(_subtotalMeta);
    }
    if (data.containsKey('discount')) {
      context.handle(
        _discountMeta,
        discount.isAcceptableOrUnknown(data['discount']!, _discountMeta),
      );
    }
    if (data.containsKey('total')) {
      context.handle(
        _totalMeta,
        total.isAcceptableOrUnknown(data['total']!, _totalMeta),
      );
    } else if (isInserting) {
      context.missing(_totalMeta);
    }
    if (data.containsKey('payment_method')) {
      context.handle(
        _paymentMethodMeta,
        paymentMethod.isAcceptableOrUnknown(
          data['payment_method']!,
          _paymentMethodMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_paymentMethodMeta);
    }
    if (data.containsKey('customer_id')) {
      context.handle(
        _customerIdMeta,
        customerId.isAcceptableOrUnknown(data['customer_id']!, _customerIdMeta),
      );
    }
    if (data.containsKey('customer_name')) {
      context.handle(
        _customerNameMeta,
        customerName.isAcceptableOrUnknown(
          data['customer_name']!,
          _customerNameMeta,
        ),
      );
    }
    if (data.containsKey('mechanic_id')) {
      context.handle(
        _mechanicIdMeta,
        mechanicId.isAcceptableOrUnknown(data['mechanic_id']!, _mechanicIdMeta),
      );
    }
    if (data.containsKey('mechanic_name')) {
      context.handle(
        _mechanicNameMeta,
        mechanicName.isAcceptableOrUnknown(
          data['mechanic_name']!,
          _mechanicNameMeta,
        ),
      );
    }
    if (data.containsKey('mechanic_delta')) {
      context.handle(
        _mechanicDeltaMeta,
        mechanicDelta.isAcceptableOrUnknown(
          data['mechanic_delta']!,
          _mechanicDeltaMeta,
        ),
      );
    }
    if (data.containsKey('points_granted')) {
      context.handle(
        _pointsGrantedMeta,
        pointsGranted.isAcceptableOrUnknown(
          data['points_granted']!,
          _pointsGrantedMeta,
        ),
      );
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    if (data.containsKey('voided')) {
      context.handle(
        _voidedMeta,
        voided.isAcceptableOrUnknown(data['voided']!, _voidedMeta),
      );
    }
    if (data.containsKey('voided_at')) {
      context.handle(
        _voidedAtMeta,
        voidedAt.isAcceptableOrUnknown(data['voided_at']!, _voidedAtMeta),
      );
    }
    if (data.containsKey('shift_id')) {
      context.handle(
        _shiftIdMeta,
        shiftId.isAcceptableOrUnknown(data['shift_id']!, _shiftIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SaleRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SaleRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      receiptNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_no'],
      )!,
      subtotal: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}subtotal'],
      )!,
      discount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}discount'],
      )!,
      total: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total'],
      )!,
      paymentMethod: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payment_method'],
      )!,
      customerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_id'],
      ),
      customerName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_name'],
      ),
      mechanicId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mechanic_id'],
      ),
      mechanicName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mechanic_name'],
      ),
      mechanicDelta: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}mechanic_delta'],
      ),
      pointsGranted: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}points_granted'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
      voided: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}voided'],
      )!,
      voidedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}voided_at'],
      ),
      shiftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shift_id'],
      ),
    );
  }

  @override
  $SalesTable createAlias(String alias) {
    return $SalesTable(attachedDatabase, alias);
  }
}

class SaleRow extends DataClass implements Insertable<SaleRow> {
  final String id;
  final String receiptNo;
  final double subtotal;
  final double discount;
  final double total;
  final String paymentMethod;
  final String? customerId;
  final String? customerName;
  final String? mechanicId;
  final String? mechanicName;
  final double? mechanicDelta;
  final int pointsGranted;
  final DateTime date;
  final bool voided;
  final DateTime? voidedAt;

  /// Schema v3 (ADR-0010): the shift this bill belongs to, as issued by the
  /// server (`sales.shift_id`). Nullable because every bill written by the
  /// offline build has none. Deliberately NOT a `references(Shifts, #id)`:
  /// a patched bill can name a shift this cache has never seen.
  final String? shiftId;
  const SaleRow({
    required this.id,
    required this.receiptNo,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    this.customerId,
    this.customerName,
    this.mechanicId,
    this.mechanicName,
    this.mechanicDelta,
    required this.pointsGranted,
    required this.date,
    required this.voided,
    this.voidedAt,
    this.shiftId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['receipt_no'] = Variable<String>(receiptNo);
    map['subtotal'] = Variable<double>(subtotal);
    map['discount'] = Variable<double>(discount);
    map['total'] = Variable<double>(total);
    map['payment_method'] = Variable<String>(paymentMethod);
    if (!nullToAbsent || customerId != null) {
      map['customer_id'] = Variable<String>(customerId);
    }
    if (!nullToAbsent || customerName != null) {
      map['customer_name'] = Variable<String>(customerName);
    }
    if (!nullToAbsent || mechanicId != null) {
      map['mechanic_id'] = Variable<String>(mechanicId);
    }
    if (!nullToAbsent || mechanicName != null) {
      map['mechanic_name'] = Variable<String>(mechanicName);
    }
    if (!nullToAbsent || mechanicDelta != null) {
      map['mechanic_delta'] = Variable<double>(mechanicDelta);
    }
    map['points_granted'] = Variable<int>(pointsGranted);
    map['date'] = Variable<DateTime>(date);
    map['voided'] = Variable<bool>(voided);
    if (!nullToAbsent || voidedAt != null) {
      map['voided_at'] = Variable<DateTime>(voidedAt);
    }
    if (!nullToAbsent || shiftId != null) {
      map['shift_id'] = Variable<String>(shiftId);
    }
    return map;
  }

  SalesCompanion toCompanion(bool nullToAbsent) {
    return SalesCompanion(
      id: Value(id),
      receiptNo: Value(receiptNo),
      subtotal: Value(subtotal),
      discount: Value(discount),
      total: Value(total),
      paymentMethod: Value(paymentMethod),
      customerId: customerId == null && nullToAbsent
          ? const Value.absent()
          : Value(customerId),
      customerName: customerName == null && nullToAbsent
          ? const Value.absent()
          : Value(customerName),
      mechanicId: mechanicId == null && nullToAbsent
          ? const Value.absent()
          : Value(mechanicId),
      mechanicName: mechanicName == null && nullToAbsent
          ? const Value.absent()
          : Value(mechanicName),
      mechanicDelta: mechanicDelta == null && nullToAbsent
          ? const Value.absent()
          : Value(mechanicDelta),
      pointsGranted: Value(pointsGranted),
      date: Value(date),
      voided: Value(voided),
      voidedAt: voidedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(voidedAt),
      shiftId: shiftId == null && nullToAbsent
          ? const Value.absent()
          : Value(shiftId),
    );
  }

  factory SaleRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SaleRow(
      id: serializer.fromJson<String>(json['id']),
      receiptNo: serializer.fromJson<String>(json['receiptNo']),
      subtotal: serializer.fromJson<double>(json['subtotal']),
      discount: serializer.fromJson<double>(json['discount']),
      total: serializer.fromJson<double>(json['total']),
      paymentMethod: serializer.fromJson<String>(json['paymentMethod']),
      customerId: serializer.fromJson<String?>(json['customerId']),
      customerName: serializer.fromJson<String?>(json['customerName']),
      mechanicId: serializer.fromJson<String?>(json['mechanicId']),
      mechanicName: serializer.fromJson<String?>(json['mechanicName']),
      mechanicDelta: serializer.fromJson<double?>(json['mechanicDelta']),
      pointsGranted: serializer.fromJson<int>(json['pointsGranted']),
      date: serializer.fromJson<DateTime>(json['date']),
      voided: serializer.fromJson<bool>(json['voided']),
      voidedAt: serializer.fromJson<DateTime?>(json['voidedAt']),
      shiftId: serializer.fromJson<String?>(json['shiftId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'receiptNo': serializer.toJson<String>(receiptNo),
      'subtotal': serializer.toJson<double>(subtotal),
      'discount': serializer.toJson<double>(discount),
      'total': serializer.toJson<double>(total),
      'paymentMethod': serializer.toJson<String>(paymentMethod),
      'customerId': serializer.toJson<String?>(customerId),
      'customerName': serializer.toJson<String?>(customerName),
      'mechanicId': serializer.toJson<String?>(mechanicId),
      'mechanicName': serializer.toJson<String?>(mechanicName),
      'mechanicDelta': serializer.toJson<double?>(mechanicDelta),
      'pointsGranted': serializer.toJson<int>(pointsGranted),
      'date': serializer.toJson<DateTime>(date),
      'voided': serializer.toJson<bool>(voided),
      'voidedAt': serializer.toJson<DateTime?>(voidedAt),
      'shiftId': serializer.toJson<String?>(shiftId),
    };
  }

  SaleRow copyWith({
    String? id,
    String? receiptNo,
    double? subtotal,
    double? discount,
    double? total,
    String? paymentMethod,
    Value<String?> customerId = const Value.absent(),
    Value<String?> customerName = const Value.absent(),
    Value<String?> mechanicId = const Value.absent(),
    Value<String?> mechanicName = const Value.absent(),
    Value<double?> mechanicDelta = const Value.absent(),
    int? pointsGranted,
    DateTime? date,
    bool? voided,
    Value<DateTime?> voidedAt = const Value.absent(),
    Value<String?> shiftId = const Value.absent(),
  }) => SaleRow(
    id: id ?? this.id,
    receiptNo: receiptNo ?? this.receiptNo,
    subtotal: subtotal ?? this.subtotal,
    discount: discount ?? this.discount,
    total: total ?? this.total,
    paymentMethod: paymentMethod ?? this.paymentMethod,
    customerId: customerId.present ? customerId.value : this.customerId,
    customerName: customerName.present ? customerName.value : this.customerName,
    mechanicId: mechanicId.present ? mechanicId.value : this.mechanicId,
    mechanicName: mechanicName.present ? mechanicName.value : this.mechanicName,
    mechanicDelta: mechanicDelta.present
        ? mechanicDelta.value
        : this.mechanicDelta,
    pointsGranted: pointsGranted ?? this.pointsGranted,
    date: date ?? this.date,
    voided: voided ?? this.voided,
    voidedAt: voidedAt.present ? voidedAt.value : this.voidedAt,
    shiftId: shiftId.present ? shiftId.value : this.shiftId,
  );
  SaleRow copyWithCompanion(SalesCompanion data) {
    return SaleRow(
      id: data.id.present ? data.id.value : this.id,
      receiptNo: data.receiptNo.present ? data.receiptNo.value : this.receiptNo,
      subtotal: data.subtotal.present ? data.subtotal.value : this.subtotal,
      discount: data.discount.present ? data.discount.value : this.discount,
      total: data.total.present ? data.total.value : this.total,
      paymentMethod: data.paymentMethod.present
          ? data.paymentMethod.value
          : this.paymentMethod,
      customerId: data.customerId.present
          ? data.customerId.value
          : this.customerId,
      customerName: data.customerName.present
          ? data.customerName.value
          : this.customerName,
      mechanicId: data.mechanicId.present
          ? data.mechanicId.value
          : this.mechanicId,
      mechanicName: data.mechanicName.present
          ? data.mechanicName.value
          : this.mechanicName,
      mechanicDelta: data.mechanicDelta.present
          ? data.mechanicDelta.value
          : this.mechanicDelta,
      pointsGranted: data.pointsGranted.present
          ? data.pointsGranted.value
          : this.pointsGranted,
      date: data.date.present ? data.date.value : this.date,
      voided: data.voided.present ? data.voided.value : this.voided,
      voidedAt: data.voidedAt.present ? data.voidedAt.value : this.voidedAt,
      shiftId: data.shiftId.present ? data.shiftId.value : this.shiftId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SaleRow(')
          ..write('id: $id, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('subtotal: $subtotal, ')
          ..write('discount: $discount, ')
          ..write('total: $total, ')
          ..write('paymentMethod: $paymentMethod, ')
          ..write('customerId: $customerId, ')
          ..write('customerName: $customerName, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('mechanicName: $mechanicName, ')
          ..write('mechanicDelta: $mechanicDelta, ')
          ..write('pointsGranted: $pointsGranted, ')
          ..write('date: $date, ')
          ..write('voided: $voided, ')
          ..write('voidedAt: $voidedAt, ')
          ..write('shiftId: $shiftId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    receiptNo,
    subtotal,
    discount,
    total,
    paymentMethod,
    customerId,
    customerName,
    mechanicId,
    mechanicName,
    mechanicDelta,
    pointsGranted,
    date,
    voided,
    voidedAt,
    shiftId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SaleRow &&
          other.id == this.id &&
          other.receiptNo == this.receiptNo &&
          other.subtotal == this.subtotal &&
          other.discount == this.discount &&
          other.total == this.total &&
          other.paymentMethod == this.paymentMethod &&
          other.customerId == this.customerId &&
          other.customerName == this.customerName &&
          other.mechanicId == this.mechanicId &&
          other.mechanicName == this.mechanicName &&
          other.mechanicDelta == this.mechanicDelta &&
          other.pointsGranted == this.pointsGranted &&
          other.date == this.date &&
          other.voided == this.voided &&
          other.voidedAt == this.voidedAt &&
          other.shiftId == this.shiftId);
}

class SalesCompanion extends UpdateCompanion<SaleRow> {
  final Value<String> id;
  final Value<String> receiptNo;
  final Value<double> subtotal;
  final Value<double> discount;
  final Value<double> total;
  final Value<String> paymentMethod;
  final Value<String?> customerId;
  final Value<String?> customerName;
  final Value<String?> mechanicId;
  final Value<String?> mechanicName;
  final Value<double?> mechanicDelta;
  final Value<int> pointsGranted;
  final Value<DateTime> date;
  final Value<bool> voided;
  final Value<DateTime?> voidedAt;
  final Value<String?> shiftId;
  final Value<int> rowid;
  const SalesCompanion({
    this.id = const Value.absent(),
    this.receiptNo = const Value.absent(),
    this.subtotal = const Value.absent(),
    this.discount = const Value.absent(),
    this.total = const Value.absent(),
    this.paymentMethod = const Value.absent(),
    this.customerId = const Value.absent(),
    this.customerName = const Value.absent(),
    this.mechanicId = const Value.absent(),
    this.mechanicName = const Value.absent(),
    this.mechanicDelta = const Value.absent(),
    this.pointsGranted = const Value.absent(),
    this.date = const Value.absent(),
    this.voided = const Value.absent(),
    this.voidedAt = const Value.absent(),
    this.shiftId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SalesCompanion.insert({
    required String id,
    required String receiptNo,
    required double subtotal,
    this.discount = const Value.absent(),
    required double total,
    required String paymentMethod,
    this.customerId = const Value.absent(),
    this.customerName = const Value.absent(),
    this.mechanicId = const Value.absent(),
    this.mechanicName = const Value.absent(),
    this.mechanicDelta = const Value.absent(),
    this.pointsGranted = const Value.absent(),
    required DateTime date,
    this.voided = const Value.absent(),
    this.voidedAt = const Value.absent(),
    this.shiftId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       receiptNo = Value(receiptNo),
       subtotal = Value(subtotal),
       total = Value(total),
       paymentMethod = Value(paymentMethod),
       date = Value(date);
  static Insertable<SaleRow> custom({
    Expression<String>? id,
    Expression<String>? receiptNo,
    Expression<double>? subtotal,
    Expression<double>? discount,
    Expression<double>? total,
    Expression<String>? paymentMethod,
    Expression<String>? customerId,
    Expression<String>? customerName,
    Expression<String>? mechanicId,
    Expression<String>? mechanicName,
    Expression<double>? mechanicDelta,
    Expression<int>? pointsGranted,
    Expression<DateTime>? date,
    Expression<bool>? voided,
    Expression<DateTime>? voidedAt,
    Expression<String>? shiftId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (receiptNo != null) 'receipt_no': receiptNo,
      if (subtotal != null) 'subtotal': subtotal,
      if (discount != null) 'discount': discount,
      if (total != null) 'total': total,
      if (paymentMethod != null) 'payment_method': paymentMethod,
      if (customerId != null) 'customer_id': customerId,
      if (customerName != null) 'customer_name': customerName,
      if (mechanicId != null) 'mechanic_id': mechanicId,
      if (mechanicName != null) 'mechanic_name': mechanicName,
      if (mechanicDelta != null) 'mechanic_delta': mechanicDelta,
      if (pointsGranted != null) 'points_granted': pointsGranted,
      if (date != null) 'date': date,
      if (voided != null) 'voided': voided,
      if (voidedAt != null) 'voided_at': voidedAt,
      if (shiftId != null) 'shift_id': shiftId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SalesCompanion copyWith({
    Value<String>? id,
    Value<String>? receiptNo,
    Value<double>? subtotal,
    Value<double>? discount,
    Value<double>? total,
    Value<String>? paymentMethod,
    Value<String?>? customerId,
    Value<String?>? customerName,
    Value<String?>? mechanicId,
    Value<String?>? mechanicName,
    Value<double?>? mechanicDelta,
    Value<int>? pointsGranted,
    Value<DateTime>? date,
    Value<bool>? voided,
    Value<DateTime?>? voidedAt,
    Value<String?>? shiftId,
    Value<int>? rowid,
  }) {
    return SalesCompanion(
      id: id ?? this.id,
      receiptNo: receiptNo ?? this.receiptNo,
      subtotal: subtotal ?? this.subtotal,
      discount: discount ?? this.discount,
      total: total ?? this.total,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      customerId: customerId ?? this.customerId,
      customerName: customerName ?? this.customerName,
      mechanicId: mechanicId ?? this.mechanicId,
      mechanicName: mechanicName ?? this.mechanicName,
      mechanicDelta: mechanicDelta ?? this.mechanicDelta,
      pointsGranted: pointsGranted ?? this.pointsGranted,
      date: date ?? this.date,
      voided: voided ?? this.voided,
      voidedAt: voidedAt ?? this.voidedAt,
      shiftId: shiftId ?? this.shiftId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (receiptNo.present) {
      map['receipt_no'] = Variable<String>(receiptNo.value);
    }
    if (subtotal.present) {
      map['subtotal'] = Variable<double>(subtotal.value);
    }
    if (discount.present) {
      map['discount'] = Variable<double>(discount.value);
    }
    if (total.present) {
      map['total'] = Variable<double>(total.value);
    }
    if (paymentMethod.present) {
      map['payment_method'] = Variable<String>(paymentMethod.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (customerName.present) {
      map['customer_name'] = Variable<String>(customerName.value);
    }
    if (mechanicId.present) {
      map['mechanic_id'] = Variable<String>(mechanicId.value);
    }
    if (mechanicName.present) {
      map['mechanic_name'] = Variable<String>(mechanicName.value);
    }
    if (mechanicDelta.present) {
      map['mechanic_delta'] = Variable<double>(mechanicDelta.value);
    }
    if (pointsGranted.present) {
      map['points_granted'] = Variable<int>(pointsGranted.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (voided.present) {
      map['voided'] = Variable<bool>(voided.value);
    }
    if (voidedAt.present) {
      map['voided_at'] = Variable<DateTime>(voidedAt.value);
    }
    if (shiftId.present) {
      map['shift_id'] = Variable<String>(shiftId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SalesCompanion(')
          ..write('id: $id, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('subtotal: $subtotal, ')
          ..write('discount: $discount, ')
          ..write('total: $total, ')
          ..write('paymentMethod: $paymentMethod, ')
          ..write('customerId: $customerId, ')
          ..write('customerName: $customerName, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('mechanicName: $mechanicName, ')
          ..write('mechanicDelta: $mechanicDelta, ')
          ..write('pointsGranted: $pointsGranted, ')
          ..write('date: $date, ')
          ..write('voided: $voided, ')
          ..write('voidedAt: $voidedAt, ')
          ..write('shiftId: $shiftId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SaleItemsTable extends SaleItems
    with TableInfo<$SaleItemsTable, SaleItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SaleItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<int> rowId = GeneratedColumn<int>(
    'row_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _saleIdMeta = const VerificationMeta('saleId');
  @override
  late final GeneratedColumn<String> saleId = GeneratedColumn<String>(
    'sale_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sales (id)',
    ),
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _partNoMeta = const VerificationMeta('partNo');
  @override
  late final GeneratedColumn<String> partNo = GeneratedColumn<String>(
    'part_no',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameTHMeta = const VerificationMeta('nameTH');
  @override
  late final GeneratedColumn<String> nameTH = GeneratedColumn<String>(
    'name_t_h',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _qtyMeta = const VerificationMeta('qty');
  @override
  late final GeneratedColumn<int> qty = GeneratedColumn<int>(
    'qty',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<double> price = GeneratedColumn<double>(
    'price',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _costAtSaleMeta = const VerificationMeta(
    'costAtSale',
  );
  @override
  late final GeneratedColumn<double> costAtSale = GeneratedColumn<double>(
    'cost_at_sale',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    rowId,
    saleId,
    productId,
    partNo,
    name,
    nameTH,
    qty,
    price,
    costAtSale,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sale_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<SaleItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    }
    if (data.containsKey('sale_id')) {
      context.handle(
        _saleIdMeta,
        saleId.isAcceptableOrUnknown(data['sale_id']!, _saleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_saleIdMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('part_no')) {
      context.handle(
        _partNoMeta,
        partNo.isAcceptableOrUnknown(data['part_no']!, _partNoMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('name_t_h')) {
      context.handle(
        _nameTHMeta,
        nameTH.isAcceptableOrUnknown(data['name_t_h']!, _nameTHMeta),
      );
    }
    if (data.containsKey('qty')) {
      context.handle(
        _qtyMeta,
        qty.isAcceptableOrUnknown(data['qty']!, _qtyMeta),
      );
    } else if (isInserting) {
      context.missing(_qtyMeta);
    }
    if (data.containsKey('price')) {
      context.handle(
        _priceMeta,
        price.isAcceptableOrUnknown(data['price']!, _priceMeta),
      );
    } else if (isInserting) {
      context.missing(_priceMeta);
    }
    if (data.containsKey('cost_at_sale')) {
      context.handle(
        _costAtSaleMeta,
        costAtSale.isAcceptableOrUnknown(
          data['cost_at_sale']!,
          _costAtSaleMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  SaleItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SaleItemRow(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}row_id'],
      )!,
      saleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sale_id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      partNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_no'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      nameTH: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_t_h'],
      ),
      qty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty'],
      )!,
      price: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}price'],
      )!,
      costAtSale: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost_at_sale'],
      ),
    );
  }

  @override
  $SaleItemsTable createAlias(String alias) {
    return $SaleItemsTable(attachedDatabase, alias);
  }
}

class SaleItemRow extends DataClass implements Insertable<SaleItemRow> {
  final int rowId;
  final String saleId;
  final String productId;
  final String? partNo;
  final String name;
  final String? nameTH;
  final int qty;
  final double price;
  final double? costAtSale;
  const SaleItemRow({
    required this.rowId,
    required this.saleId,
    required this.productId,
    this.partNo,
    required this.name,
    this.nameTH,
    required this.qty,
    required this.price,
    this.costAtSale,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<int>(rowId);
    map['sale_id'] = Variable<String>(saleId);
    map['product_id'] = Variable<String>(productId);
    if (!nullToAbsent || partNo != null) {
      map['part_no'] = Variable<String>(partNo);
    }
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || nameTH != null) {
      map['name_t_h'] = Variable<String>(nameTH);
    }
    map['qty'] = Variable<int>(qty);
    map['price'] = Variable<double>(price);
    if (!nullToAbsent || costAtSale != null) {
      map['cost_at_sale'] = Variable<double>(costAtSale);
    }
    return map;
  }

  SaleItemsCompanion toCompanion(bool nullToAbsent) {
    return SaleItemsCompanion(
      rowId: Value(rowId),
      saleId: Value(saleId),
      productId: Value(productId),
      partNo: partNo == null && nullToAbsent
          ? const Value.absent()
          : Value(partNo),
      name: Value(name),
      nameTH: nameTH == null && nullToAbsent
          ? const Value.absent()
          : Value(nameTH),
      qty: Value(qty),
      price: Value(price),
      costAtSale: costAtSale == null && nullToAbsent
          ? const Value.absent()
          : Value(costAtSale),
    );
  }

  factory SaleItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SaleItemRow(
      rowId: serializer.fromJson<int>(json['rowId']),
      saleId: serializer.fromJson<String>(json['saleId']),
      productId: serializer.fromJson<String>(json['productId']),
      partNo: serializer.fromJson<String?>(json['partNo']),
      name: serializer.fromJson<String>(json['name']),
      nameTH: serializer.fromJson<String?>(json['nameTH']),
      qty: serializer.fromJson<int>(json['qty']),
      price: serializer.fromJson<double>(json['price']),
      costAtSale: serializer.fromJson<double?>(json['costAtSale']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<int>(rowId),
      'saleId': serializer.toJson<String>(saleId),
      'productId': serializer.toJson<String>(productId),
      'partNo': serializer.toJson<String?>(partNo),
      'name': serializer.toJson<String>(name),
      'nameTH': serializer.toJson<String?>(nameTH),
      'qty': serializer.toJson<int>(qty),
      'price': serializer.toJson<double>(price),
      'costAtSale': serializer.toJson<double?>(costAtSale),
    };
  }

  SaleItemRow copyWith({
    int? rowId,
    String? saleId,
    String? productId,
    Value<String?> partNo = const Value.absent(),
    String? name,
    Value<String?> nameTH = const Value.absent(),
    int? qty,
    double? price,
    Value<double?> costAtSale = const Value.absent(),
  }) => SaleItemRow(
    rowId: rowId ?? this.rowId,
    saleId: saleId ?? this.saleId,
    productId: productId ?? this.productId,
    partNo: partNo.present ? partNo.value : this.partNo,
    name: name ?? this.name,
    nameTH: nameTH.present ? nameTH.value : this.nameTH,
    qty: qty ?? this.qty,
    price: price ?? this.price,
    costAtSale: costAtSale.present ? costAtSale.value : this.costAtSale,
  );
  SaleItemRow copyWithCompanion(SaleItemsCompanion data) {
    return SaleItemRow(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      saleId: data.saleId.present ? data.saleId.value : this.saleId,
      productId: data.productId.present ? data.productId.value : this.productId,
      partNo: data.partNo.present ? data.partNo.value : this.partNo,
      name: data.name.present ? data.name.value : this.name,
      nameTH: data.nameTH.present ? data.nameTH.value : this.nameTH,
      qty: data.qty.present ? data.qty.value : this.qty,
      price: data.price.present ? data.price.value : this.price,
      costAtSale: data.costAtSale.present
          ? data.costAtSale.value
          : this.costAtSale,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SaleItemRow(')
          ..write('rowId: $rowId, ')
          ..write('saleId: $saleId, ')
          ..write('productId: $productId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('costAtSale: $costAtSale')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    rowId,
    saleId,
    productId,
    partNo,
    name,
    nameTH,
    qty,
    price,
    costAtSale,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SaleItemRow &&
          other.rowId == this.rowId &&
          other.saleId == this.saleId &&
          other.productId == this.productId &&
          other.partNo == this.partNo &&
          other.name == this.name &&
          other.nameTH == this.nameTH &&
          other.qty == this.qty &&
          other.price == this.price &&
          other.costAtSale == this.costAtSale);
}

class SaleItemsCompanion extends UpdateCompanion<SaleItemRow> {
  final Value<int> rowId;
  final Value<String> saleId;
  final Value<String> productId;
  final Value<String?> partNo;
  final Value<String> name;
  final Value<String?> nameTH;
  final Value<int> qty;
  final Value<double> price;
  final Value<double?> costAtSale;
  const SaleItemsCompanion({
    this.rowId = const Value.absent(),
    this.saleId = const Value.absent(),
    this.productId = const Value.absent(),
    this.partNo = const Value.absent(),
    this.name = const Value.absent(),
    this.nameTH = const Value.absent(),
    this.qty = const Value.absent(),
    this.price = const Value.absent(),
    this.costAtSale = const Value.absent(),
  });
  SaleItemsCompanion.insert({
    this.rowId = const Value.absent(),
    required String saleId,
    required String productId,
    this.partNo = const Value.absent(),
    required String name,
    this.nameTH = const Value.absent(),
    required int qty,
    required double price,
    this.costAtSale = const Value.absent(),
  }) : saleId = Value(saleId),
       productId = Value(productId),
       name = Value(name),
       qty = Value(qty),
       price = Value(price);
  static Insertable<SaleItemRow> custom({
    Expression<int>? rowId,
    Expression<String>? saleId,
    Expression<String>? productId,
    Expression<String>? partNo,
    Expression<String>? name,
    Expression<String>? nameTH,
    Expression<int>? qty,
    Expression<double>? price,
    Expression<double>? costAtSale,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (saleId != null) 'sale_id': saleId,
      if (productId != null) 'product_id': productId,
      if (partNo != null) 'part_no': partNo,
      if (name != null) 'name': name,
      if (nameTH != null) 'name_t_h': nameTH,
      if (qty != null) 'qty': qty,
      if (price != null) 'price': price,
      if (costAtSale != null) 'cost_at_sale': costAtSale,
    });
  }

  SaleItemsCompanion copyWith({
    Value<int>? rowId,
    Value<String>? saleId,
    Value<String>? productId,
    Value<String?>? partNo,
    Value<String>? name,
    Value<String?>? nameTH,
    Value<int>? qty,
    Value<double>? price,
    Value<double?>? costAtSale,
  }) {
    return SaleItemsCompanion(
      rowId: rowId ?? this.rowId,
      saleId: saleId ?? this.saleId,
      productId: productId ?? this.productId,
      partNo: partNo ?? this.partNo,
      name: name ?? this.name,
      nameTH: nameTH ?? this.nameTH,
      qty: qty ?? this.qty,
      price: price ?? this.price,
      costAtSale: costAtSale ?? this.costAtSale,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<int>(rowId.value);
    }
    if (saleId.present) {
      map['sale_id'] = Variable<String>(saleId.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (partNo.present) {
      map['part_no'] = Variable<String>(partNo.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (nameTH.present) {
      map['name_t_h'] = Variable<String>(nameTH.value);
    }
    if (qty.present) {
      map['qty'] = Variable<int>(qty.value);
    }
    if (price.present) {
      map['price'] = Variable<double>(price.value);
    }
    if (costAtSale.present) {
      map['cost_at_sale'] = Variable<double>(costAtSale.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SaleItemsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('saleId: $saleId, ')
          ..write('productId: $productId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('nameTH: $nameTH, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('costAtSale: $costAtSale')
          ..write(')'))
        .toString();
  }
}

class $PurchaseOrdersTable extends PurchaseOrders
    with TableInfo<$PurchaseOrdersTable, PurchaseOrderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PurchaseOrdersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _poNoMeta = const VerificationMeta('poNo');
  @override
  late final GeneratedColumn<String> poNo = GeneratedColumn<String>(
    'po_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _supplierMeta = const VerificationMeta(
    'supplier',
  );
  @override
  late final GeneratedColumn<String> supplier = GeneratedColumn<String>(
    'supplier',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('open'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  @override
  late final GeneratedColumn<DateTime> receivedAt = GeneratedColumn<DateTime>(
    'received_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cancelledAtMeta = const VerificationMeta(
    'cancelledAt',
  );
  @override
  late final GeneratedColumn<DateTime> cancelledAt = GeneratedColumn<DateTime>(
    'cancelled_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    poNo,
    supplier,
    status,
    createdAt,
    receivedAt,
    cancelledAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'purchase_orders';
  @override
  VerificationContext validateIntegrity(
    Insertable<PurchaseOrderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('po_no')) {
      context.handle(
        _poNoMeta,
        poNo.isAcceptableOrUnknown(data['po_no']!, _poNoMeta),
      );
    } else if (isInserting) {
      context.missing(_poNoMeta);
    }
    if (data.containsKey('supplier')) {
      context.handle(
        _supplierMeta,
        supplier.isAcceptableOrUnknown(data['supplier']!, _supplierMeta),
      );
    } else if (isInserting) {
      context.missing(_supplierMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    }
    if (data.containsKey('cancelled_at')) {
      context.handle(
        _cancelledAtMeta,
        cancelledAt.isAcceptableOrUnknown(
          data['cancelled_at']!,
          _cancelledAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PurchaseOrderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PurchaseOrderRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      poNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}po_no'],
      )!,
      supplier: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}supplier'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}received_at'],
      ),
      cancelledAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cancelled_at'],
      ),
    );
  }

  @override
  $PurchaseOrdersTable createAlias(String alias) {
    return $PurchaseOrdersTable(attachedDatabase, alias);
  }
}

class PurchaseOrderRow extends DataClass
    implements Insertable<PurchaseOrderRow> {
  final String id;
  final String poNo;
  final String supplier;
  final String status;
  final DateTime createdAt;
  final DateTime? receivedAt;
  final DateTime? cancelledAt;
  const PurchaseOrderRow({
    required this.id,
    required this.poNo,
    required this.supplier,
    required this.status,
    required this.createdAt,
    this.receivedAt,
    this.cancelledAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['po_no'] = Variable<String>(poNo);
    map['supplier'] = Variable<String>(supplier);
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || receivedAt != null) {
      map['received_at'] = Variable<DateTime>(receivedAt);
    }
    if (!nullToAbsent || cancelledAt != null) {
      map['cancelled_at'] = Variable<DateTime>(cancelledAt);
    }
    return map;
  }

  PurchaseOrdersCompanion toCompanion(bool nullToAbsent) {
    return PurchaseOrdersCompanion(
      id: Value(id),
      poNo: Value(poNo),
      supplier: Value(supplier),
      status: Value(status),
      createdAt: Value(createdAt),
      receivedAt: receivedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(receivedAt),
      cancelledAt: cancelledAt == null && nullToAbsent
          ? const Value.absent()
          : Value(cancelledAt),
    );
  }

  factory PurchaseOrderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PurchaseOrderRow(
      id: serializer.fromJson<String>(json['id']),
      poNo: serializer.fromJson<String>(json['poNo']),
      supplier: serializer.fromJson<String>(json['supplier']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      receivedAt: serializer.fromJson<DateTime?>(json['receivedAt']),
      cancelledAt: serializer.fromJson<DateTime?>(json['cancelledAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'poNo': serializer.toJson<String>(poNo),
      'supplier': serializer.toJson<String>(supplier),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'receivedAt': serializer.toJson<DateTime?>(receivedAt),
      'cancelledAt': serializer.toJson<DateTime?>(cancelledAt),
    };
  }

  PurchaseOrderRow copyWith({
    String? id,
    String? poNo,
    String? supplier,
    String? status,
    DateTime? createdAt,
    Value<DateTime?> receivedAt = const Value.absent(),
    Value<DateTime?> cancelledAt = const Value.absent(),
  }) => PurchaseOrderRow(
    id: id ?? this.id,
    poNo: poNo ?? this.poNo,
    supplier: supplier ?? this.supplier,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    receivedAt: receivedAt.present ? receivedAt.value : this.receivedAt,
    cancelledAt: cancelledAt.present ? cancelledAt.value : this.cancelledAt,
  );
  PurchaseOrderRow copyWithCompanion(PurchaseOrdersCompanion data) {
    return PurchaseOrderRow(
      id: data.id.present ? data.id.value : this.id,
      poNo: data.poNo.present ? data.poNo.value : this.poNo,
      supplier: data.supplier.present ? data.supplier.value : this.supplier,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
      cancelledAt: data.cancelledAt.present
          ? data.cancelledAt.value
          : this.cancelledAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PurchaseOrderRow(')
          ..write('id: $id, ')
          ..write('poNo: $poNo, ')
          ..write('supplier: $supplier, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('cancelledAt: $cancelledAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    poNo,
    supplier,
    status,
    createdAt,
    receivedAt,
    cancelledAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PurchaseOrderRow &&
          other.id == this.id &&
          other.poNo == this.poNo &&
          other.supplier == this.supplier &&
          other.status == this.status &&
          other.createdAt == this.createdAt &&
          other.receivedAt == this.receivedAt &&
          other.cancelledAt == this.cancelledAt);
}

class PurchaseOrdersCompanion extends UpdateCompanion<PurchaseOrderRow> {
  final Value<String> id;
  final Value<String> poNo;
  final Value<String> supplier;
  final Value<String> status;
  final Value<DateTime> createdAt;
  final Value<DateTime?> receivedAt;
  final Value<DateTime?> cancelledAt;
  final Value<int> rowid;
  const PurchaseOrdersCompanion({
    this.id = const Value.absent(),
    this.poNo = const Value.absent(),
    this.supplier = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.cancelledAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PurchaseOrdersCompanion.insert({
    required String id,
    required String poNo,
    required String supplier,
    this.status = const Value.absent(),
    required DateTime createdAt,
    this.receivedAt = const Value.absent(),
    this.cancelledAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       poNo = Value(poNo),
       supplier = Value(supplier),
       createdAt = Value(createdAt);
  static Insertable<PurchaseOrderRow> custom({
    Expression<String>? id,
    Expression<String>? poNo,
    Expression<String>? supplier,
    Expression<String>? status,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? receivedAt,
    Expression<DateTime>? cancelledAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (poNo != null) 'po_no': poNo,
      if (supplier != null) 'supplier': supplier,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (receivedAt != null) 'received_at': receivedAt,
      if (cancelledAt != null) 'cancelled_at': cancelledAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PurchaseOrdersCompanion copyWith({
    Value<String>? id,
    Value<String>? poNo,
    Value<String>? supplier,
    Value<String>? status,
    Value<DateTime>? createdAt,
    Value<DateTime?>? receivedAt,
    Value<DateTime?>? cancelledAt,
    Value<int>? rowid,
  }) {
    return PurchaseOrdersCompanion(
      id: id ?? this.id,
      poNo: poNo ?? this.poNo,
      supplier: supplier ?? this.supplier,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      receivedAt: receivedAt ?? this.receivedAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (poNo.present) {
      map['po_no'] = Variable<String>(poNo.value);
    }
    if (supplier.present) {
      map['supplier'] = Variable<String>(supplier.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<DateTime>(receivedAt.value);
    }
    if (cancelledAt.present) {
      map['cancelled_at'] = Variable<DateTime>(cancelledAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PurchaseOrdersCompanion(')
          ..write('id: $id, ')
          ..write('poNo: $poNo, ')
          ..write('supplier: $supplier, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('cancelledAt: $cancelledAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PoItemsTable extends PoItems with TableInfo<$PoItemsTable, PoItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PoItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<int> rowId = GeneratedColumn<int>(
    'row_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _poIdMeta = const VerificationMeta('poId');
  @override
  late final GeneratedColumn<String> poId = GeneratedColumn<String>(
    'po_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES purchase_orders (id)',
    ),
  );
  static const VerificationMeta _partNoMeta = const VerificationMeta('partNo');
  @override
  late final GeneratedColumn<String> partNo = GeneratedColumn<String>(
    'part_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _qtyMeta = const VerificationMeta('qty');
  @override
  late final GeneratedColumn<int> qty = GeneratedColumn<int>(
    'qty',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _costMeta = const VerificationMeta('cost');
  @override
  late final GeneratedColumn<double> cost = GeneratedColumn<double>(
    'cost',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [rowId, poId, partNo, name, qty, cost];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'po_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<PoItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    }
    if (data.containsKey('po_id')) {
      context.handle(
        _poIdMeta,
        poId.isAcceptableOrUnknown(data['po_id']!, _poIdMeta),
      );
    } else if (isInserting) {
      context.missing(_poIdMeta);
    }
    if (data.containsKey('part_no')) {
      context.handle(
        _partNoMeta,
        partNo.isAcceptableOrUnknown(data['part_no']!, _partNoMeta),
      );
    } else if (isInserting) {
      context.missing(_partNoMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('qty')) {
      context.handle(
        _qtyMeta,
        qty.isAcceptableOrUnknown(data['qty']!, _qtyMeta),
      );
    } else if (isInserting) {
      context.missing(_qtyMeta);
    }
    if (data.containsKey('cost')) {
      context.handle(
        _costMeta,
        cost.isAcceptableOrUnknown(data['cost']!, _costMeta),
      );
    } else if (isInserting) {
      context.missing(_costMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  PoItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PoItemRow(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}row_id'],
      )!,
      poId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}po_id'],
      )!,
      partNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_no'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      qty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty'],
      )!,
      cost: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost'],
      )!,
    );
  }

  @override
  $PoItemsTable createAlias(String alias) {
    return $PoItemsTable(attachedDatabase, alias);
  }
}

class PoItemRow extends DataClass implements Insertable<PoItemRow> {
  final int rowId;
  final String poId;
  final String partNo;
  final String name;
  final int qty;
  final double cost;
  const PoItemRow({
    required this.rowId,
    required this.poId,
    required this.partNo,
    required this.name,
    required this.qty,
    required this.cost,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<int>(rowId);
    map['po_id'] = Variable<String>(poId);
    map['part_no'] = Variable<String>(partNo);
    map['name'] = Variable<String>(name);
    map['qty'] = Variable<int>(qty);
    map['cost'] = Variable<double>(cost);
    return map;
  }

  PoItemsCompanion toCompanion(bool nullToAbsent) {
    return PoItemsCompanion(
      rowId: Value(rowId),
      poId: Value(poId),
      partNo: Value(partNo),
      name: Value(name),
      qty: Value(qty),
      cost: Value(cost),
    );
  }

  factory PoItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PoItemRow(
      rowId: serializer.fromJson<int>(json['rowId']),
      poId: serializer.fromJson<String>(json['poId']),
      partNo: serializer.fromJson<String>(json['partNo']),
      name: serializer.fromJson<String>(json['name']),
      qty: serializer.fromJson<int>(json['qty']),
      cost: serializer.fromJson<double>(json['cost']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<int>(rowId),
      'poId': serializer.toJson<String>(poId),
      'partNo': serializer.toJson<String>(partNo),
      'name': serializer.toJson<String>(name),
      'qty': serializer.toJson<int>(qty),
      'cost': serializer.toJson<double>(cost),
    };
  }

  PoItemRow copyWith({
    int? rowId,
    String? poId,
    String? partNo,
    String? name,
    int? qty,
    double? cost,
  }) => PoItemRow(
    rowId: rowId ?? this.rowId,
    poId: poId ?? this.poId,
    partNo: partNo ?? this.partNo,
    name: name ?? this.name,
    qty: qty ?? this.qty,
    cost: cost ?? this.cost,
  );
  PoItemRow copyWithCompanion(PoItemsCompanion data) {
    return PoItemRow(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      poId: data.poId.present ? data.poId.value : this.poId,
      partNo: data.partNo.present ? data.partNo.value : this.partNo,
      name: data.name.present ? data.name.value : this.name,
      qty: data.qty.present ? data.qty.value : this.qty,
      cost: data.cost.present ? data.cost.value : this.cost,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PoItemRow(')
          ..write('rowId: $rowId, ')
          ..write('poId: $poId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('cost: $cost')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(rowId, poId, partNo, name, qty, cost);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PoItemRow &&
          other.rowId == this.rowId &&
          other.poId == this.poId &&
          other.partNo == this.partNo &&
          other.name == this.name &&
          other.qty == this.qty &&
          other.cost == this.cost);
}

class PoItemsCompanion extends UpdateCompanion<PoItemRow> {
  final Value<int> rowId;
  final Value<String> poId;
  final Value<String> partNo;
  final Value<String> name;
  final Value<int> qty;
  final Value<double> cost;
  const PoItemsCompanion({
    this.rowId = const Value.absent(),
    this.poId = const Value.absent(),
    this.partNo = const Value.absent(),
    this.name = const Value.absent(),
    this.qty = const Value.absent(),
    this.cost = const Value.absent(),
  });
  PoItemsCompanion.insert({
    this.rowId = const Value.absent(),
    required String poId,
    required String partNo,
    required String name,
    required int qty,
    required double cost,
  }) : poId = Value(poId),
       partNo = Value(partNo),
       name = Value(name),
       qty = Value(qty),
       cost = Value(cost);
  static Insertable<PoItemRow> custom({
    Expression<int>? rowId,
    Expression<String>? poId,
    Expression<String>? partNo,
    Expression<String>? name,
    Expression<int>? qty,
    Expression<double>? cost,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (poId != null) 'po_id': poId,
      if (partNo != null) 'part_no': partNo,
      if (name != null) 'name': name,
      if (qty != null) 'qty': qty,
      if (cost != null) 'cost': cost,
    });
  }

  PoItemsCompanion copyWith({
    Value<int>? rowId,
    Value<String>? poId,
    Value<String>? partNo,
    Value<String>? name,
    Value<int>? qty,
    Value<double>? cost,
  }) {
    return PoItemsCompanion(
      rowId: rowId ?? this.rowId,
      poId: poId ?? this.poId,
      partNo: partNo ?? this.partNo,
      name: name ?? this.name,
      qty: qty ?? this.qty,
      cost: cost ?? this.cost,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<int>(rowId.value);
    }
    if (poId.present) {
      map['po_id'] = Variable<String>(poId.value);
    }
    if (partNo.present) {
      map['part_no'] = Variable<String>(partNo.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (qty.present) {
      map['qty'] = Variable<int>(qty.value);
    }
    if (cost.present) {
      map['cost'] = Variable<double>(cost.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PoItemsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('poId: $poId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('cost: $cost')
          ..write(')'))
        .toString();
  }
}

class $ReturnsTable extends Returns with TableInfo<$ReturnsTable, ReturnRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReturnsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cnNoMeta = const VerificationMeta('cnNo');
  @override
  late final GeneratedColumn<String> cnNo = GeneratedColumn<String>(
    'cn_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _saleIdMeta = const VerificationMeta('saleId');
  @override
  late final GeneratedColumn<String> saleId = GeneratedColumn<String>(
    'sale_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiptNoMeta = const VerificationMeta(
    'receiptNo',
  );
  @override
  late final GeneratedColumn<String> receiptNo = GeneratedColumn<String>(
    'receipt_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _refundSubtotalMeta = const VerificationMeta(
    'refundSubtotal',
  );
  @override
  late final GeneratedColumn<double> refundSubtotal = GeneratedColumn<double>(
    'refund_subtotal',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _refundDiscountMeta = const VerificationMeta(
    'refundDiscount',
  );
  @override
  late final GeneratedColumn<double> refundDiscount = GeneratedColumn<double>(
    'refund_discount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _refundTotalMeta = const VerificationMeta(
    'refundTotal',
  );
  @override
  late final GeneratedColumn<double> refundTotal = GeneratedColumn<double>(
    'refund_total',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _refundMethodMeta = const VerificationMeta(
    'refundMethod',
  );
  @override
  late final GeneratedColumn<String> refundMethod = GeneratedColumn<String>(
    'refund_method',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _customerIdMeta = const VerificationMeta(
    'customerId',
  );
  @override
  late final GeneratedColumn<String> customerId = GeneratedColumn<String>(
    'customer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mechanicIdMeta = const VerificationMeta(
    'mechanicId',
  );
  @override
  late final GeneratedColumn<String> mechanicId = GeneratedColumn<String>(
    'mechanic_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mechanicNameMeta = const VerificationMeta(
    'mechanicName',
  );
  @override
  late final GeneratedColumn<String> mechanicName = GeneratedColumn<String>(
    'mechanic_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    cnNo,
    saleId,
    receiptNo,
    refundSubtotal,
    refundDiscount,
    refundTotal,
    refundMethod,
    reason,
    customerId,
    mechanicId,
    mechanicName,
    date,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'returns';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReturnRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('cn_no')) {
      context.handle(
        _cnNoMeta,
        cnNo.isAcceptableOrUnknown(data['cn_no']!, _cnNoMeta),
      );
    } else if (isInserting) {
      context.missing(_cnNoMeta);
    }
    if (data.containsKey('sale_id')) {
      context.handle(
        _saleIdMeta,
        saleId.isAcceptableOrUnknown(data['sale_id']!, _saleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_saleIdMeta);
    }
    if (data.containsKey('receipt_no')) {
      context.handle(
        _receiptNoMeta,
        receiptNo.isAcceptableOrUnknown(data['receipt_no']!, _receiptNoMeta),
      );
    } else if (isInserting) {
      context.missing(_receiptNoMeta);
    }
    if (data.containsKey('refund_subtotal')) {
      context.handle(
        _refundSubtotalMeta,
        refundSubtotal.isAcceptableOrUnknown(
          data['refund_subtotal']!,
          _refundSubtotalMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_refundSubtotalMeta);
    }
    if (data.containsKey('refund_discount')) {
      context.handle(
        _refundDiscountMeta,
        refundDiscount.isAcceptableOrUnknown(
          data['refund_discount']!,
          _refundDiscountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_refundDiscountMeta);
    }
    if (data.containsKey('refund_total')) {
      context.handle(
        _refundTotalMeta,
        refundTotal.isAcceptableOrUnknown(
          data['refund_total']!,
          _refundTotalMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_refundTotalMeta);
    }
    if (data.containsKey('refund_method')) {
      context.handle(
        _refundMethodMeta,
        refundMethod.isAcceptableOrUnknown(
          data['refund_method']!,
          _refundMethodMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_refundMethodMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
      );
    }
    if (data.containsKey('customer_id')) {
      context.handle(
        _customerIdMeta,
        customerId.isAcceptableOrUnknown(data['customer_id']!, _customerIdMeta),
      );
    }
    if (data.containsKey('mechanic_id')) {
      context.handle(
        _mechanicIdMeta,
        mechanicId.isAcceptableOrUnknown(data['mechanic_id']!, _mechanicIdMeta),
      );
    }
    if (data.containsKey('mechanic_name')) {
      context.handle(
        _mechanicNameMeta,
        mechanicName.isAcceptableOrUnknown(
          data['mechanic_name']!,
          _mechanicNameMeta,
        ),
      );
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReturnRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReturnRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      cnNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cn_no'],
      )!,
      saleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sale_id'],
      )!,
      receiptNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_no'],
      )!,
      refundSubtotal: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}refund_subtotal'],
      )!,
      refundDiscount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}refund_discount'],
      )!,
      refundTotal: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}refund_total'],
      )!,
      refundMethod: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}refund_method'],
      )!,
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      )!,
      customerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_id'],
      ),
      mechanicId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mechanic_id'],
      ),
      mechanicName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mechanic_name'],
      ),
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
    );
  }

  @override
  $ReturnsTable createAlias(String alias) {
    return $ReturnsTable(attachedDatabase, alias);
  }
}

class ReturnRow extends DataClass implements Insertable<ReturnRow> {
  final String id;
  final String cnNo;
  final String saleId;
  final String receiptNo;
  final double refundSubtotal;
  final double refundDiscount;
  final double refundTotal;
  final String refundMethod;
  final String reason;
  final String? customerId;
  final String? mechanicId;
  final String? mechanicName;
  final DateTime date;
  const ReturnRow({
    required this.id,
    required this.cnNo,
    required this.saleId,
    required this.receiptNo,
    required this.refundSubtotal,
    required this.refundDiscount,
    required this.refundTotal,
    required this.refundMethod,
    required this.reason,
    this.customerId,
    this.mechanicId,
    this.mechanicName,
    required this.date,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['cn_no'] = Variable<String>(cnNo);
    map['sale_id'] = Variable<String>(saleId);
    map['receipt_no'] = Variable<String>(receiptNo);
    map['refund_subtotal'] = Variable<double>(refundSubtotal);
    map['refund_discount'] = Variable<double>(refundDiscount);
    map['refund_total'] = Variable<double>(refundTotal);
    map['refund_method'] = Variable<String>(refundMethod);
    map['reason'] = Variable<String>(reason);
    if (!nullToAbsent || customerId != null) {
      map['customer_id'] = Variable<String>(customerId);
    }
    if (!nullToAbsent || mechanicId != null) {
      map['mechanic_id'] = Variable<String>(mechanicId);
    }
    if (!nullToAbsent || mechanicName != null) {
      map['mechanic_name'] = Variable<String>(mechanicName);
    }
    map['date'] = Variable<DateTime>(date);
    return map;
  }

  ReturnsCompanion toCompanion(bool nullToAbsent) {
    return ReturnsCompanion(
      id: Value(id),
      cnNo: Value(cnNo),
      saleId: Value(saleId),
      receiptNo: Value(receiptNo),
      refundSubtotal: Value(refundSubtotal),
      refundDiscount: Value(refundDiscount),
      refundTotal: Value(refundTotal),
      refundMethod: Value(refundMethod),
      reason: Value(reason),
      customerId: customerId == null && nullToAbsent
          ? const Value.absent()
          : Value(customerId),
      mechanicId: mechanicId == null && nullToAbsent
          ? const Value.absent()
          : Value(mechanicId),
      mechanicName: mechanicName == null && nullToAbsent
          ? const Value.absent()
          : Value(mechanicName),
      date: Value(date),
    );
  }

  factory ReturnRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReturnRow(
      id: serializer.fromJson<String>(json['id']),
      cnNo: serializer.fromJson<String>(json['cnNo']),
      saleId: serializer.fromJson<String>(json['saleId']),
      receiptNo: serializer.fromJson<String>(json['receiptNo']),
      refundSubtotal: serializer.fromJson<double>(json['refundSubtotal']),
      refundDiscount: serializer.fromJson<double>(json['refundDiscount']),
      refundTotal: serializer.fromJson<double>(json['refundTotal']),
      refundMethod: serializer.fromJson<String>(json['refundMethod']),
      reason: serializer.fromJson<String>(json['reason']),
      customerId: serializer.fromJson<String?>(json['customerId']),
      mechanicId: serializer.fromJson<String?>(json['mechanicId']),
      mechanicName: serializer.fromJson<String?>(json['mechanicName']),
      date: serializer.fromJson<DateTime>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'cnNo': serializer.toJson<String>(cnNo),
      'saleId': serializer.toJson<String>(saleId),
      'receiptNo': serializer.toJson<String>(receiptNo),
      'refundSubtotal': serializer.toJson<double>(refundSubtotal),
      'refundDiscount': serializer.toJson<double>(refundDiscount),
      'refundTotal': serializer.toJson<double>(refundTotal),
      'refundMethod': serializer.toJson<String>(refundMethod),
      'reason': serializer.toJson<String>(reason),
      'customerId': serializer.toJson<String?>(customerId),
      'mechanicId': serializer.toJson<String?>(mechanicId),
      'mechanicName': serializer.toJson<String?>(mechanicName),
      'date': serializer.toJson<DateTime>(date),
    };
  }

  ReturnRow copyWith({
    String? id,
    String? cnNo,
    String? saleId,
    String? receiptNo,
    double? refundSubtotal,
    double? refundDiscount,
    double? refundTotal,
    String? refundMethod,
    String? reason,
    Value<String?> customerId = const Value.absent(),
    Value<String?> mechanicId = const Value.absent(),
    Value<String?> mechanicName = const Value.absent(),
    DateTime? date,
  }) => ReturnRow(
    id: id ?? this.id,
    cnNo: cnNo ?? this.cnNo,
    saleId: saleId ?? this.saleId,
    receiptNo: receiptNo ?? this.receiptNo,
    refundSubtotal: refundSubtotal ?? this.refundSubtotal,
    refundDiscount: refundDiscount ?? this.refundDiscount,
    refundTotal: refundTotal ?? this.refundTotal,
    refundMethod: refundMethod ?? this.refundMethod,
    reason: reason ?? this.reason,
    customerId: customerId.present ? customerId.value : this.customerId,
    mechanicId: mechanicId.present ? mechanicId.value : this.mechanicId,
    mechanicName: mechanicName.present ? mechanicName.value : this.mechanicName,
    date: date ?? this.date,
  );
  ReturnRow copyWithCompanion(ReturnsCompanion data) {
    return ReturnRow(
      id: data.id.present ? data.id.value : this.id,
      cnNo: data.cnNo.present ? data.cnNo.value : this.cnNo,
      saleId: data.saleId.present ? data.saleId.value : this.saleId,
      receiptNo: data.receiptNo.present ? data.receiptNo.value : this.receiptNo,
      refundSubtotal: data.refundSubtotal.present
          ? data.refundSubtotal.value
          : this.refundSubtotal,
      refundDiscount: data.refundDiscount.present
          ? data.refundDiscount.value
          : this.refundDiscount,
      refundTotal: data.refundTotal.present
          ? data.refundTotal.value
          : this.refundTotal,
      refundMethod: data.refundMethod.present
          ? data.refundMethod.value
          : this.refundMethod,
      reason: data.reason.present ? data.reason.value : this.reason,
      customerId: data.customerId.present
          ? data.customerId.value
          : this.customerId,
      mechanicId: data.mechanicId.present
          ? data.mechanicId.value
          : this.mechanicId,
      mechanicName: data.mechanicName.present
          ? data.mechanicName.value
          : this.mechanicName,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReturnRow(')
          ..write('id: $id, ')
          ..write('cnNo: $cnNo, ')
          ..write('saleId: $saleId, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('refundSubtotal: $refundSubtotal, ')
          ..write('refundDiscount: $refundDiscount, ')
          ..write('refundTotal: $refundTotal, ')
          ..write('refundMethod: $refundMethod, ')
          ..write('reason: $reason, ')
          ..write('customerId: $customerId, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('mechanicName: $mechanicName, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    cnNo,
    saleId,
    receiptNo,
    refundSubtotal,
    refundDiscount,
    refundTotal,
    refundMethod,
    reason,
    customerId,
    mechanicId,
    mechanicName,
    date,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReturnRow &&
          other.id == this.id &&
          other.cnNo == this.cnNo &&
          other.saleId == this.saleId &&
          other.receiptNo == this.receiptNo &&
          other.refundSubtotal == this.refundSubtotal &&
          other.refundDiscount == this.refundDiscount &&
          other.refundTotal == this.refundTotal &&
          other.refundMethod == this.refundMethod &&
          other.reason == this.reason &&
          other.customerId == this.customerId &&
          other.mechanicId == this.mechanicId &&
          other.mechanicName == this.mechanicName &&
          other.date == this.date);
}

class ReturnsCompanion extends UpdateCompanion<ReturnRow> {
  final Value<String> id;
  final Value<String> cnNo;
  final Value<String> saleId;
  final Value<String> receiptNo;
  final Value<double> refundSubtotal;
  final Value<double> refundDiscount;
  final Value<double> refundTotal;
  final Value<String> refundMethod;
  final Value<String> reason;
  final Value<String?> customerId;
  final Value<String?> mechanicId;
  final Value<String?> mechanicName;
  final Value<DateTime> date;
  final Value<int> rowid;
  const ReturnsCompanion({
    this.id = const Value.absent(),
    this.cnNo = const Value.absent(),
    this.saleId = const Value.absent(),
    this.receiptNo = const Value.absent(),
    this.refundSubtotal = const Value.absent(),
    this.refundDiscount = const Value.absent(),
    this.refundTotal = const Value.absent(),
    this.refundMethod = const Value.absent(),
    this.reason = const Value.absent(),
    this.customerId = const Value.absent(),
    this.mechanicId = const Value.absent(),
    this.mechanicName = const Value.absent(),
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReturnsCompanion.insert({
    required String id,
    required String cnNo,
    required String saleId,
    required String receiptNo,
    required double refundSubtotal,
    required double refundDiscount,
    required double refundTotal,
    required String refundMethod,
    this.reason = const Value.absent(),
    this.customerId = const Value.absent(),
    this.mechanicId = const Value.absent(),
    this.mechanicName = const Value.absent(),
    required DateTime date,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       cnNo = Value(cnNo),
       saleId = Value(saleId),
       receiptNo = Value(receiptNo),
       refundSubtotal = Value(refundSubtotal),
       refundDiscount = Value(refundDiscount),
       refundTotal = Value(refundTotal),
       refundMethod = Value(refundMethod),
       date = Value(date);
  static Insertable<ReturnRow> custom({
    Expression<String>? id,
    Expression<String>? cnNo,
    Expression<String>? saleId,
    Expression<String>? receiptNo,
    Expression<double>? refundSubtotal,
    Expression<double>? refundDiscount,
    Expression<double>? refundTotal,
    Expression<String>? refundMethod,
    Expression<String>? reason,
    Expression<String>? customerId,
    Expression<String>? mechanicId,
    Expression<String>? mechanicName,
    Expression<DateTime>? date,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (cnNo != null) 'cn_no': cnNo,
      if (saleId != null) 'sale_id': saleId,
      if (receiptNo != null) 'receipt_no': receiptNo,
      if (refundSubtotal != null) 'refund_subtotal': refundSubtotal,
      if (refundDiscount != null) 'refund_discount': refundDiscount,
      if (refundTotal != null) 'refund_total': refundTotal,
      if (refundMethod != null) 'refund_method': refundMethod,
      if (reason != null) 'reason': reason,
      if (customerId != null) 'customer_id': customerId,
      if (mechanicId != null) 'mechanic_id': mechanicId,
      if (mechanicName != null) 'mechanic_name': mechanicName,
      if (date != null) 'date': date,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReturnsCompanion copyWith({
    Value<String>? id,
    Value<String>? cnNo,
    Value<String>? saleId,
    Value<String>? receiptNo,
    Value<double>? refundSubtotal,
    Value<double>? refundDiscount,
    Value<double>? refundTotal,
    Value<String>? refundMethod,
    Value<String>? reason,
    Value<String?>? customerId,
    Value<String?>? mechanicId,
    Value<String?>? mechanicName,
    Value<DateTime>? date,
    Value<int>? rowid,
  }) {
    return ReturnsCompanion(
      id: id ?? this.id,
      cnNo: cnNo ?? this.cnNo,
      saleId: saleId ?? this.saleId,
      receiptNo: receiptNo ?? this.receiptNo,
      refundSubtotal: refundSubtotal ?? this.refundSubtotal,
      refundDiscount: refundDiscount ?? this.refundDiscount,
      refundTotal: refundTotal ?? this.refundTotal,
      refundMethod: refundMethod ?? this.refundMethod,
      reason: reason ?? this.reason,
      customerId: customerId ?? this.customerId,
      mechanicId: mechanicId ?? this.mechanicId,
      mechanicName: mechanicName ?? this.mechanicName,
      date: date ?? this.date,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (cnNo.present) {
      map['cn_no'] = Variable<String>(cnNo.value);
    }
    if (saleId.present) {
      map['sale_id'] = Variable<String>(saleId.value);
    }
    if (receiptNo.present) {
      map['receipt_no'] = Variable<String>(receiptNo.value);
    }
    if (refundSubtotal.present) {
      map['refund_subtotal'] = Variable<double>(refundSubtotal.value);
    }
    if (refundDiscount.present) {
      map['refund_discount'] = Variable<double>(refundDiscount.value);
    }
    if (refundTotal.present) {
      map['refund_total'] = Variable<double>(refundTotal.value);
    }
    if (refundMethod.present) {
      map['refund_method'] = Variable<String>(refundMethod.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (customerId.present) {
      map['customer_id'] = Variable<String>(customerId.value);
    }
    if (mechanicId.present) {
      map['mechanic_id'] = Variable<String>(mechanicId.value);
    }
    if (mechanicName.present) {
      map['mechanic_name'] = Variable<String>(mechanicName.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReturnsCompanion(')
          ..write('id: $id, ')
          ..write('cnNo: $cnNo, ')
          ..write('saleId: $saleId, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('refundSubtotal: $refundSubtotal, ')
          ..write('refundDiscount: $refundDiscount, ')
          ..write('refundTotal: $refundTotal, ')
          ..write('refundMethod: $refundMethod, ')
          ..write('reason: $reason, ')
          ..write('customerId: $customerId, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('mechanicName: $mechanicName, ')
          ..write('date: $date, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReturnItemsTable extends ReturnItems
    with TableInfo<$ReturnItemsTable, ReturnItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReturnItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<int> rowId = GeneratedColumn<int>(
    'row_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _returnIdMeta = const VerificationMeta(
    'returnId',
  );
  @override
  late final GeneratedColumn<String> returnId = GeneratedColumn<String>(
    'return_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES returns (id)',
    ),
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _qtyMeta = const VerificationMeta('qty');
  @override
  late final GeneratedColumn<int> qty = GeneratedColumn<int>(
    'qty',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<double> price = GeneratedColumn<double>(
    'price',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalQtyMeta = const VerificationMeta(
    'originalQty',
  );
  @override
  late final GeneratedColumn<int> originalQty = GeneratedColumn<int>(
    'original_qty',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    rowId,
    returnId,
    productId,
    name,
    qty,
    price,
    originalQty,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'return_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReturnItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    }
    if (data.containsKey('return_id')) {
      context.handle(
        _returnIdMeta,
        returnId.isAcceptableOrUnknown(data['return_id']!, _returnIdMeta),
      );
    } else if (isInserting) {
      context.missing(_returnIdMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('qty')) {
      context.handle(
        _qtyMeta,
        qty.isAcceptableOrUnknown(data['qty']!, _qtyMeta),
      );
    } else if (isInserting) {
      context.missing(_qtyMeta);
    }
    if (data.containsKey('price')) {
      context.handle(
        _priceMeta,
        price.isAcceptableOrUnknown(data['price']!, _priceMeta),
      );
    } else if (isInserting) {
      context.missing(_priceMeta);
    }
    if (data.containsKey('original_qty')) {
      context.handle(
        _originalQtyMeta,
        originalQty.isAcceptableOrUnknown(
          data['original_qty']!,
          _originalQtyMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  ReturnItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReturnItemRow(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}row_id'],
      )!,
      returnId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}return_id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      qty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty'],
      )!,
      price: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}price'],
      )!,
      originalQty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}original_qty'],
      ),
    );
  }

  @override
  $ReturnItemsTable createAlias(String alias) {
    return $ReturnItemsTable(attachedDatabase, alias);
  }
}

class ReturnItemRow extends DataClass implements Insertable<ReturnItemRow> {
  final int rowId;
  final String returnId;
  final String productId;
  final String name;
  final int qty;
  final double price;
  final int? originalQty;
  const ReturnItemRow({
    required this.rowId,
    required this.returnId,
    required this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.originalQty,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<int>(rowId);
    map['return_id'] = Variable<String>(returnId);
    map['product_id'] = Variable<String>(productId);
    map['name'] = Variable<String>(name);
    map['qty'] = Variable<int>(qty);
    map['price'] = Variable<double>(price);
    if (!nullToAbsent || originalQty != null) {
      map['original_qty'] = Variable<int>(originalQty);
    }
    return map;
  }

  ReturnItemsCompanion toCompanion(bool nullToAbsent) {
    return ReturnItemsCompanion(
      rowId: Value(rowId),
      returnId: Value(returnId),
      productId: Value(productId),
      name: Value(name),
      qty: Value(qty),
      price: Value(price),
      originalQty: originalQty == null && nullToAbsent
          ? const Value.absent()
          : Value(originalQty),
    );
  }

  factory ReturnItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReturnItemRow(
      rowId: serializer.fromJson<int>(json['rowId']),
      returnId: serializer.fromJson<String>(json['returnId']),
      productId: serializer.fromJson<String>(json['productId']),
      name: serializer.fromJson<String>(json['name']),
      qty: serializer.fromJson<int>(json['qty']),
      price: serializer.fromJson<double>(json['price']),
      originalQty: serializer.fromJson<int?>(json['originalQty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<int>(rowId),
      'returnId': serializer.toJson<String>(returnId),
      'productId': serializer.toJson<String>(productId),
      'name': serializer.toJson<String>(name),
      'qty': serializer.toJson<int>(qty),
      'price': serializer.toJson<double>(price),
      'originalQty': serializer.toJson<int?>(originalQty),
    };
  }

  ReturnItemRow copyWith({
    int? rowId,
    String? returnId,
    String? productId,
    String? name,
    int? qty,
    double? price,
    Value<int?> originalQty = const Value.absent(),
  }) => ReturnItemRow(
    rowId: rowId ?? this.rowId,
    returnId: returnId ?? this.returnId,
    productId: productId ?? this.productId,
    name: name ?? this.name,
    qty: qty ?? this.qty,
    price: price ?? this.price,
    originalQty: originalQty.present ? originalQty.value : this.originalQty,
  );
  ReturnItemRow copyWithCompanion(ReturnItemsCompanion data) {
    return ReturnItemRow(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      returnId: data.returnId.present ? data.returnId.value : this.returnId,
      productId: data.productId.present ? data.productId.value : this.productId,
      name: data.name.present ? data.name.value : this.name,
      qty: data.qty.present ? data.qty.value : this.qty,
      price: data.price.present ? data.price.value : this.price,
      originalQty: data.originalQty.present
          ? data.originalQty.value
          : this.originalQty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReturnItemRow(')
          ..write('rowId: $rowId, ')
          ..write('returnId: $returnId, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('originalQty: $originalQty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(rowId, returnId, productId, name, qty, price, originalQty);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReturnItemRow &&
          other.rowId == this.rowId &&
          other.returnId == this.returnId &&
          other.productId == this.productId &&
          other.name == this.name &&
          other.qty == this.qty &&
          other.price == this.price &&
          other.originalQty == this.originalQty);
}

class ReturnItemsCompanion extends UpdateCompanion<ReturnItemRow> {
  final Value<int> rowId;
  final Value<String> returnId;
  final Value<String> productId;
  final Value<String> name;
  final Value<int> qty;
  final Value<double> price;
  final Value<int?> originalQty;
  const ReturnItemsCompanion({
    this.rowId = const Value.absent(),
    this.returnId = const Value.absent(),
    this.productId = const Value.absent(),
    this.name = const Value.absent(),
    this.qty = const Value.absent(),
    this.price = const Value.absent(),
    this.originalQty = const Value.absent(),
  });
  ReturnItemsCompanion.insert({
    this.rowId = const Value.absent(),
    required String returnId,
    required String productId,
    required String name,
    required int qty,
    required double price,
    this.originalQty = const Value.absent(),
  }) : returnId = Value(returnId),
       productId = Value(productId),
       name = Value(name),
       qty = Value(qty),
       price = Value(price);
  static Insertable<ReturnItemRow> custom({
    Expression<int>? rowId,
    Expression<String>? returnId,
    Expression<String>? productId,
    Expression<String>? name,
    Expression<int>? qty,
    Expression<double>? price,
    Expression<int>? originalQty,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (returnId != null) 'return_id': returnId,
      if (productId != null) 'product_id': productId,
      if (name != null) 'name': name,
      if (qty != null) 'qty': qty,
      if (price != null) 'price': price,
      if (originalQty != null) 'original_qty': originalQty,
    });
  }

  ReturnItemsCompanion copyWith({
    Value<int>? rowId,
    Value<String>? returnId,
    Value<String>? productId,
    Value<String>? name,
    Value<int>? qty,
    Value<double>? price,
    Value<int?>? originalQty,
  }) {
    return ReturnItemsCompanion(
      rowId: rowId ?? this.rowId,
      returnId: returnId ?? this.returnId,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      qty: qty ?? this.qty,
      price: price ?? this.price,
      originalQty: originalQty ?? this.originalQty,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<int>(rowId.value);
    }
    if (returnId.present) {
      map['return_id'] = Variable<String>(returnId.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (qty.present) {
      map['qty'] = Variable<int>(qty.value);
    }
    if (price.present) {
      map['price'] = Variable<double>(price.value);
    }
    if (originalQty.present) {
      map['original_qty'] = Variable<int>(originalQty.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReturnItemsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('returnId: $returnId, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('originalQty: $originalQty')
          ..write(')'))
        .toString();
  }
}

class $QuotesTable extends Quotes with TableInfo<$QuotesTable, QuoteRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _quoteNoMeta = const VerificationMeta(
    'quoteNo',
  );
  @override
  late final GeneratedColumn<String> quoteNo = GeneratedColumn<String>(
    'quote_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('open'),
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _validUntilMeta = const VerificationMeta(
    'validUntil',
  );
  @override
  late final GeneratedColumn<DateTime> validUntil = GeneratedColumn<DateTime>(
    'valid_until',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _convertedAtMeta = const VerificationMeta(
    'convertedAt',
  );
  @override
  late final GeneratedColumn<DateTime> convertedAt = GeneratedColumn<DateTime>(
    'converted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _subtotalMeta = const VerificationMeta(
    'subtotal',
  );
  @override
  late final GeneratedColumn<double> subtotal = GeneratedColumn<double>(
    'subtotal',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _discountMeta = const VerificationMeta(
    'discount',
  );
  @override
  late final GeneratedColumn<double> discount = GeneratedColumn<double>(
    'discount',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalMeta = const VerificationMeta('total');
  @override
  late final GeneratedColumn<double> total = GeneratedColumn<double>(
    'total',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _customerNameMeta = const VerificationMeta(
    'customerName',
  );
  @override
  late final GeneratedColumn<String> customerName = GeneratedColumn<String>(
    'customer_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _customerPhoneMeta = const VerificationMeta(
    'customerPhone',
  );
  @override
  late final GeneratedColumn<String> customerPhone = GeneratedColumn<String>(
    'customer_phone',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _validDaysMeta = const VerificationMeta(
    'validDays',
  );
  @override
  late final GeneratedColumn<int> validDays = GeneratedColumn<int>(
    'valid_days',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    quoteNo,
    status,
    date,
    validUntil,
    convertedAt,
    subtotal,
    discount,
    total,
    customerName,
    customerPhone,
    notes,
    validDays,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'quotes';
  @override
  VerificationContext validateIntegrity(
    Insertable<QuoteRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('quote_no')) {
      context.handle(
        _quoteNoMeta,
        quoteNo.isAcceptableOrUnknown(data['quote_no']!, _quoteNoMeta),
      );
    } else if (isInserting) {
      context.missing(_quoteNoMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    if (data.containsKey('valid_until')) {
      context.handle(
        _validUntilMeta,
        validUntil.isAcceptableOrUnknown(data['valid_until']!, _validUntilMeta),
      );
    } else if (isInserting) {
      context.missing(_validUntilMeta);
    }
    if (data.containsKey('converted_at')) {
      context.handle(
        _convertedAtMeta,
        convertedAt.isAcceptableOrUnknown(
          data['converted_at']!,
          _convertedAtMeta,
        ),
      );
    }
    if (data.containsKey('subtotal')) {
      context.handle(
        _subtotalMeta,
        subtotal.isAcceptableOrUnknown(data['subtotal']!, _subtotalMeta),
      );
    }
    if (data.containsKey('discount')) {
      context.handle(
        _discountMeta,
        discount.isAcceptableOrUnknown(data['discount']!, _discountMeta),
      );
    }
    if (data.containsKey('total')) {
      context.handle(
        _totalMeta,
        total.isAcceptableOrUnknown(data['total']!, _totalMeta),
      );
    }
    if (data.containsKey('customer_name')) {
      context.handle(
        _customerNameMeta,
        customerName.isAcceptableOrUnknown(
          data['customer_name']!,
          _customerNameMeta,
        ),
      );
    }
    if (data.containsKey('customer_phone')) {
      context.handle(
        _customerPhoneMeta,
        customerPhone.isAcceptableOrUnknown(
          data['customer_phone']!,
          _customerPhoneMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('valid_days')) {
      context.handle(
        _validDaysMeta,
        validDays.isAcceptableOrUnknown(data['valid_days']!, _validDaysMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  QuoteRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QuoteRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      quoteNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quote_no'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
      validUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}valid_until'],
      )!,
      convertedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}converted_at'],
      ),
      subtotal: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}subtotal'],
      ),
      discount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}discount'],
      ),
      total: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}total'],
      ),
      customerName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_name'],
      ),
      customerPhone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}customer_phone'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
      validDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}valid_days'],
      ),
    );
  }

  @override
  $QuotesTable createAlias(String alias) {
    return $QuotesTable(attachedDatabase, alias);
  }
}

class QuoteRow extends DataClass implements Insertable<QuoteRow> {
  final String id;
  final String quoteNo;
  final String status;
  final DateTime date;
  final DateTime validUntil;
  final DateTime? convertedAt;
  final double? subtotal;
  final double? discount;
  final double? total;
  final String? customerName;
  final String? customerPhone;
  final String? notes;
  final int? validDays;
  const QuoteRow({
    required this.id,
    required this.quoteNo,
    required this.status,
    required this.date,
    required this.validUntil,
    this.convertedAt,
    this.subtotal,
    this.discount,
    this.total,
    this.customerName,
    this.customerPhone,
    this.notes,
    this.validDays,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['quote_no'] = Variable<String>(quoteNo);
    map['status'] = Variable<String>(status);
    map['date'] = Variable<DateTime>(date);
    map['valid_until'] = Variable<DateTime>(validUntil);
    if (!nullToAbsent || convertedAt != null) {
      map['converted_at'] = Variable<DateTime>(convertedAt);
    }
    if (!nullToAbsent || subtotal != null) {
      map['subtotal'] = Variable<double>(subtotal);
    }
    if (!nullToAbsent || discount != null) {
      map['discount'] = Variable<double>(discount);
    }
    if (!nullToAbsent || total != null) {
      map['total'] = Variable<double>(total);
    }
    if (!nullToAbsent || customerName != null) {
      map['customer_name'] = Variable<String>(customerName);
    }
    if (!nullToAbsent || customerPhone != null) {
      map['customer_phone'] = Variable<String>(customerPhone);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || validDays != null) {
      map['valid_days'] = Variable<int>(validDays);
    }
    return map;
  }

  QuotesCompanion toCompanion(bool nullToAbsent) {
    return QuotesCompanion(
      id: Value(id),
      quoteNo: Value(quoteNo),
      status: Value(status),
      date: Value(date),
      validUntil: Value(validUntil),
      convertedAt: convertedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(convertedAt),
      subtotal: subtotal == null && nullToAbsent
          ? const Value.absent()
          : Value(subtotal),
      discount: discount == null && nullToAbsent
          ? const Value.absent()
          : Value(discount),
      total: total == null && nullToAbsent
          ? const Value.absent()
          : Value(total),
      customerName: customerName == null && nullToAbsent
          ? const Value.absent()
          : Value(customerName),
      customerPhone: customerPhone == null && nullToAbsent
          ? const Value.absent()
          : Value(customerPhone),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
      validDays: validDays == null && nullToAbsent
          ? const Value.absent()
          : Value(validDays),
    );
  }

  factory QuoteRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QuoteRow(
      id: serializer.fromJson<String>(json['id']),
      quoteNo: serializer.fromJson<String>(json['quoteNo']),
      status: serializer.fromJson<String>(json['status']),
      date: serializer.fromJson<DateTime>(json['date']),
      validUntil: serializer.fromJson<DateTime>(json['validUntil']),
      convertedAt: serializer.fromJson<DateTime?>(json['convertedAt']),
      subtotal: serializer.fromJson<double?>(json['subtotal']),
      discount: serializer.fromJson<double?>(json['discount']),
      total: serializer.fromJson<double?>(json['total']),
      customerName: serializer.fromJson<String?>(json['customerName']),
      customerPhone: serializer.fromJson<String?>(json['customerPhone']),
      notes: serializer.fromJson<String?>(json['notes']),
      validDays: serializer.fromJson<int?>(json['validDays']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'quoteNo': serializer.toJson<String>(quoteNo),
      'status': serializer.toJson<String>(status),
      'date': serializer.toJson<DateTime>(date),
      'validUntil': serializer.toJson<DateTime>(validUntil),
      'convertedAt': serializer.toJson<DateTime?>(convertedAt),
      'subtotal': serializer.toJson<double?>(subtotal),
      'discount': serializer.toJson<double?>(discount),
      'total': serializer.toJson<double?>(total),
      'customerName': serializer.toJson<String?>(customerName),
      'customerPhone': serializer.toJson<String?>(customerPhone),
      'notes': serializer.toJson<String?>(notes),
      'validDays': serializer.toJson<int?>(validDays),
    };
  }

  QuoteRow copyWith({
    String? id,
    String? quoteNo,
    String? status,
    DateTime? date,
    DateTime? validUntil,
    Value<DateTime?> convertedAt = const Value.absent(),
    Value<double?> subtotal = const Value.absent(),
    Value<double?> discount = const Value.absent(),
    Value<double?> total = const Value.absent(),
    Value<String?> customerName = const Value.absent(),
    Value<String?> customerPhone = const Value.absent(),
    Value<String?> notes = const Value.absent(),
    Value<int?> validDays = const Value.absent(),
  }) => QuoteRow(
    id: id ?? this.id,
    quoteNo: quoteNo ?? this.quoteNo,
    status: status ?? this.status,
    date: date ?? this.date,
    validUntil: validUntil ?? this.validUntil,
    convertedAt: convertedAt.present ? convertedAt.value : this.convertedAt,
    subtotal: subtotal.present ? subtotal.value : this.subtotal,
    discount: discount.present ? discount.value : this.discount,
    total: total.present ? total.value : this.total,
    customerName: customerName.present ? customerName.value : this.customerName,
    customerPhone: customerPhone.present
        ? customerPhone.value
        : this.customerPhone,
    notes: notes.present ? notes.value : this.notes,
    validDays: validDays.present ? validDays.value : this.validDays,
  );
  QuoteRow copyWithCompanion(QuotesCompanion data) {
    return QuoteRow(
      id: data.id.present ? data.id.value : this.id,
      quoteNo: data.quoteNo.present ? data.quoteNo.value : this.quoteNo,
      status: data.status.present ? data.status.value : this.status,
      date: data.date.present ? data.date.value : this.date,
      validUntil: data.validUntil.present
          ? data.validUntil.value
          : this.validUntil,
      convertedAt: data.convertedAt.present
          ? data.convertedAt.value
          : this.convertedAt,
      subtotal: data.subtotal.present ? data.subtotal.value : this.subtotal,
      discount: data.discount.present ? data.discount.value : this.discount,
      total: data.total.present ? data.total.value : this.total,
      customerName: data.customerName.present
          ? data.customerName.value
          : this.customerName,
      customerPhone: data.customerPhone.present
          ? data.customerPhone.value
          : this.customerPhone,
      notes: data.notes.present ? data.notes.value : this.notes,
      validDays: data.validDays.present ? data.validDays.value : this.validDays,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QuoteRow(')
          ..write('id: $id, ')
          ..write('quoteNo: $quoteNo, ')
          ..write('status: $status, ')
          ..write('date: $date, ')
          ..write('validUntil: $validUntil, ')
          ..write('convertedAt: $convertedAt, ')
          ..write('subtotal: $subtotal, ')
          ..write('discount: $discount, ')
          ..write('total: $total, ')
          ..write('customerName: $customerName, ')
          ..write('customerPhone: $customerPhone, ')
          ..write('notes: $notes, ')
          ..write('validDays: $validDays')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    quoteNo,
    status,
    date,
    validUntil,
    convertedAt,
    subtotal,
    discount,
    total,
    customerName,
    customerPhone,
    notes,
    validDays,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QuoteRow &&
          other.id == this.id &&
          other.quoteNo == this.quoteNo &&
          other.status == this.status &&
          other.date == this.date &&
          other.validUntil == this.validUntil &&
          other.convertedAt == this.convertedAt &&
          other.subtotal == this.subtotal &&
          other.discount == this.discount &&
          other.total == this.total &&
          other.customerName == this.customerName &&
          other.customerPhone == this.customerPhone &&
          other.notes == this.notes &&
          other.validDays == this.validDays);
}

class QuotesCompanion extends UpdateCompanion<QuoteRow> {
  final Value<String> id;
  final Value<String> quoteNo;
  final Value<String> status;
  final Value<DateTime> date;
  final Value<DateTime> validUntil;
  final Value<DateTime?> convertedAt;
  final Value<double?> subtotal;
  final Value<double?> discount;
  final Value<double?> total;
  final Value<String?> customerName;
  final Value<String?> customerPhone;
  final Value<String?> notes;
  final Value<int?> validDays;
  final Value<int> rowid;
  const QuotesCompanion({
    this.id = const Value.absent(),
    this.quoteNo = const Value.absent(),
    this.status = const Value.absent(),
    this.date = const Value.absent(),
    this.validUntil = const Value.absent(),
    this.convertedAt = const Value.absent(),
    this.subtotal = const Value.absent(),
    this.discount = const Value.absent(),
    this.total = const Value.absent(),
    this.customerName = const Value.absent(),
    this.customerPhone = const Value.absent(),
    this.notes = const Value.absent(),
    this.validDays = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QuotesCompanion.insert({
    required String id,
    required String quoteNo,
    this.status = const Value.absent(),
    required DateTime date,
    required DateTime validUntil,
    this.convertedAt = const Value.absent(),
    this.subtotal = const Value.absent(),
    this.discount = const Value.absent(),
    this.total = const Value.absent(),
    this.customerName = const Value.absent(),
    this.customerPhone = const Value.absent(),
    this.notes = const Value.absent(),
    this.validDays = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       quoteNo = Value(quoteNo),
       date = Value(date),
       validUntil = Value(validUntil);
  static Insertable<QuoteRow> custom({
    Expression<String>? id,
    Expression<String>? quoteNo,
    Expression<String>? status,
    Expression<DateTime>? date,
    Expression<DateTime>? validUntil,
    Expression<DateTime>? convertedAt,
    Expression<double>? subtotal,
    Expression<double>? discount,
    Expression<double>? total,
    Expression<String>? customerName,
    Expression<String>? customerPhone,
    Expression<String>? notes,
    Expression<int>? validDays,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (quoteNo != null) 'quote_no': quoteNo,
      if (status != null) 'status': status,
      if (date != null) 'date': date,
      if (validUntil != null) 'valid_until': validUntil,
      if (convertedAt != null) 'converted_at': convertedAt,
      if (subtotal != null) 'subtotal': subtotal,
      if (discount != null) 'discount': discount,
      if (total != null) 'total': total,
      if (customerName != null) 'customer_name': customerName,
      if (customerPhone != null) 'customer_phone': customerPhone,
      if (notes != null) 'notes': notes,
      if (validDays != null) 'valid_days': validDays,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QuotesCompanion copyWith({
    Value<String>? id,
    Value<String>? quoteNo,
    Value<String>? status,
    Value<DateTime>? date,
    Value<DateTime>? validUntil,
    Value<DateTime?>? convertedAt,
    Value<double?>? subtotal,
    Value<double?>? discount,
    Value<double?>? total,
    Value<String?>? customerName,
    Value<String?>? customerPhone,
    Value<String?>? notes,
    Value<int?>? validDays,
    Value<int>? rowid,
  }) {
    return QuotesCompanion(
      id: id ?? this.id,
      quoteNo: quoteNo ?? this.quoteNo,
      status: status ?? this.status,
      date: date ?? this.date,
      validUntil: validUntil ?? this.validUntil,
      convertedAt: convertedAt ?? this.convertedAt,
      subtotal: subtotal ?? this.subtotal,
      discount: discount ?? this.discount,
      total: total ?? this.total,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      notes: notes ?? this.notes,
      validDays: validDays ?? this.validDays,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (quoteNo.present) {
      map['quote_no'] = Variable<String>(quoteNo.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (validUntil.present) {
      map['valid_until'] = Variable<DateTime>(validUntil.value);
    }
    if (convertedAt.present) {
      map['converted_at'] = Variable<DateTime>(convertedAt.value);
    }
    if (subtotal.present) {
      map['subtotal'] = Variable<double>(subtotal.value);
    }
    if (discount.present) {
      map['discount'] = Variable<double>(discount.value);
    }
    if (total.present) {
      map['total'] = Variable<double>(total.value);
    }
    if (customerName.present) {
      map['customer_name'] = Variable<String>(customerName.value);
    }
    if (customerPhone.present) {
      map['customer_phone'] = Variable<String>(customerPhone.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (validDays.present) {
      map['valid_days'] = Variable<int>(validDays.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuotesCompanion(')
          ..write('id: $id, ')
          ..write('quoteNo: $quoteNo, ')
          ..write('status: $status, ')
          ..write('date: $date, ')
          ..write('validUntil: $validUntil, ')
          ..write('convertedAt: $convertedAt, ')
          ..write('subtotal: $subtotal, ')
          ..write('discount: $discount, ')
          ..write('total: $total, ')
          ..write('customerName: $customerName, ')
          ..write('customerPhone: $customerPhone, ')
          ..write('notes: $notes, ')
          ..write('validDays: $validDays, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $QuoteItemsTable extends QuoteItems
    with TableInfo<$QuoteItemsTable, QuoteItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuoteItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<int> rowId = GeneratedColumn<int>(
    'row_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _quoteIdMeta = const VerificationMeta(
    'quoteId',
  );
  @override
  late final GeneratedColumn<String> quoteId = GeneratedColumn<String>(
    'quote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES quotes (id)',
    ),
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _qtyMeta = const VerificationMeta('qty');
  @override
  late final GeneratedColumn<int> qty = GeneratedColumn<int>(
    'qty',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priceMeta = const VerificationMeta('price');
  @override
  late final GeneratedColumn<double> price = GeneratedColumn<double>(
    'price',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _costAtSaleMeta = const VerificationMeta(
    'costAtSale',
  );
  @override
  late final GeneratedColumn<double> costAtSale = GeneratedColumn<double>(
    'cost_at_sale',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    rowId,
    quoteId,
    productId,
    name,
    qty,
    price,
    costAtSale,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'quote_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<QuoteItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    }
    if (data.containsKey('quote_id')) {
      context.handle(
        _quoteIdMeta,
        quoteId.isAcceptableOrUnknown(data['quote_id']!, _quoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_quoteIdMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('qty')) {
      context.handle(
        _qtyMeta,
        qty.isAcceptableOrUnknown(data['qty']!, _qtyMeta),
      );
    } else if (isInserting) {
      context.missing(_qtyMeta);
    }
    if (data.containsKey('price')) {
      context.handle(
        _priceMeta,
        price.isAcceptableOrUnknown(data['price']!, _priceMeta),
      );
    } else if (isInserting) {
      context.missing(_priceMeta);
    }
    if (data.containsKey('cost_at_sale')) {
      context.handle(
        _costAtSaleMeta,
        costAtSale.isAcceptableOrUnknown(
          data['cost_at_sale']!,
          _costAtSaleMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  QuoteItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QuoteItemRow(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}row_id'],
      )!,
      quoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quote_id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      qty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}qty'],
      )!,
      price: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}price'],
      )!,
      costAtSale: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost_at_sale'],
      ),
    );
  }

  @override
  $QuoteItemsTable createAlias(String alias) {
    return $QuoteItemsTable(attachedDatabase, alias);
  }
}

class QuoteItemRow extends DataClass implements Insertable<QuoteItemRow> {
  final int rowId;
  final String quoteId;
  final String? productId;
  final String name;
  final int qty;
  final double price;
  final double? costAtSale;
  const QuoteItemRow({
    required this.rowId,
    required this.quoteId,
    this.productId,
    required this.name,
    required this.qty,
    required this.price,
    this.costAtSale,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<int>(rowId);
    map['quote_id'] = Variable<String>(quoteId);
    if (!nullToAbsent || productId != null) {
      map['product_id'] = Variable<String>(productId);
    }
    map['name'] = Variable<String>(name);
    map['qty'] = Variable<int>(qty);
    map['price'] = Variable<double>(price);
    if (!nullToAbsent || costAtSale != null) {
      map['cost_at_sale'] = Variable<double>(costAtSale);
    }
    return map;
  }

  QuoteItemsCompanion toCompanion(bool nullToAbsent) {
    return QuoteItemsCompanion(
      rowId: Value(rowId),
      quoteId: Value(quoteId),
      productId: productId == null && nullToAbsent
          ? const Value.absent()
          : Value(productId),
      name: Value(name),
      qty: Value(qty),
      price: Value(price),
      costAtSale: costAtSale == null && nullToAbsent
          ? const Value.absent()
          : Value(costAtSale),
    );
  }

  factory QuoteItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QuoteItemRow(
      rowId: serializer.fromJson<int>(json['rowId']),
      quoteId: serializer.fromJson<String>(json['quoteId']),
      productId: serializer.fromJson<String?>(json['productId']),
      name: serializer.fromJson<String>(json['name']),
      qty: serializer.fromJson<int>(json['qty']),
      price: serializer.fromJson<double>(json['price']),
      costAtSale: serializer.fromJson<double?>(json['costAtSale']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<int>(rowId),
      'quoteId': serializer.toJson<String>(quoteId),
      'productId': serializer.toJson<String?>(productId),
      'name': serializer.toJson<String>(name),
      'qty': serializer.toJson<int>(qty),
      'price': serializer.toJson<double>(price),
      'costAtSale': serializer.toJson<double?>(costAtSale),
    };
  }

  QuoteItemRow copyWith({
    int? rowId,
    String? quoteId,
    Value<String?> productId = const Value.absent(),
    String? name,
    int? qty,
    double? price,
    Value<double?> costAtSale = const Value.absent(),
  }) => QuoteItemRow(
    rowId: rowId ?? this.rowId,
    quoteId: quoteId ?? this.quoteId,
    productId: productId.present ? productId.value : this.productId,
    name: name ?? this.name,
    qty: qty ?? this.qty,
    price: price ?? this.price,
    costAtSale: costAtSale.present ? costAtSale.value : this.costAtSale,
  );
  QuoteItemRow copyWithCompanion(QuoteItemsCompanion data) {
    return QuoteItemRow(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      quoteId: data.quoteId.present ? data.quoteId.value : this.quoteId,
      productId: data.productId.present ? data.productId.value : this.productId,
      name: data.name.present ? data.name.value : this.name,
      qty: data.qty.present ? data.qty.value : this.qty,
      price: data.price.present ? data.price.value : this.price,
      costAtSale: data.costAtSale.present
          ? data.costAtSale.value
          : this.costAtSale,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QuoteItemRow(')
          ..write('rowId: $rowId, ')
          ..write('quoteId: $quoteId, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('costAtSale: $costAtSale')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(rowId, quoteId, productId, name, qty, price, costAtSale);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QuoteItemRow &&
          other.rowId == this.rowId &&
          other.quoteId == this.quoteId &&
          other.productId == this.productId &&
          other.name == this.name &&
          other.qty == this.qty &&
          other.price == this.price &&
          other.costAtSale == this.costAtSale);
}

class QuoteItemsCompanion extends UpdateCompanion<QuoteItemRow> {
  final Value<int> rowId;
  final Value<String> quoteId;
  final Value<String?> productId;
  final Value<String> name;
  final Value<int> qty;
  final Value<double> price;
  final Value<double?> costAtSale;
  const QuoteItemsCompanion({
    this.rowId = const Value.absent(),
    this.quoteId = const Value.absent(),
    this.productId = const Value.absent(),
    this.name = const Value.absent(),
    this.qty = const Value.absent(),
    this.price = const Value.absent(),
    this.costAtSale = const Value.absent(),
  });
  QuoteItemsCompanion.insert({
    this.rowId = const Value.absent(),
    required String quoteId,
    this.productId = const Value.absent(),
    required String name,
    required int qty,
    required double price,
    this.costAtSale = const Value.absent(),
  }) : quoteId = Value(quoteId),
       name = Value(name),
       qty = Value(qty),
       price = Value(price);
  static Insertable<QuoteItemRow> custom({
    Expression<int>? rowId,
    Expression<String>? quoteId,
    Expression<String>? productId,
    Expression<String>? name,
    Expression<int>? qty,
    Expression<double>? price,
    Expression<double>? costAtSale,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (quoteId != null) 'quote_id': quoteId,
      if (productId != null) 'product_id': productId,
      if (name != null) 'name': name,
      if (qty != null) 'qty': qty,
      if (price != null) 'price': price,
      if (costAtSale != null) 'cost_at_sale': costAtSale,
    });
  }

  QuoteItemsCompanion copyWith({
    Value<int>? rowId,
    Value<String>? quoteId,
    Value<String?>? productId,
    Value<String>? name,
    Value<int>? qty,
    Value<double>? price,
    Value<double?>? costAtSale,
  }) {
    return QuoteItemsCompanion(
      rowId: rowId ?? this.rowId,
      quoteId: quoteId ?? this.quoteId,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      qty: qty ?? this.qty,
      price: price ?? this.price,
      costAtSale: costAtSale ?? this.costAtSale,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<int>(rowId.value);
    }
    if (quoteId.present) {
      map['quote_id'] = Variable<String>(quoteId.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (qty.present) {
      map['qty'] = Variable<int>(qty.value);
    }
    if (price.present) {
      map['price'] = Variable<double>(price.value);
    }
    if (costAtSale.present) {
      map['cost_at_sale'] = Variable<double>(costAtSale.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuoteItemsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('quoteId: $quoteId, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('qty: $qty, ')
          ..write('price: $price, ')
          ..write('costAtSale: $costAtSale')
          ..write(')'))
        .toString();
  }
}

class $MovementsTable extends Movements
    with TableInfo<$MovementsTable, MovementRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MovementsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _partNoMeta = const VerificationMeta('partNo');
  @override
  late final GeneratedColumn<String> partNo = GeneratedColumn<String>(
    'part_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deltaMeta = const VerificationMeta('delta');
  @override
  late final GeneratedColumn<int> delta = GeneratedColumn<int>(
    'delta',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stockAfterMeta = const VerificationMeta(
    'stockAfter',
  );
  @override
  late final GeneratedColumn<int> stockAfter = GeneratedColumn<int>(
    'stock_after',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productId,
    partNo,
    name,
    delta,
    type,
    note,
    stockAfter,
    date,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'movements';
  @override
  VerificationContext validateIntegrity(
    Insertable<MovementRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('part_no')) {
      context.handle(
        _partNoMeta,
        partNo.isAcceptableOrUnknown(data['part_no']!, _partNoMeta),
      );
    } else if (isInserting) {
      context.missing(_partNoMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('delta')) {
      context.handle(
        _deltaMeta,
        delta.isAcceptableOrUnknown(data['delta']!, _deltaMeta),
      );
    } else if (isInserting) {
      context.missing(_deltaMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('stock_after')) {
      context.handle(
        _stockAfterMeta,
        stockAfter.isAcceptableOrUnknown(data['stock_after']!, _stockAfterMeta),
      );
    } else if (isInserting) {
      context.missing(_stockAfterMeta);
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MovementRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MovementRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      partNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_no'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      delta: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delta'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      stockAfter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stock_after'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
    );
  }

  @override
  $MovementsTable createAlias(String alias) {
    return $MovementsTable(attachedDatabase, alias);
  }
}

class MovementRow extends DataClass implements Insertable<MovementRow> {
  final String id;
  final String productId;
  final String partNo;
  final String name;
  final int delta;
  final String type;
  final String? note;
  final int stockAfter;
  final DateTime date;
  const MovementRow({
    required this.id,
    required this.productId,
    required this.partNo,
    required this.name,
    required this.delta,
    required this.type,
    this.note,
    required this.stockAfter,
    required this.date,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['product_id'] = Variable<String>(productId);
    map['part_no'] = Variable<String>(partNo);
    map['name'] = Variable<String>(name);
    map['delta'] = Variable<int>(delta);
    map['type'] = Variable<String>(type);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['stock_after'] = Variable<int>(stockAfter);
    map['date'] = Variable<DateTime>(date);
    return map;
  }

  MovementsCompanion toCompanion(bool nullToAbsent) {
    return MovementsCompanion(
      id: Value(id),
      productId: Value(productId),
      partNo: Value(partNo),
      name: Value(name),
      delta: Value(delta),
      type: Value(type),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      stockAfter: Value(stockAfter),
      date: Value(date),
    );
  }

  factory MovementRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MovementRow(
      id: serializer.fromJson<String>(json['id']),
      productId: serializer.fromJson<String>(json['productId']),
      partNo: serializer.fromJson<String>(json['partNo']),
      name: serializer.fromJson<String>(json['name']),
      delta: serializer.fromJson<int>(json['delta']),
      type: serializer.fromJson<String>(json['type']),
      note: serializer.fromJson<String?>(json['note']),
      stockAfter: serializer.fromJson<int>(json['stockAfter']),
      date: serializer.fromJson<DateTime>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productId': serializer.toJson<String>(productId),
      'partNo': serializer.toJson<String>(partNo),
      'name': serializer.toJson<String>(name),
      'delta': serializer.toJson<int>(delta),
      'type': serializer.toJson<String>(type),
      'note': serializer.toJson<String?>(note),
      'stockAfter': serializer.toJson<int>(stockAfter),
      'date': serializer.toJson<DateTime>(date),
    };
  }

  MovementRow copyWith({
    String? id,
    String? productId,
    String? partNo,
    String? name,
    int? delta,
    String? type,
    Value<String?> note = const Value.absent(),
    int? stockAfter,
    DateTime? date,
  }) => MovementRow(
    id: id ?? this.id,
    productId: productId ?? this.productId,
    partNo: partNo ?? this.partNo,
    name: name ?? this.name,
    delta: delta ?? this.delta,
    type: type ?? this.type,
    note: note.present ? note.value : this.note,
    stockAfter: stockAfter ?? this.stockAfter,
    date: date ?? this.date,
  );
  MovementRow copyWithCompanion(MovementsCompanion data) {
    return MovementRow(
      id: data.id.present ? data.id.value : this.id,
      productId: data.productId.present ? data.productId.value : this.productId,
      partNo: data.partNo.present ? data.partNo.value : this.partNo,
      name: data.name.present ? data.name.value : this.name,
      delta: data.delta.present ? data.delta.value : this.delta,
      type: data.type.present ? data.type.value : this.type,
      note: data.note.present ? data.note.value : this.note,
      stockAfter: data.stockAfter.present
          ? data.stockAfter.value
          : this.stockAfter,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MovementRow(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('delta: $delta, ')
          ..write('type: $type, ')
          ..write('note: $note, ')
          ..write('stockAfter: $stockAfter, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productId,
    partNo,
    name,
    delta,
    type,
    note,
    stockAfter,
    date,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MovementRow &&
          other.id == this.id &&
          other.productId == this.productId &&
          other.partNo == this.partNo &&
          other.name == this.name &&
          other.delta == this.delta &&
          other.type == this.type &&
          other.note == this.note &&
          other.stockAfter == this.stockAfter &&
          other.date == this.date);
}

class MovementsCompanion extends UpdateCompanion<MovementRow> {
  final Value<String> id;
  final Value<String> productId;
  final Value<String> partNo;
  final Value<String> name;
  final Value<int> delta;
  final Value<String> type;
  final Value<String?> note;
  final Value<int> stockAfter;
  final Value<DateTime> date;
  final Value<int> rowid;
  const MovementsCompanion({
    this.id = const Value.absent(),
    this.productId = const Value.absent(),
    this.partNo = const Value.absent(),
    this.name = const Value.absent(),
    this.delta = const Value.absent(),
    this.type = const Value.absent(),
    this.note = const Value.absent(),
    this.stockAfter = const Value.absent(),
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MovementsCompanion.insert({
    required String id,
    required String productId,
    required String partNo,
    required String name,
    required int delta,
    required String type,
    this.note = const Value.absent(),
    required int stockAfter,
    required DateTime date,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productId = Value(productId),
       partNo = Value(partNo),
       name = Value(name),
       delta = Value(delta),
       type = Value(type),
       stockAfter = Value(stockAfter),
       date = Value(date);
  static Insertable<MovementRow> custom({
    Expression<String>? id,
    Expression<String>? productId,
    Expression<String>? partNo,
    Expression<String>? name,
    Expression<int>? delta,
    Expression<String>? type,
    Expression<String>? note,
    Expression<int>? stockAfter,
    Expression<DateTime>? date,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productId != null) 'product_id': productId,
      if (partNo != null) 'part_no': partNo,
      if (name != null) 'name': name,
      if (delta != null) 'delta': delta,
      if (type != null) 'type': type,
      if (note != null) 'note': note,
      if (stockAfter != null) 'stock_after': stockAfter,
      if (date != null) 'date': date,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MovementsCompanion copyWith({
    Value<String>? id,
    Value<String>? productId,
    Value<String>? partNo,
    Value<String>? name,
    Value<int>? delta,
    Value<String>? type,
    Value<String?>? note,
    Value<int>? stockAfter,
    Value<DateTime>? date,
    Value<int>? rowid,
  }) {
    return MovementsCompanion(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      partNo: partNo ?? this.partNo,
      name: name ?? this.name,
      delta: delta ?? this.delta,
      type: type ?? this.type,
      note: note ?? this.note,
      stockAfter: stockAfter ?? this.stockAfter,
      date: date ?? this.date,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (partNo.present) {
      map['part_no'] = Variable<String>(partNo.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (delta.present) {
      map['delta'] = Variable<int>(delta.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (stockAfter.present) {
      map['stock_after'] = Variable<int>(stockAfter.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MovementsCompanion(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('partNo: $partNo, ')
          ..write('name: $name, ')
          ..write('delta: $delta, ')
          ..write('type: $type, ')
          ..write('note: $note, ')
          ..write('stockAfter: $stockAfter, ')
          ..write('date: $date, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SuppliersTable extends Suppliers
    with TableInfo<$SuppliersTable, SupplierRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SuppliersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productIdMeta = const VerificationMeta(
    'productId',
  );
  @override
  late final GeneratedColumn<String> productId = GeneratedColumn<String>(
    'product_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unitCostMeta = const VerificationMeta(
    'unitCost',
  );
  @override
  late final GeneratedColumn<double> unitCost = GeneratedColumn<double>(
    'unit_cost',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _freightMeta = const VerificationMeta(
    'freight',
  );
  @override
  late final GeneratedColumn<double> freight = GeneratedColumn<double>(
    'freight',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productId,
    name,
    unitCost,
    freight,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'suppliers';
  @override
  VerificationContext validateIntegrity(
    Insertable<SupplierRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('product_id')) {
      context.handle(
        _productIdMeta,
        productId.isAcceptableOrUnknown(data['product_id']!, _productIdMeta),
      );
    } else if (isInserting) {
      context.missing(_productIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('unit_cost')) {
      context.handle(
        _unitCostMeta,
        unitCost.isAcceptableOrUnknown(data['unit_cost']!, _unitCostMeta),
      );
    } else if (isInserting) {
      context.missing(_unitCostMeta);
    }
    if (data.containsKey('freight')) {
      context.handle(
        _freightMeta,
        freight.isAcceptableOrUnknown(data['freight']!, _freightMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SupplierRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SupplierRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}product_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      unitCost: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}unit_cost'],
      )!,
      freight: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}freight'],
      )!,
    );
  }

  @override
  $SuppliersTable createAlias(String alias) {
    return $SuppliersTable(attachedDatabase, alias);
  }
}

class SupplierRow extends DataClass implements Insertable<SupplierRow> {
  final String id;
  final String productId;
  final String name;
  final double unitCost;
  final double freight;
  const SupplierRow({
    required this.id,
    required this.productId,
    required this.name,
    required this.unitCost,
    required this.freight,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['product_id'] = Variable<String>(productId);
    map['name'] = Variable<String>(name);
    map['unit_cost'] = Variable<double>(unitCost);
    map['freight'] = Variable<double>(freight);
    return map;
  }

  SuppliersCompanion toCompanion(bool nullToAbsent) {
    return SuppliersCompanion(
      id: Value(id),
      productId: Value(productId),
      name: Value(name),
      unitCost: Value(unitCost),
      freight: Value(freight),
    );
  }

  factory SupplierRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SupplierRow(
      id: serializer.fromJson<String>(json['id']),
      productId: serializer.fromJson<String>(json['productId']),
      name: serializer.fromJson<String>(json['name']),
      unitCost: serializer.fromJson<double>(json['unitCost']),
      freight: serializer.fromJson<double>(json['freight']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productId': serializer.toJson<String>(productId),
      'name': serializer.toJson<String>(name),
      'unitCost': serializer.toJson<double>(unitCost),
      'freight': serializer.toJson<double>(freight),
    };
  }

  SupplierRow copyWith({
    String? id,
    String? productId,
    String? name,
    double? unitCost,
    double? freight,
  }) => SupplierRow(
    id: id ?? this.id,
    productId: productId ?? this.productId,
    name: name ?? this.name,
    unitCost: unitCost ?? this.unitCost,
    freight: freight ?? this.freight,
  );
  SupplierRow copyWithCompanion(SuppliersCompanion data) {
    return SupplierRow(
      id: data.id.present ? data.id.value : this.id,
      productId: data.productId.present ? data.productId.value : this.productId,
      name: data.name.present ? data.name.value : this.name,
      unitCost: data.unitCost.present ? data.unitCost.value : this.unitCost,
      freight: data.freight.present ? data.freight.value : this.freight,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SupplierRow(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('unitCost: $unitCost, ')
          ..write('freight: $freight')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, productId, name, unitCost, freight);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SupplierRow &&
          other.id == this.id &&
          other.productId == this.productId &&
          other.name == this.name &&
          other.unitCost == this.unitCost &&
          other.freight == this.freight);
}

class SuppliersCompanion extends UpdateCompanion<SupplierRow> {
  final Value<String> id;
  final Value<String> productId;
  final Value<String> name;
  final Value<double> unitCost;
  final Value<double> freight;
  final Value<int> rowid;
  const SuppliersCompanion({
    this.id = const Value.absent(),
    this.productId = const Value.absent(),
    this.name = const Value.absent(),
    this.unitCost = const Value.absent(),
    this.freight = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SuppliersCompanion.insert({
    required String id,
    required String productId,
    required String name,
    required double unitCost,
    this.freight = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productId = Value(productId),
       name = Value(name),
       unitCost = Value(unitCost);
  static Insertable<SupplierRow> custom({
    Expression<String>? id,
    Expression<String>? productId,
    Expression<String>? name,
    Expression<double>? unitCost,
    Expression<double>? freight,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productId != null) 'product_id': productId,
      if (name != null) 'name': name,
      if (unitCost != null) 'unit_cost': unitCost,
      if (freight != null) 'freight': freight,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SuppliersCompanion copyWith({
    Value<String>? id,
    Value<String>? productId,
    Value<String>? name,
    Value<double>? unitCost,
    Value<double>? freight,
    Value<int>? rowid,
  }) {
    return SuppliersCompanion(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      unitCost: unitCost ?? this.unitCost,
      freight: freight ?? this.freight,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productId.present) {
      map['product_id'] = Variable<String>(productId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (unitCost.present) {
      map['unit_cost'] = Variable<double>(unitCost.value);
    }
    if (freight.present) {
      map['freight'] = Variable<double>(freight.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SuppliersCompanion(')
          ..write('id: $id, ')
          ..write('productId: $productId, ')
          ..write('name: $name, ')
          ..write('unitCost: $unitCost, ')
          ..write('freight: $freight, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CreditPaymentsTable extends CreditPayments
    with TableInfo<$CreditPaymentsTable, CreditPaymentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CreditPaymentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiptNoMeta = const VerificationMeta(
    'receiptNo',
  );
  @override
  late final GeneratedColumn<String> receiptNo = GeneratedColumn<String>(
    'receipt_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mechanicIdMeta = const VerificationMeta(
    'mechanicId',
  );
  @override
  late final GeneratedColumn<String> mechanicId = GeneratedColumn<String>(
    'mechanic_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
    'amount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    receiptNo,
    mechanicId,
    amount,
    date,
    note,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'credit_payments';
  @override
  VerificationContext validateIntegrity(
    Insertable<CreditPaymentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('receipt_no')) {
      context.handle(
        _receiptNoMeta,
        receiptNo.isAcceptableOrUnknown(data['receipt_no']!, _receiptNoMeta),
      );
    } else if (isInserting) {
      context.missing(_receiptNoMeta);
    }
    if (data.containsKey('mechanic_id')) {
      context.handle(
        _mechanicIdMeta,
        mechanicId.isAcceptableOrUnknown(data['mechanic_id']!, _mechanicIdMeta),
      );
    } else if (isInserting) {
      context.missing(_mechanicIdMeta);
    }
    if (data.containsKey('amount')) {
      context.handle(
        _amountMeta,
        amount.isAcceptableOrUnknown(data['amount']!, _amountMeta),
      );
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CreditPaymentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CreditPaymentRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      receiptNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_no'],
      )!,
      mechanicId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mechanic_id'],
      )!,
      amount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}amount'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
    );
  }

  @override
  $CreditPaymentsTable createAlias(String alias) {
    return $CreditPaymentsTable(attachedDatabase, alias);
  }
}

class CreditPaymentRow extends DataClass
    implements Insertable<CreditPaymentRow> {
  final String id;
  final String receiptNo;
  final String mechanicId;
  final double amount;
  final DateTime date;
  final String? note;
  const CreditPaymentRow({
    required this.id,
    required this.receiptNo,
    required this.mechanicId,
    required this.amount,
    required this.date,
    this.note,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['receipt_no'] = Variable<String>(receiptNo);
    map['mechanic_id'] = Variable<String>(mechanicId);
    map['amount'] = Variable<double>(amount);
    map['date'] = Variable<DateTime>(date);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    return map;
  }

  CreditPaymentsCompanion toCompanion(bool nullToAbsent) {
    return CreditPaymentsCompanion(
      id: Value(id),
      receiptNo: Value(receiptNo),
      mechanicId: Value(mechanicId),
      amount: Value(amount),
      date: Value(date),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
    );
  }

  factory CreditPaymentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CreditPaymentRow(
      id: serializer.fromJson<String>(json['id']),
      receiptNo: serializer.fromJson<String>(json['receiptNo']),
      mechanicId: serializer.fromJson<String>(json['mechanicId']),
      amount: serializer.fromJson<double>(json['amount']),
      date: serializer.fromJson<DateTime>(json['date']),
      note: serializer.fromJson<String?>(json['note']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'receiptNo': serializer.toJson<String>(receiptNo),
      'mechanicId': serializer.toJson<String>(mechanicId),
      'amount': serializer.toJson<double>(amount),
      'date': serializer.toJson<DateTime>(date),
      'note': serializer.toJson<String?>(note),
    };
  }

  CreditPaymentRow copyWith({
    String? id,
    String? receiptNo,
    String? mechanicId,
    double? amount,
    DateTime? date,
    Value<String?> note = const Value.absent(),
  }) => CreditPaymentRow(
    id: id ?? this.id,
    receiptNo: receiptNo ?? this.receiptNo,
    mechanicId: mechanicId ?? this.mechanicId,
    amount: amount ?? this.amount,
    date: date ?? this.date,
    note: note.present ? note.value : this.note,
  );
  CreditPaymentRow copyWithCompanion(CreditPaymentsCompanion data) {
    return CreditPaymentRow(
      id: data.id.present ? data.id.value : this.id,
      receiptNo: data.receiptNo.present ? data.receiptNo.value : this.receiptNo,
      mechanicId: data.mechanicId.present
          ? data.mechanicId.value
          : this.mechanicId,
      amount: data.amount.present ? data.amount.value : this.amount,
      date: data.date.present ? data.date.value : this.date,
      note: data.note.present ? data.note.value : this.note,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CreditPaymentRow(')
          ..write('id: $id, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('amount: $amount, ')
          ..write('date: $date, ')
          ..write('note: $note')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, receiptNo, mechanicId, amount, date, note);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CreditPaymentRow &&
          other.id == this.id &&
          other.receiptNo == this.receiptNo &&
          other.mechanicId == this.mechanicId &&
          other.amount == this.amount &&
          other.date == this.date &&
          other.note == this.note);
}

class CreditPaymentsCompanion extends UpdateCompanion<CreditPaymentRow> {
  final Value<String> id;
  final Value<String> receiptNo;
  final Value<String> mechanicId;
  final Value<double> amount;
  final Value<DateTime> date;
  final Value<String?> note;
  final Value<int> rowid;
  const CreditPaymentsCompanion({
    this.id = const Value.absent(),
    this.receiptNo = const Value.absent(),
    this.mechanicId = const Value.absent(),
    this.amount = const Value.absent(),
    this.date = const Value.absent(),
    this.note = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CreditPaymentsCompanion.insert({
    required String id,
    required String receiptNo,
    required String mechanicId,
    required double amount,
    required DateTime date,
    this.note = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       receiptNo = Value(receiptNo),
       mechanicId = Value(mechanicId),
       amount = Value(amount),
       date = Value(date);
  static Insertable<CreditPaymentRow> custom({
    Expression<String>? id,
    Expression<String>? receiptNo,
    Expression<String>? mechanicId,
    Expression<double>? amount,
    Expression<DateTime>? date,
    Expression<String>? note,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (receiptNo != null) 'receipt_no': receiptNo,
      if (mechanicId != null) 'mechanic_id': mechanicId,
      if (amount != null) 'amount': amount,
      if (date != null) 'date': date,
      if (note != null) 'note': note,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CreditPaymentsCompanion copyWith({
    Value<String>? id,
    Value<String>? receiptNo,
    Value<String>? mechanicId,
    Value<double>? amount,
    Value<DateTime>? date,
    Value<String?>? note,
    Value<int>? rowid,
  }) {
    return CreditPaymentsCompanion(
      id: id ?? this.id,
      receiptNo: receiptNo ?? this.receiptNo,
      mechanicId: mechanicId ?? this.mechanicId,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      note: note ?? this.note,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (receiptNo.present) {
      map['receipt_no'] = Variable<String>(receiptNo.value);
    }
    if (mechanicId.present) {
      map['mechanic_id'] = Variable<String>(mechanicId.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CreditPaymentsCompanion(')
          ..write('id: $id, ')
          ..write('receiptNo: $receiptNo, ')
          ..write('mechanicId: $mechanicId, ')
          ..write('amount: $amount, ')
          ..write('date: $date, ')
          ..write('note: $note, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ShiftsTable extends Shifts with TableInfo<$ShiftsTable, ShiftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ShiftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dateStrMeta = const VerificationMeta(
    'dateStr',
  );
  @override
  late final GeneratedColumn<String> dateStr = GeneratedColumn<String>(
    'date_str',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startingCashMeta = const VerificationMeta(
    'startingCash',
  );
  @override
  late final GeneratedColumn<double> startingCash = GeneratedColumn<double>(
    'starting_cash',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _openedAtMeta = const VerificationMeta(
    'openedAt',
  );
  @override
  late final GeneratedColumn<DateTime> openedAt = GeneratedColumn<DateTime>(
    'opened_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _closedAtMeta = const VerificationMeta(
    'closedAt',
  );
  @override
  late final GeneratedColumn<DateTime> closedAt = GeneratedColumn<DateTime>(
    'closed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _physicalCashMeta = const VerificationMeta(
    'physicalCash',
  );
  @override
  late final GeneratedColumn<double> physicalCash = GeneratedColumn<double>(
    'physical_cash',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _autoArchivedMeta = const VerificationMeta(
    'autoArchived',
  );
  @override
  late final GeneratedColumn<bool> autoArchived = GeneratedColumn<bool>(
    'auto_archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_archived" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _archivedAtMeta = const VerificationMeta(
    'archivedAt',
  );
  @override
  late final GeneratedColumn<DateTime> archivedAt = GeneratedColumn<DateTime>(
    'archived_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    dateStr,
    startingCash,
    openedAt,
    closedAt,
    physicalCash,
    isActive,
    autoArchived,
    archivedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shifts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ShiftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('date_str')) {
      context.handle(
        _dateStrMeta,
        dateStr.isAcceptableOrUnknown(data['date_str']!, _dateStrMeta),
      );
    } else if (isInserting) {
      context.missing(_dateStrMeta);
    }
    if (data.containsKey('starting_cash')) {
      context.handle(
        _startingCashMeta,
        startingCash.isAcceptableOrUnknown(
          data['starting_cash']!,
          _startingCashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startingCashMeta);
    }
    if (data.containsKey('opened_at')) {
      context.handle(
        _openedAtMeta,
        openedAt.isAcceptableOrUnknown(data['opened_at']!, _openedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_openedAtMeta);
    }
    if (data.containsKey('closed_at')) {
      context.handle(
        _closedAtMeta,
        closedAt.isAcceptableOrUnknown(data['closed_at']!, _closedAtMeta),
      );
    }
    if (data.containsKey('physical_cash')) {
      context.handle(
        _physicalCashMeta,
        physicalCash.isAcceptableOrUnknown(
          data['physical_cash']!,
          _physicalCashMeta,
        ),
      );
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    if (data.containsKey('auto_archived')) {
      context.handle(
        _autoArchivedMeta,
        autoArchived.isAcceptableOrUnknown(
          data['auto_archived']!,
          _autoArchivedMeta,
        ),
      );
    }
    if (data.containsKey('archived_at')) {
      context.handle(
        _archivedAtMeta,
        archivedAt.isAcceptableOrUnknown(data['archived_at']!, _archivedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ShiftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ShiftRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      dateStr: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}date_str'],
      )!,
      startingCash: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}starting_cash'],
      )!,
      openedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}opened_at'],
      )!,
      closedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}closed_at'],
      ),
      physicalCash: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}physical_cash'],
      ),
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
      autoArchived: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_archived'],
      )!,
      archivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}archived_at'],
      ),
    );
  }

  @override
  $ShiftsTable createAlias(String alias) {
    return $ShiftsTable(attachedDatabase, alias);
  }
}

class ShiftRow extends DataClass implements Insertable<ShiftRow> {
  /// Schema v3 (ADR-0010): TEXT, not an autoincrement integer — the server
  /// issues shift ids (TEXT + `device_id`) and an integer column cannot hold
  /// one. Offline-issued ids come from `newId('sh')`.
  final String id;
  final String dateStr;
  final double startingCash;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double? physicalCash;
  final bool isActive;
  final bool autoArchived;
  final DateTime? archivedAt;
  const ShiftRow({
    required this.id,
    required this.dateStr,
    required this.startingCash,
    required this.openedAt,
    this.closedAt,
    this.physicalCash,
    required this.isActive,
    required this.autoArchived,
    this.archivedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['date_str'] = Variable<String>(dateStr);
    map['starting_cash'] = Variable<double>(startingCash);
    map['opened_at'] = Variable<DateTime>(openedAt);
    if (!nullToAbsent || closedAt != null) {
      map['closed_at'] = Variable<DateTime>(closedAt);
    }
    if (!nullToAbsent || physicalCash != null) {
      map['physical_cash'] = Variable<double>(physicalCash);
    }
    map['is_active'] = Variable<bool>(isActive);
    map['auto_archived'] = Variable<bool>(autoArchived);
    if (!nullToAbsent || archivedAt != null) {
      map['archived_at'] = Variable<DateTime>(archivedAt);
    }
    return map;
  }

  ShiftsCompanion toCompanion(bool nullToAbsent) {
    return ShiftsCompanion(
      id: Value(id),
      dateStr: Value(dateStr),
      startingCash: Value(startingCash),
      openedAt: Value(openedAt),
      closedAt: closedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(closedAt),
      physicalCash: physicalCash == null && nullToAbsent
          ? const Value.absent()
          : Value(physicalCash),
      isActive: Value(isActive),
      autoArchived: Value(autoArchived),
      archivedAt: archivedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(archivedAt),
    );
  }

  factory ShiftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ShiftRow(
      id: serializer.fromJson<String>(json['id']),
      dateStr: serializer.fromJson<String>(json['dateStr']),
      startingCash: serializer.fromJson<double>(json['startingCash']),
      openedAt: serializer.fromJson<DateTime>(json['openedAt']),
      closedAt: serializer.fromJson<DateTime?>(json['closedAt']),
      physicalCash: serializer.fromJson<double?>(json['physicalCash']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      autoArchived: serializer.fromJson<bool>(json['autoArchived']),
      archivedAt: serializer.fromJson<DateTime?>(json['archivedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'dateStr': serializer.toJson<String>(dateStr),
      'startingCash': serializer.toJson<double>(startingCash),
      'openedAt': serializer.toJson<DateTime>(openedAt),
      'closedAt': serializer.toJson<DateTime?>(closedAt),
      'physicalCash': serializer.toJson<double?>(physicalCash),
      'isActive': serializer.toJson<bool>(isActive),
      'autoArchived': serializer.toJson<bool>(autoArchived),
      'archivedAt': serializer.toJson<DateTime?>(archivedAt),
    };
  }

  ShiftRow copyWith({
    String? id,
    String? dateStr,
    double? startingCash,
    DateTime? openedAt,
    Value<DateTime?> closedAt = const Value.absent(),
    Value<double?> physicalCash = const Value.absent(),
    bool? isActive,
    bool? autoArchived,
    Value<DateTime?> archivedAt = const Value.absent(),
  }) => ShiftRow(
    id: id ?? this.id,
    dateStr: dateStr ?? this.dateStr,
    startingCash: startingCash ?? this.startingCash,
    openedAt: openedAt ?? this.openedAt,
    closedAt: closedAt.present ? closedAt.value : this.closedAt,
    physicalCash: physicalCash.present ? physicalCash.value : this.physicalCash,
    isActive: isActive ?? this.isActive,
    autoArchived: autoArchived ?? this.autoArchived,
    archivedAt: archivedAt.present ? archivedAt.value : this.archivedAt,
  );
  ShiftRow copyWithCompanion(ShiftsCompanion data) {
    return ShiftRow(
      id: data.id.present ? data.id.value : this.id,
      dateStr: data.dateStr.present ? data.dateStr.value : this.dateStr,
      startingCash: data.startingCash.present
          ? data.startingCash.value
          : this.startingCash,
      openedAt: data.openedAt.present ? data.openedAt.value : this.openedAt,
      closedAt: data.closedAt.present ? data.closedAt.value : this.closedAt,
      physicalCash: data.physicalCash.present
          ? data.physicalCash.value
          : this.physicalCash,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      autoArchived: data.autoArchived.present
          ? data.autoArchived.value
          : this.autoArchived,
      archivedAt: data.archivedAt.present
          ? data.archivedAt.value
          : this.archivedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ShiftRow(')
          ..write('id: $id, ')
          ..write('dateStr: $dateStr, ')
          ..write('startingCash: $startingCash, ')
          ..write('openedAt: $openedAt, ')
          ..write('closedAt: $closedAt, ')
          ..write('physicalCash: $physicalCash, ')
          ..write('isActive: $isActive, ')
          ..write('autoArchived: $autoArchived, ')
          ..write('archivedAt: $archivedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    dateStr,
    startingCash,
    openedAt,
    closedAt,
    physicalCash,
    isActive,
    autoArchived,
    archivedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShiftRow &&
          other.id == this.id &&
          other.dateStr == this.dateStr &&
          other.startingCash == this.startingCash &&
          other.openedAt == this.openedAt &&
          other.closedAt == this.closedAt &&
          other.physicalCash == this.physicalCash &&
          other.isActive == this.isActive &&
          other.autoArchived == this.autoArchived &&
          other.archivedAt == this.archivedAt);
}

class ShiftsCompanion extends UpdateCompanion<ShiftRow> {
  final Value<String> id;
  final Value<String> dateStr;
  final Value<double> startingCash;
  final Value<DateTime> openedAt;
  final Value<DateTime?> closedAt;
  final Value<double?> physicalCash;
  final Value<bool> isActive;
  final Value<bool> autoArchived;
  final Value<DateTime?> archivedAt;
  final Value<int> rowid;
  const ShiftsCompanion({
    this.id = const Value.absent(),
    this.dateStr = const Value.absent(),
    this.startingCash = const Value.absent(),
    this.openedAt = const Value.absent(),
    this.closedAt = const Value.absent(),
    this.physicalCash = const Value.absent(),
    this.isActive = const Value.absent(),
    this.autoArchived = const Value.absent(),
    this.archivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ShiftsCompanion.insert({
    required String id,
    required String dateStr,
    required double startingCash,
    required DateTime openedAt,
    this.closedAt = const Value.absent(),
    this.physicalCash = const Value.absent(),
    this.isActive = const Value.absent(),
    this.autoArchived = const Value.absent(),
    this.archivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       dateStr = Value(dateStr),
       startingCash = Value(startingCash),
       openedAt = Value(openedAt);
  static Insertable<ShiftRow> custom({
    Expression<String>? id,
    Expression<String>? dateStr,
    Expression<double>? startingCash,
    Expression<DateTime>? openedAt,
    Expression<DateTime>? closedAt,
    Expression<double>? physicalCash,
    Expression<bool>? isActive,
    Expression<bool>? autoArchived,
    Expression<DateTime>? archivedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dateStr != null) 'date_str': dateStr,
      if (startingCash != null) 'starting_cash': startingCash,
      if (openedAt != null) 'opened_at': openedAt,
      if (closedAt != null) 'closed_at': closedAt,
      if (physicalCash != null) 'physical_cash': physicalCash,
      if (isActive != null) 'is_active': isActive,
      if (autoArchived != null) 'auto_archived': autoArchived,
      if (archivedAt != null) 'archived_at': archivedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ShiftsCompanion copyWith({
    Value<String>? id,
    Value<String>? dateStr,
    Value<double>? startingCash,
    Value<DateTime>? openedAt,
    Value<DateTime?>? closedAt,
    Value<double?>? physicalCash,
    Value<bool>? isActive,
    Value<bool>? autoArchived,
    Value<DateTime?>? archivedAt,
    Value<int>? rowid,
  }) {
    return ShiftsCompanion(
      id: id ?? this.id,
      dateStr: dateStr ?? this.dateStr,
      startingCash: startingCash ?? this.startingCash,
      openedAt: openedAt ?? this.openedAt,
      closedAt: closedAt ?? this.closedAt,
      physicalCash: physicalCash ?? this.physicalCash,
      isActive: isActive ?? this.isActive,
      autoArchived: autoArchived ?? this.autoArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (dateStr.present) {
      map['date_str'] = Variable<String>(dateStr.value);
    }
    if (startingCash.present) {
      map['starting_cash'] = Variable<double>(startingCash.value);
    }
    if (openedAt.present) {
      map['opened_at'] = Variable<DateTime>(openedAt.value);
    }
    if (closedAt.present) {
      map['closed_at'] = Variable<DateTime>(closedAt.value);
    }
    if (physicalCash.present) {
      map['physical_cash'] = Variable<double>(physicalCash.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (autoArchived.present) {
      map['auto_archived'] = Variable<bool>(autoArchived.value);
    }
    if (archivedAt.present) {
      map['archived_at'] = Variable<DateTime>(archivedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ShiftsCompanion(')
          ..write('id: $id, ')
          ..write('dateStr: $dateStr, ')
          ..write('startingCash: $startingCash, ')
          ..write('openedAt: $openedAt, ')
          ..write('closedAt: $closedAt, ')
          ..write('physicalCash: $physicalCash, ')
          ..write('isActive: $isActive, ')
          ..write('autoArchived: $autoArchived, ')
          ..write('archivedAt: $archivedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DrawerEntriesTable extends DrawerEntries
    with TableInfo<$DrawerEntriesTable, DrawerEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DrawerEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _shiftIdMeta = const VerificationMeta(
    'shiftId',
  );
  @override
  late final GeneratedColumn<String> shiftId = GeneratedColumn<String>(
    'shift_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES shifts (id)',
    ),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
    'amount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    shiftId,
    type,
    amount,
    note,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drawer_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<DrawerEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('shift_id')) {
      context.handle(
        _shiftIdMeta,
        shiftId.isAcceptableOrUnknown(data['shift_id']!, _shiftIdMeta),
      );
    } else if (isInserting) {
      context.missing(_shiftIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('amount')) {
      context.handle(
        _amountMeta,
        amount.isAcceptableOrUnknown(data['amount']!, _amountMeta),
      );
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DrawerEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DrawerEntryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      shiftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shift_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      amount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}amount'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $DrawerEntriesTable createAlias(String alias) {
    return $DrawerEntriesTable(attachedDatabase, alias);
  }
}

class DrawerEntryRow extends DataClass implements Insertable<DrawerEntryRow> {
  final String id;
  final String shiftId;
  final String type;
  final double amount;
  final String? note;
  final DateTime createdAt;
  const DrawerEntryRow({
    required this.id,
    required this.shiftId,
    required this.type,
    required this.amount,
    this.note,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['shift_id'] = Variable<String>(shiftId);
    map['type'] = Variable<String>(type);
    map['amount'] = Variable<double>(amount);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  DrawerEntriesCompanion toCompanion(bool nullToAbsent) {
    return DrawerEntriesCompanion(
      id: Value(id),
      shiftId: Value(shiftId),
      type: Value(type),
      amount: Value(amount),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
    );
  }

  factory DrawerEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DrawerEntryRow(
      id: serializer.fromJson<String>(json['id']),
      shiftId: serializer.fromJson<String>(json['shiftId']),
      type: serializer.fromJson<String>(json['type']),
      amount: serializer.fromJson<double>(json['amount']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'shiftId': serializer.toJson<String>(shiftId),
      'type': serializer.toJson<String>(type),
      'amount': serializer.toJson<double>(amount),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  DrawerEntryRow copyWith({
    String? id,
    String? shiftId,
    String? type,
    double? amount,
    Value<String?> note = const Value.absent(),
    DateTime? createdAt,
  }) => DrawerEntryRow(
    id: id ?? this.id,
    shiftId: shiftId ?? this.shiftId,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    note: note.present ? note.value : this.note,
    createdAt: createdAt ?? this.createdAt,
  );
  DrawerEntryRow copyWithCompanion(DrawerEntriesCompanion data) {
    return DrawerEntryRow(
      id: data.id.present ? data.id.value : this.id,
      shiftId: data.shiftId.present ? data.shiftId.value : this.shiftId,
      type: data.type.present ? data.type.value : this.type,
      amount: data.amount.present ? data.amount.value : this.amount,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DrawerEntryRow(')
          ..write('id: $id, ')
          ..write('shiftId: $shiftId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, shiftId, type, amount, note, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DrawerEntryRow &&
          other.id == this.id &&
          other.shiftId == this.shiftId &&
          other.type == this.type &&
          other.amount == this.amount &&
          other.note == this.note &&
          other.createdAt == this.createdAt);
}

class DrawerEntriesCompanion extends UpdateCompanion<DrawerEntryRow> {
  final Value<String> id;
  final Value<String> shiftId;
  final Value<String> type;
  final Value<double> amount;
  final Value<String?> note;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const DrawerEntriesCompanion({
    this.id = const Value.absent(),
    this.shiftId = const Value.absent(),
    this.type = const Value.absent(),
    this.amount = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DrawerEntriesCompanion.insert({
    required String id,
    required String shiftId,
    required String type,
    required double amount,
    this.note = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       shiftId = Value(shiftId),
       type = Value(type),
       amount = Value(amount),
       createdAt = Value(createdAt);
  static Insertable<DrawerEntryRow> custom({
    Expression<String>? id,
    Expression<String>? shiftId,
    Expression<String>? type,
    Expression<double>? amount,
    Expression<String>? note,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (shiftId != null) 'shift_id': shiftId,
      if (type != null) 'type': type,
      if (amount != null) 'amount': amount,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DrawerEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? shiftId,
    Value<String>? type,
    Value<double>? amount,
    Value<String?>? note,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return DrawerEntriesCompanion(
      id: id ?? this.id,
      shiftId: shiftId ?? this.shiftId,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (shiftId.present) {
      map['shift_id'] = Variable<String>(shiftId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DrawerEntriesCompanion(')
          ..write('id: $id, ')
          ..write('shiftId: $shiftId, ')
          ..write('type: $type, ')
          ..write('amount: $amount, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ParkedSalesTable extends ParkedSales
    with TableInfo<$ParkedSalesTable, ParkedSaleRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ParkedSalesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parkedAtMeta = const VerificationMeta(
    'parkedAt',
  );
  @override
  late final GeneratedColumn<DateTime> parkedAt = GeneratedColumn<DateTime>(
    'parked_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, parkedAt, payload];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'parked_sales';
  @override
  VerificationContext validateIntegrity(
    Insertable<ParkedSaleRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('parked_at')) {
      context.handle(
        _parkedAtMeta,
        parkedAt.isAcceptableOrUnknown(data['parked_at']!, _parkedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_parkedAtMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ParkedSaleRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ParkedSaleRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      parkedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}parked_at'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
    );
  }

  @override
  $ParkedSalesTable createAlias(String alias) {
    return $ParkedSalesTable(attachedDatabase, alias);
  }
}

class ParkedSaleRow extends DataClass implements Insertable<ParkedSaleRow> {
  final String id;
  final DateTime parkedAt;
  final String payload;
  const ParkedSaleRow({
    required this.id,
    required this.parkedAt,
    required this.payload,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['parked_at'] = Variable<DateTime>(parkedAt);
    map['payload'] = Variable<String>(payload);
    return map;
  }

  ParkedSalesCompanion toCompanion(bool nullToAbsent) {
    return ParkedSalesCompanion(
      id: Value(id),
      parkedAt: Value(parkedAt),
      payload: Value(payload),
    );
  }

  factory ParkedSaleRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ParkedSaleRow(
      id: serializer.fromJson<String>(json['id']),
      parkedAt: serializer.fromJson<DateTime>(json['parkedAt']),
      payload: serializer.fromJson<String>(json['payload']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'parkedAt': serializer.toJson<DateTime>(parkedAt),
      'payload': serializer.toJson<String>(payload),
    };
  }

  ParkedSaleRow copyWith({String? id, DateTime? parkedAt, String? payload}) =>
      ParkedSaleRow(
        id: id ?? this.id,
        parkedAt: parkedAt ?? this.parkedAt,
        payload: payload ?? this.payload,
      );
  ParkedSaleRow copyWithCompanion(ParkedSalesCompanion data) {
    return ParkedSaleRow(
      id: data.id.present ? data.id.value : this.id,
      parkedAt: data.parkedAt.present ? data.parkedAt.value : this.parkedAt,
      payload: data.payload.present ? data.payload.value : this.payload,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ParkedSaleRow(')
          ..write('id: $id, ')
          ..write('parkedAt: $parkedAt, ')
          ..write('payload: $payload')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, parkedAt, payload);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ParkedSaleRow &&
          other.id == this.id &&
          other.parkedAt == this.parkedAt &&
          other.payload == this.payload);
}

class ParkedSalesCompanion extends UpdateCompanion<ParkedSaleRow> {
  final Value<String> id;
  final Value<DateTime> parkedAt;
  final Value<String> payload;
  final Value<int> rowid;
  const ParkedSalesCompanion({
    this.id = const Value.absent(),
    this.parkedAt = const Value.absent(),
    this.payload = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ParkedSalesCompanion.insert({
    required String id,
    required DateTime parkedAt,
    required String payload,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       parkedAt = Value(parkedAt),
       payload = Value(payload);
  static Insertable<ParkedSaleRow> custom({
    Expression<String>? id,
    Expression<DateTime>? parkedAt,
    Expression<String>? payload,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (parkedAt != null) 'parked_at': parkedAt,
      if (payload != null) 'payload': payload,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ParkedSalesCompanion copyWith({
    Value<String>? id,
    Value<DateTime>? parkedAt,
    Value<String>? payload,
    Value<int>? rowid,
  }) {
    return ParkedSalesCompanion(
      id: id ?? this.id,
      parkedAt: parkedAt ?? this.parkedAt,
      payload: payload ?? this.payload,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (parkedAt.present) {
      map['parked_at'] = Variable<DateTime>(parkedAt.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ParkedSalesCompanion(')
          ..write('id: $id, ')
          ..write('parkedAt: $parkedAt, ')
          ..write('payload: $payload, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsRowTable extends SettingsRow
    with TableInfo<$SettingsRowTable, SettingsRowData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsRowTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shopNameMeta = const VerificationMeta(
    'shopName',
  );
  @override
  late final GeneratedColumn<String> shopName = GeneratedColumn<String>(
    'shop_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _shopNameENMeta = const VerificationMeta(
    'shopNameEN',
  );
  @override
  late final GeneratedColumn<String> shopNameEN = GeneratedColumn<String>(
    'shop_name_e_n',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taxRateMeta = const VerificationMeta(
    'taxRate',
  );
  @override
  late final GeneratedColumn<double> taxRate = GeneratedColumn<double>(
    'tax_rate',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(7),
  );
  static const VerificationMeta _quoteValidDaysMeta = const VerificationMeta(
    'quoteValidDays',
  );
  @override
  late final GeneratedColumn<int> quoteValidDays = GeneratedColumn<int>(
    'quote_valid_days',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(30),
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _phoneMeta = const VerificationMeta('phone');
  @override
  late final GeneratedColumn<String> phone = GeneratedColumn<String>(
    'phone',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cashierNameMeta = const VerificationMeta(
    'cashierName',
  );
  @override
  late final GeneratedColumn<String> cashierName = GeneratedColumn<String>(
    'cashier_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _taxIdMeta = const VerificationMeta('taxId');
  @override
  late final GeneratedColumn<String> taxId = GeneratedColumn<String>(
    'tax_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _branchNoMeta = const VerificationMeta(
    'branchNo',
  );
  @override
  late final GeneratedColumn<String> branchNo = GeneratedColumn<String>(
    'branch_no',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    shopName,
    shopNameEN,
    taxRate,
    quoteValidDays,
    address,
    phone,
    cashierName,
    taxId,
    branchNo,
    updatedAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings_row';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingsRowData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('shop_name')) {
      context.handle(
        _shopNameMeta,
        shopName.isAcceptableOrUnknown(data['shop_name']!, _shopNameMeta),
      );
    } else if (isInserting) {
      context.missing(_shopNameMeta);
    }
    if (data.containsKey('shop_name_e_n')) {
      context.handle(
        _shopNameENMeta,
        shopNameEN.isAcceptableOrUnknown(
          data['shop_name_e_n']!,
          _shopNameENMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_shopNameENMeta);
    }
    if (data.containsKey('tax_rate')) {
      context.handle(
        _taxRateMeta,
        taxRate.isAcceptableOrUnknown(data['tax_rate']!, _taxRateMeta),
      );
    }
    if (data.containsKey('quote_valid_days')) {
      context.handle(
        _quoteValidDaysMeta,
        quoteValidDays.isAcceptableOrUnknown(
          data['quote_valid_days']!,
          _quoteValidDaysMeta,
        ),
      );
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    }
    if (data.containsKey('phone')) {
      context.handle(
        _phoneMeta,
        phone.isAcceptableOrUnknown(data['phone']!, _phoneMeta),
      );
    }
    if (data.containsKey('cashier_name')) {
      context.handle(
        _cashierNameMeta,
        cashierName.isAcceptableOrUnknown(
          data['cashier_name']!,
          _cashierNameMeta,
        ),
      );
    }
    if (data.containsKey('tax_id')) {
      context.handle(
        _taxIdMeta,
        taxId.isAcceptableOrUnknown(data['tax_id']!, _taxIdMeta),
      );
    }
    if (data.containsKey('branch_no')) {
      context.handle(
        _branchNoMeta,
        branchNo.isAcceptableOrUnknown(data['branch_no']!, _branchNoMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SettingsRowData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingsRowData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      shopName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shop_name'],
      )!,
      shopNameEN: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shop_name_e_n'],
      )!,
      taxRate: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}tax_rate'],
      )!,
      quoteValidDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}quote_valid_days'],
      )!,
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      ),
      phone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phone'],
      ),
      cashierName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cashier_name'],
      ),
      taxId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tax_id'],
      ),
      branchNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}branch_no'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $SettingsRowTable createAlias(String alias) {
    return $SettingsRowTable(attachedDatabase, alias);
  }
}

class SettingsRowData extends DataClass implements Insertable<SettingsRowData> {
  final int id;
  final String shopName;
  final String shopNameEN;
  final double taxRate;
  final int quoteValidDays;
  final String? address;
  final String? phone;
  final String? cashierName;
  final String? taxId;
  final String? branchNo;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  const SettingsRowData({
    required this.id,
    required this.shopName,
    required this.shopNameEN,
    required this.taxRate,
    required this.quoteValidDays,
    this.address,
    this.phone,
    this.cashierName,
    this.taxId,
    this.branchNo,
    this.updatedAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['shop_name'] = Variable<String>(shopName);
    map['shop_name_e_n'] = Variable<String>(shopNameEN);
    map['tax_rate'] = Variable<double>(taxRate);
    map['quote_valid_days'] = Variable<int>(quoteValidDays);
    if (!nullToAbsent || address != null) {
      map['address'] = Variable<String>(address);
    }
    if (!nullToAbsent || phone != null) {
      map['phone'] = Variable<String>(phone);
    }
    if (!nullToAbsent || cashierName != null) {
      map['cashier_name'] = Variable<String>(cashierName);
    }
    if (!nullToAbsent || taxId != null) {
      map['tax_id'] = Variable<String>(taxId);
    }
    if (!nullToAbsent || branchNo != null) {
      map['branch_no'] = Variable<String>(branchNo);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  SettingsRowCompanion toCompanion(bool nullToAbsent) {
    return SettingsRowCompanion(
      id: Value(id),
      shopName: Value(shopName),
      shopNameEN: Value(shopNameEN),
      taxRate: Value(taxRate),
      quoteValidDays: Value(quoteValidDays),
      address: address == null && nullToAbsent
          ? const Value.absent()
          : Value(address),
      phone: phone == null && nullToAbsent
          ? const Value.absent()
          : Value(phone),
      cashierName: cashierName == null && nullToAbsent
          ? const Value.absent()
          : Value(cashierName),
      taxId: taxId == null && nullToAbsent
          ? const Value.absent()
          : Value(taxId),
      branchNo: branchNo == null && nullToAbsent
          ? const Value.absent()
          : Value(branchNo),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory SettingsRowData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingsRowData(
      id: serializer.fromJson<int>(json['id']),
      shopName: serializer.fromJson<String>(json['shopName']),
      shopNameEN: serializer.fromJson<String>(json['shopNameEN']),
      taxRate: serializer.fromJson<double>(json['taxRate']),
      quoteValidDays: serializer.fromJson<int>(json['quoteValidDays']),
      address: serializer.fromJson<String?>(json['address']),
      phone: serializer.fromJson<String?>(json['phone']),
      cashierName: serializer.fromJson<String?>(json['cashierName']),
      taxId: serializer.fromJson<String?>(json['taxId']),
      branchNo: serializer.fromJson<String?>(json['branchNo']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'shopName': serializer.toJson<String>(shopName),
      'shopNameEN': serializer.toJson<String>(shopNameEN),
      'taxRate': serializer.toJson<double>(taxRate),
      'quoteValidDays': serializer.toJson<int>(quoteValidDays),
      'address': serializer.toJson<String?>(address),
      'phone': serializer.toJson<String?>(phone),
      'cashierName': serializer.toJson<String?>(cashierName),
      'taxId': serializer.toJson<String?>(taxId),
      'branchNo': serializer.toJson<String?>(branchNo),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  SettingsRowData copyWith({
    int? id,
    String? shopName,
    String? shopNameEN,
    double? taxRate,
    int? quoteValidDays,
    Value<String?> address = const Value.absent(),
    Value<String?> phone = const Value.absent(),
    Value<String?> cashierName = const Value.absent(),
    Value<String?> taxId = const Value.absent(),
    Value<String?> branchNo = const Value.absent(),
    Value<DateTime?> updatedAt = const Value.absent(),
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => SettingsRowData(
    id: id ?? this.id,
    shopName: shopName ?? this.shopName,
    shopNameEN: shopNameEN ?? this.shopNameEN,
    taxRate: taxRate ?? this.taxRate,
    quoteValidDays: quoteValidDays ?? this.quoteValidDays,
    address: address.present ? address.value : this.address,
    phone: phone.present ? phone.value : this.phone,
    cashierName: cashierName.present ? cashierName.value : this.cashierName,
    taxId: taxId.present ? taxId.value : this.taxId,
    branchNo: branchNo.present ? branchNo.value : this.branchNo,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  SettingsRowData copyWithCompanion(SettingsRowCompanion data) {
    return SettingsRowData(
      id: data.id.present ? data.id.value : this.id,
      shopName: data.shopName.present ? data.shopName.value : this.shopName,
      shopNameEN: data.shopNameEN.present
          ? data.shopNameEN.value
          : this.shopNameEN,
      taxRate: data.taxRate.present ? data.taxRate.value : this.taxRate,
      quoteValidDays: data.quoteValidDays.present
          ? data.quoteValidDays.value
          : this.quoteValidDays,
      address: data.address.present ? data.address.value : this.address,
      phone: data.phone.present ? data.phone.value : this.phone,
      cashierName: data.cashierName.present
          ? data.cashierName.value
          : this.cashierName,
      taxId: data.taxId.present ? data.taxId.value : this.taxId,
      branchNo: data.branchNo.present ? data.branchNo.value : this.branchNo,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingsRowData(')
          ..write('id: $id, ')
          ..write('shopName: $shopName, ')
          ..write('shopNameEN: $shopNameEN, ')
          ..write('taxRate: $taxRate, ')
          ..write('quoteValidDays: $quoteValidDays, ')
          ..write('address: $address, ')
          ..write('phone: $phone, ')
          ..write('cashierName: $cashierName, ')
          ..write('taxId: $taxId, ')
          ..write('branchNo: $branchNo, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    shopName,
    shopNameEN,
    taxRate,
    quoteValidDays,
    address,
    phone,
    cashierName,
    taxId,
    branchNo,
    updatedAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingsRowData &&
          other.id == this.id &&
          other.shopName == this.shopName &&
          other.shopNameEN == this.shopNameEN &&
          other.taxRate == this.taxRate &&
          other.quoteValidDays == this.quoteValidDays &&
          other.address == this.address &&
          other.phone == this.phone &&
          other.cashierName == this.cashierName &&
          other.taxId == this.taxId &&
          other.branchNo == this.branchNo &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt);
}

class SettingsRowCompanion extends UpdateCompanion<SettingsRowData> {
  final Value<int> id;
  final Value<String> shopName;
  final Value<String> shopNameEN;
  final Value<double> taxRate;
  final Value<int> quoteValidDays;
  final Value<String?> address;
  final Value<String?> phone;
  final Value<String?> cashierName;
  final Value<String?> taxId;
  final Value<String?> branchNo;
  final Value<DateTime?> updatedAt;
  final Value<DateTime?> deletedAt;
  const SettingsRowCompanion({
    this.id = const Value.absent(),
    this.shopName = const Value.absent(),
    this.shopNameEN = const Value.absent(),
    this.taxRate = const Value.absent(),
    this.quoteValidDays = const Value.absent(),
    this.address = const Value.absent(),
    this.phone = const Value.absent(),
    this.cashierName = const Value.absent(),
    this.taxId = const Value.absent(),
    this.branchNo = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
  });
  SettingsRowCompanion.insert({
    this.id = const Value.absent(),
    required String shopName,
    required String shopNameEN,
    this.taxRate = const Value.absent(),
    this.quoteValidDays = const Value.absent(),
    this.address = const Value.absent(),
    this.phone = const Value.absent(),
    this.cashierName = const Value.absent(),
    this.taxId = const Value.absent(),
    this.branchNo = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
  }) : shopName = Value(shopName),
       shopNameEN = Value(shopNameEN);
  static Insertable<SettingsRowData> custom({
    Expression<int>? id,
    Expression<String>? shopName,
    Expression<String>? shopNameEN,
    Expression<double>? taxRate,
    Expression<int>? quoteValidDays,
    Expression<String>? address,
    Expression<String>? phone,
    Expression<String>? cashierName,
    Expression<String>? taxId,
    Expression<String>? branchNo,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? deletedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (shopName != null) 'shop_name': shopName,
      if (shopNameEN != null) 'shop_name_e_n': shopNameEN,
      if (taxRate != null) 'tax_rate': taxRate,
      if (quoteValidDays != null) 'quote_valid_days': quoteValidDays,
      if (address != null) 'address': address,
      if (phone != null) 'phone': phone,
      if (cashierName != null) 'cashier_name': cashierName,
      if (taxId != null) 'tax_id': taxId,
      if (branchNo != null) 'branch_no': branchNo,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
    });
  }

  SettingsRowCompanion copyWith({
    Value<int>? id,
    Value<String>? shopName,
    Value<String>? shopNameEN,
    Value<double>? taxRate,
    Value<int>? quoteValidDays,
    Value<String?>? address,
    Value<String?>? phone,
    Value<String?>? cashierName,
    Value<String?>? taxId,
    Value<String?>? branchNo,
    Value<DateTime?>? updatedAt,
    Value<DateTime?>? deletedAt,
  }) {
    return SettingsRowCompanion(
      id: id ?? this.id,
      shopName: shopName ?? this.shopName,
      shopNameEN: shopNameEN ?? this.shopNameEN,
      taxRate: taxRate ?? this.taxRate,
      quoteValidDays: quoteValidDays ?? this.quoteValidDays,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      cashierName: cashierName ?? this.cashierName,
      taxId: taxId ?? this.taxId,
      branchNo: branchNo ?? this.branchNo,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (shopName.present) {
      map['shop_name'] = Variable<String>(shopName.value);
    }
    if (shopNameEN.present) {
      map['shop_name_e_n'] = Variable<String>(shopNameEN.value);
    }
    if (taxRate.present) {
      map['tax_rate'] = Variable<double>(taxRate.value);
    }
    if (quoteValidDays.present) {
      map['quote_valid_days'] = Variable<int>(quoteValidDays.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (phone.present) {
      map['phone'] = Variable<String>(phone.value);
    }
    if (cashierName.present) {
      map['cashier_name'] = Variable<String>(cashierName.value);
    }
    if (taxId.present) {
      map['tax_id'] = Variable<String>(taxId.value);
    }
    if (branchNo.present) {
      map['branch_no'] = Variable<String>(branchNo.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsRowCompanion(')
          ..write('id: $id, ')
          ..write('shopName: $shopName, ')
          ..write('shopNameEN: $shopNameEN, ')
          ..write('taxRate: $taxRate, ')
          ..write('quoteValidDays: $quoteValidDays, ')
          ..write('address: $address, ')
          ..write('phone: $phone, ')
          ..write('cashierName: $cashierName, ')
          ..write('taxId: $taxId, ')
          ..write('branchNo: $branchNo, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }
}

class $AppMetaTable extends AppMeta with TableInfo<$AppMetaTable, AppMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppMetaTable createAlias(String alias) {
    return $AppMetaTable(attachedDatabase, alias);
  }
}

class AppMetaRow extends DataClass implements Insertable<AppMetaRow> {
  final String key;
  final String value;
  const AppMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppMetaCompanion toCompanion(bool nullToAbsent) {
    return AppMetaCompanion(key: Value(key), value: Value(value));
  }

  factory AppMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppMetaRow copyWith({String? key, String? value}) =>
      AppMetaRow(key: key ?? this.key, value: value ?? this.value);
  AppMetaRow copyWithCompanion(AppMetaCompanion data) {
    return AppMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class AppMetaCompanion extends UpdateCompanion<AppMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppMetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProductsTable products = $ProductsTable(this);
  late final $CategoriesTable categories = $CategoriesTable(this);
  late final $CustomersTable customers = $CustomersTable(this);
  late final $MechanicsTable mechanics = $MechanicsTable(this);
  late final $SalesTable sales = $SalesTable(this);
  late final $SaleItemsTable saleItems = $SaleItemsTable(this);
  late final $PurchaseOrdersTable purchaseOrders = $PurchaseOrdersTable(this);
  late final $PoItemsTable poItems = $PoItemsTable(this);
  late final $ReturnsTable returns = $ReturnsTable(this);
  late final $ReturnItemsTable returnItems = $ReturnItemsTable(this);
  late final $QuotesTable quotes = $QuotesTable(this);
  late final $QuoteItemsTable quoteItems = $QuoteItemsTable(this);
  late final $MovementsTable movements = $MovementsTable(this);
  late final $SuppliersTable suppliers = $SuppliersTable(this);
  late final $CreditPaymentsTable creditPayments = $CreditPaymentsTable(this);
  late final $ShiftsTable shifts = $ShiftsTable(this);
  late final $DrawerEntriesTable drawerEntries = $DrawerEntriesTable(this);
  late final $ParkedSalesTable parkedSales = $ParkedSalesTable(this);
  late final $SettingsRowTable settingsRow = $SettingsRowTable(this);
  late final $AppMetaTable appMeta = $AppMetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    products,
    categories,
    customers,
    mechanics,
    sales,
    saleItems,
    purchaseOrders,
    poItems,
    returns,
    returnItems,
    quotes,
    quoteItems,
    movements,
    suppliers,
    creditPayments,
    shifts,
    drawerEntries,
    parkedSales,
    settingsRow,
    appMeta,
  ];
}

typedef $$ProductsTableCreateCompanionBuilder =
    ProductsCompanion Function({
      required String id,
      required String partNo,
      required String name,
      required String nameTH,
      required String category,
      required String brand,
      required double price,
      required double cost,
      required int stock,
      required int minStock,
      Value<String?> compat,
      Value<String?> zone,
      Value<DateTime?> updatedAt,
      Value<bool> offlineOk,
      Value<int> rowid,
    });
typedef $$ProductsTableUpdateCompanionBuilder =
    ProductsCompanion Function({
      Value<String> id,
      Value<String> partNo,
      Value<String> name,
      Value<String> nameTH,
      Value<String> category,
      Value<String> brand,
      Value<double> price,
      Value<double> cost,
      Value<int> stock,
      Value<int> minStock,
      Value<String?> compat,
      Value<String?> zone,
      Value<DateTime?> updatedAt,
      Value<bool> offlineOk,
      Value<int> rowid,
    });

class $$ProductsTableFilterComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get brand => $composableBuilder(
    column: $table.brand,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stock => $composableBuilder(
    column: $table.stock,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get minStock => $composableBuilder(
    column: $table.minStock,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get compat => $composableBuilder(
    column: $table.compat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get zone => $composableBuilder(
    column: $table.zone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get offlineOk => $composableBuilder(
    column: $table.offlineOk,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProductsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get brand => $composableBuilder(
    column: $table.brand,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stock => $composableBuilder(
    column: $table.stock,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get minStock => $composableBuilder(
    column: $table.minStock,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get compat => $composableBuilder(
    column: $table.compat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get zone => $composableBuilder(
    column: $table.zone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get offlineOk => $composableBuilder(
    column: $table.offlineOk,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProductsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProductsTable> {
  $$ProductsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get partNo =>
      $composableBuilder(column: $table.partNo, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameTH =>
      $composableBuilder(column: $table.nameTH, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get brand =>
      $composableBuilder(column: $table.brand, builder: (column) => column);

  GeneratedColumn<double> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<double> get cost =>
      $composableBuilder(column: $table.cost, builder: (column) => column);

  GeneratedColumn<int> get stock =>
      $composableBuilder(column: $table.stock, builder: (column) => column);

  GeneratedColumn<int> get minStock =>
      $composableBuilder(column: $table.minStock, builder: (column) => column);

  GeneratedColumn<String> get compat =>
      $composableBuilder(column: $table.compat, builder: (column) => column);

  GeneratedColumn<String> get zone =>
      $composableBuilder(column: $table.zone, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get offlineOk =>
      $composableBuilder(column: $table.offlineOk, builder: (column) => column);
}

class $$ProductsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProductsTable,
          ProductRow,
          $$ProductsTableFilterComposer,
          $$ProductsTableOrderingComposer,
          $$ProductsTableAnnotationComposer,
          $$ProductsTableCreateCompanionBuilder,
          $$ProductsTableUpdateCompanionBuilder,
          (
            ProductRow,
            BaseReferences<_$AppDatabase, $ProductsTable, ProductRow>,
          ),
          ProductRow,
          PrefetchHooks Function()
        > {
  $$ProductsTableTableManager(_$AppDatabase db, $ProductsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProductsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProductsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProductsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> partNo = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> nameTH = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<String> brand = const Value.absent(),
                Value<double> price = const Value.absent(),
                Value<double> cost = const Value.absent(),
                Value<int> stock = const Value.absent(),
                Value<int> minStock = const Value.absent(),
                Value<String?> compat = const Value.absent(),
                Value<String?> zone = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<bool> offlineOk = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProductsCompanion(
                id: id,
                partNo: partNo,
                name: name,
                nameTH: nameTH,
                category: category,
                brand: brand,
                price: price,
                cost: cost,
                stock: stock,
                minStock: minStock,
                compat: compat,
                zone: zone,
                updatedAt: updatedAt,
                offlineOk: offlineOk,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String partNo,
                required String name,
                required String nameTH,
                required String category,
                required String brand,
                required double price,
                required double cost,
                required int stock,
                required int minStock,
                Value<String?> compat = const Value.absent(),
                Value<String?> zone = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<bool> offlineOk = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProductsCompanion.insert(
                id: id,
                partNo: partNo,
                name: name,
                nameTH: nameTH,
                category: category,
                brand: brand,
                price: price,
                cost: cost,
                stock: stock,
                minStock: minStock,
                compat: compat,
                zone: zone,
                updatedAt: updatedAt,
                offlineOk: offlineOk,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProductsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProductsTable,
      ProductRow,
      $$ProductsTableFilterComposer,
      $$ProductsTableOrderingComposer,
      $$ProductsTableAnnotationComposer,
      $$ProductsTableCreateCompanionBuilder,
      $$ProductsTableUpdateCompanionBuilder,
      (ProductRow, BaseReferences<_$AppDatabase, $ProductsTable, ProductRow>),
      ProductRow,
      PrefetchHooks Function()
    >;
typedef $$CategoriesTableCreateCompanionBuilder =
    CategoriesCompanion Function({
      required String name,
      required int position,
      Value<int> rowid,
    });
typedef $$CategoriesTableUpdateCompanionBuilder =
    CategoriesCompanion Function({
      Value<String> name,
      Value<int> position,
      Value<int> rowid,
    });

class $$CategoriesTableFilterComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CategoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CategoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);
}

class $$CategoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CategoriesTable,
          CategoryRow,
          $$CategoriesTableFilterComposer,
          $$CategoriesTableOrderingComposer,
          $$CategoriesTableAnnotationComposer,
          $$CategoriesTableCreateCompanionBuilder,
          $$CategoriesTableUpdateCompanionBuilder,
          (
            CategoryRow,
            BaseReferences<_$AppDatabase, $CategoriesTable, CategoryRow>,
          ),
          CategoryRow,
          PrefetchHooks Function()
        > {
  $$CategoriesTableTableManager(_$AppDatabase db, $CategoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CategoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CategoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> name = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CategoriesCompanion(
                name: name,
                position: position,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String name,
                required int position,
                Value<int> rowid = const Value.absent(),
              }) => CategoriesCompanion.insert(
                name: name,
                position: position,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CategoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CategoriesTable,
      CategoryRow,
      $$CategoriesTableFilterComposer,
      $$CategoriesTableOrderingComposer,
      $$CategoriesTableAnnotationComposer,
      $$CategoriesTableCreateCompanionBuilder,
      $$CategoriesTableUpdateCompanionBuilder,
      (
        CategoryRow,
        BaseReferences<_$AppDatabase, $CategoriesTable, CategoryRow>,
      ),
      CategoryRow,
      PrefetchHooks Function()
    >;
typedef $$CustomersTableCreateCompanionBuilder =
    CustomersCompanion Function({
      required String id,
      required String code,
      required String name,
      required String nameTH,
      Value<String?> phone,
      Value<String?> address,
      Value<int> points,
      Value<double> totalSpend,
      required String createdAt,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$CustomersTableUpdateCompanionBuilder =
    CustomersCompanion Function({
      Value<String> id,
      Value<String> code,
      Value<String> name,
      Value<String> nameTH,
      Value<String?> phone,
      Value<String?> address,
      Value<int> points,
      Value<double> totalSpend,
      Value<String> createdAt,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$CustomersTableFilterComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get points => $composableBuilder(
    column: $table.points,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get totalSpend => $composableBuilder(
    column: $table.totalSpend,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CustomersTableOrderingComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get points => $composableBuilder(
    column: $table.points,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get totalSpend => $composableBuilder(
    column: $table.totalSpend,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CustomersTableAnnotationComposer
    extends Composer<_$AppDatabase, $CustomersTable> {
  $$CustomersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameTH =>
      $composableBuilder(column: $table.nameTH, builder: (column) => column);

  GeneratedColumn<String> get phone =>
      $composableBuilder(column: $table.phone, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<int> get points =>
      $composableBuilder(column: $table.points, builder: (column) => column);

  GeneratedColumn<double> get totalSpend => $composableBuilder(
    column: $table.totalSpend,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$CustomersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CustomersTable,
          CustomerRow,
          $$CustomersTableFilterComposer,
          $$CustomersTableOrderingComposer,
          $$CustomersTableAnnotationComposer,
          $$CustomersTableCreateCompanionBuilder,
          $$CustomersTableUpdateCompanionBuilder,
          (
            CustomerRow,
            BaseReferences<_$AppDatabase, $CustomersTable, CustomerRow>,
          ),
          CustomerRow,
          PrefetchHooks Function()
        > {
  $$CustomersTableTableManager(_$AppDatabase db, $CustomersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CustomersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CustomersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CustomersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> nameTH = const Value.absent(),
                Value<String?> phone = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<int> points = const Value.absent(),
                Value<double> totalSpend = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CustomersCompanion(
                id: id,
                code: code,
                name: name,
                nameTH: nameTH,
                phone: phone,
                address: address,
                points: points,
                totalSpend: totalSpend,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String code,
                required String name,
                required String nameTH,
                Value<String?> phone = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<int> points = const Value.absent(),
                Value<double> totalSpend = const Value.absent(),
                required String createdAt,
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CustomersCompanion.insert(
                id: id,
                code: code,
                name: name,
                nameTH: nameTH,
                phone: phone,
                address: address,
                points: points,
                totalSpend: totalSpend,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CustomersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CustomersTable,
      CustomerRow,
      $$CustomersTableFilterComposer,
      $$CustomersTableOrderingComposer,
      $$CustomersTableAnnotationComposer,
      $$CustomersTableCreateCompanionBuilder,
      $$CustomersTableUpdateCompanionBuilder,
      (
        CustomerRow,
        BaseReferences<_$AppDatabase, $CustomersTable, CustomerRow>,
      ),
      CustomerRow,
      PrefetchHooks Function()
    >;
typedef $$MechanicsTableCreateCompanionBuilder =
    MechanicsCompanion Function({
      required String id,
      required String code,
      required String name,
      Value<String?> nameTH,
      Value<String?> nickname,
      Value<String?> shopName,
      Value<String?> phone,
      Value<String?> note,
      Value<double> creditLimit,
      Value<double> creditBalance,
      Value<double> totalSales,
      Value<double> totalCredit,
      Value<double> totalDiscount,
      Value<double> totalMarkup,
      required String createdAt,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });
typedef $$MechanicsTableUpdateCompanionBuilder =
    MechanicsCompanion Function({
      Value<String> id,
      Value<String> code,
      Value<String> name,
      Value<String?> nameTH,
      Value<String?> nickname,
      Value<String?> shopName,
      Value<String?> phone,
      Value<String?> note,
      Value<double> creditLimit,
      Value<double> creditBalance,
      Value<double> totalSales,
      Value<double> totalCredit,
      Value<double> totalDiscount,
      Value<double> totalMarkup,
      Value<String> createdAt,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
      Value<int> rowid,
    });

class $$MechanicsTableFilterComposer
    extends Composer<_$AppDatabase, $MechanicsTable> {
  $$MechanicsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shopName => $composableBuilder(
    column: $table.shopName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get creditLimit => $composableBuilder(
    column: $table.creditLimit,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get creditBalance => $composableBuilder(
    column: $table.creditBalance,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get totalSales => $composableBuilder(
    column: $table.totalSales,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get totalCredit => $composableBuilder(
    column: $table.totalCredit,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get totalDiscount => $composableBuilder(
    column: $table.totalDiscount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get totalMarkup => $composableBuilder(
    column: $table.totalMarkup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MechanicsTableOrderingComposer
    extends Composer<_$AppDatabase, $MechanicsTable> {
  $$MechanicsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shopName => $composableBuilder(
    column: $table.shopName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get creditLimit => $composableBuilder(
    column: $table.creditLimit,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get creditBalance => $composableBuilder(
    column: $table.creditBalance,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get totalSales => $composableBuilder(
    column: $table.totalSales,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get totalCredit => $composableBuilder(
    column: $table.totalCredit,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get totalDiscount => $composableBuilder(
    column: $table.totalDiscount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get totalMarkup => $composableBuilder(
    column: $table.totalMarkup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MechanicsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MechanicsTable> {
  $$MechanicsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameTH =>
      $composableBuilder(column: $table.nameTH, builder: (column) => column);

  GeneratedColumn<String> get nickname =>
      $composableBuilder(column: $table.nickname, builder: (column) => column);

  GeneratedColumn<String> get shopName =>
      $composableBuilder(column: $table.shopName, builder: (column) => column);

  GeneratedColumn<String> get phone =>
      $composableBuilder(column: $table.phone, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<double> get creditLimit => $composableBuilder(
    column: $table.creditLimit,
    builder: (column) => column,
  );

  GeneratedColumn<double> get creditBalance => $composableBuilder(
    column: $table.creditBalance,
    builder: (column) => column,
  );

  GeneratedColumn<double> get totalSales => $composableBuilder(
    column: $table.totalSales,
    builder: (column) => column,
  );

  GeneratedColumn<double> get totalCredit => $composableBuilder(
    column: $table.totalCredit,
    builder: (column) => column,
  );

  GeneratedColumn<double> get totalDiscount => $composableBuilder(
    column: $table.totalDiscount,
    builder: (column) => column,
  );

  GeneratedColumn<double> get totalMarkup => $composableBuilder(
    column: $table.totalMarkup,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$MechanicsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MechanicsTable,
          MechanicRow,
          $$MechanicsTableFilterComposer,
          $$MechanicsTableOrderingComposer,
          $$MechanicsTableAnnotationComposer,
          $$MechanicsTableCreateCompanionBuilder,
          $$MechanicsTableUpdateCompanionBuilder,
          (
            MechanicRow,
            BaseReferences<_$AppDatabase, $MechanicsTable, MechanicRow>,
          ),
          MechanicRow,
          PrefetchHooks Function()
        > {
  $$MechanicsTableTableManager(_$AppDatabase db, $MechanicsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MechanicsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MechanicsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MechanicsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> nameTH = const Value.absent(),
                Value<String?> nickname = const Value.absent(),
                Value<String?> shopName = const Value.absent(),
                Value<String?> phone = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<double> creditLimit = const Value.absent(),
                Value<double> creditBalance = const Value.absent(),
                Value<double> totalSales = const Value.absent(),
                Value<double> totalCredit = const Value.absent(),
                Value<double> totalDiscount = const Value.absent(),
                Value<double> totalMarkup = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MechanicsCompanion(
                id: id,
                code: code,
                name: name,
                nameTH: nameTH,
                nickname: nickname,
                shopName: shopName,
                phone: phone,
                note: note,
                creditLimit: creditLimit,
                creditBalance: creditBalance,
                totalSales: totalSales,
                totalCredit: totalCredit,
                totalDiscount: totalDiscount,
                totalMarkup: totalMarkup,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String code,
                required String name,
                Value<String?> nameTH = const Value.absent(),
                Value<String?> nickname = const Value.absent(),
                Value<String?> shopName = const Value.absent(),
                Value<String?> phone = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<double> creditLimit = const Value.absent(),
                Value<double> creditBalance = const Value.absent(),
                Value<double> totalSales = const Value.absent(),
                Value<double> totalCredit = const Value.absent(),
                Value<double> totalDiscount = const Value.absent(),
                Value<double> totalMarkup = const Value.absent(),
                required String createdAt,
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MechanicsCompanion.insert(
                id: id,
                code: code,
                name: name,
                nameTH: nameTH,
                nickname: nickname,
                shopName: shopName,
                phone: phone,
                note: note,
                creditLimit: creditLimit,
                creditBalance: creditBalance,
                totalSales: totalSales,
                totalCredit: totalCredit,
                totalDiscount: totalDiscount,
                totalMarkup: totalMarkup,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MechanicsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MechanicsTable,
      MechanicRow,
      $$MechanicsTableFilterComposer,
      $$MechanicsTableOrderingComposer,
      $$MechanicsTableAnnotationComposer,
      $$MechanicsTableCreateCompanionBuilder,
      $$MechanicsTableUpdateCompanionBuilder,
      (
        MechanicRow,
        BaseReferences<_$AppDatabase, $MechanicsTable, MechanicRow>,
      ),
      MechanicRow,
      PrefetchHooks Function()
    >;
typedef $$SalesTableCreateCompanionBuilder =
    SalesCompanion Function({
      required String id,
      required String receiptNo,
      required double subtotal,
      Value<double> discount,
      required double total,
      required String paymentMethod,
      Value<String?> customerId,
      Value<String?> customerName,
      Value<String?> mechanicId,
      Value<String?> mechanicName,
      Value<double?> mechanicDelta,
      Value<int> pointsGranted,
      required DateTime date,
      Value<bool> voided,
      Value<DateTime?> voidedAt,
      Value<String?> shiftId,
      Value<int> rowid,
    });
typedef $$SalesTableUpdateCompanionBuilder =
    SalesCompanion Function({
      Value<String> id,
      Value<String> receiptNo,
      Value<double> subtotal,
      Value<double> discount,
      Value<double> total,
      Value<String> paymentMethod,
      Value<String?> customerId,
      Value<String?> customerName,
      Value<String?> mechanicId,
      Value<String?> mechanicName,
      Value<double?> mechanicDelta,
      Value<int> pointsGranted,
      Value<DateTime> date,
      Value<bool> voided,
      Value<DateTime?> voidedAt,
      Value<String?> shiftId,
      Value<int> rowid,
    });

final class $$SalesTableReferences
    extends BaseReferences<_$AppDatabase, $SalesTable, SaleRow> {
  $$SalesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SaleItemsTable, List<SaleItemRow>>
  _saleItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.saleItems,
    aliasName: 'sales__id__sale_items__sale_id',
  );

  $$SaleItemsTableProcessedTableManager get saleItemsRefs {
    final manager = $$SaleItemsTableTableManager(
      $_db,
      $_db.saleItems,
    ).filter((f) => f.saleId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_saleItemsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SalesTableFilterComposer extends Composer<_$AppDatabase, $SalesTable> {
  $$SalesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get subtotal => $composableBuilder(
    column: $table.subtotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get discount => $composableBuilder(
    column: $table.discount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get mechanicDelta => $composableBuilder(
    column: $table.mechanicDelta,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pointsGranted => $composableBuilder(
    column: $table.pointsGranted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get voided => $composableBuilder(
    column: $table.voided,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get voidedAt => $composableBuilder(
    column: $table.voidedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shiftId => $composableBuilder(
    column: $table.shiftId,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> saleItemsRefs(
    Expression<bool> Function($$SaleItemsTableFilterComposer f) f,
  ) {
    final $$SaleItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.saleItems,
      getReferencedColumn: (t) => t.saleId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SaleItemsTableFilterComposer(
            $db: $db,
            $table: $db.saleItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SalesTableOrderingComposer
    extends Composer<_$AppDatabase, $SalesTable> {
  $$SalesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get subtotal => $composableBuilder(
    column: $table.subtotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get discount => $composableBuilder(
    column: $table.discount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get mechanicDelta => $composableBuilder(
    column: $table.mechanicDelta,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pointsGranted => $composableBuilder(
    column: $table.pointsGranted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get voided => $composableBuilder(
    column: $table.voided,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get voidedAt => $composableBuilder(
    column: $table.voidedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shiftId => $composableBuilder(
    column: $table.shiftId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SalesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SalesTable> {
  $$SalesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get receiptNo =>
      $composableBuilder(column: $table.receiptNo, builder: (column) => column);

  GeneratedColumn<double> get subtotal =>
      $composableBuilder(column: $table.subtotal, builder: (column) => column);

  GeneratedColumn<double> get discount =>
      $composableBuilder(column: $table.discount, builder: (column) => column);

  GeneratedColumn<double> get total =>
      $composableBuilder(column: $table.total, builder: (column) => column);

  GeneratedColumn<String> get paymentMethod => $composableBuilder(
    column: $table.paymentMethod,
    builder: (column) => column,
  );

  GeneratedColumn<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => column,
  );

  GeneratedColumn<double> get mechanicDelta => $composableBuilder(
    column: $table.mechanicDelta,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pointsGranted => $composableBuilder(
    column: $table.pointsGranted,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);

  GeneratedColumn<bool> get voided =>
      $composableBuilder(column: $table.voided, builder: (column) => column);

  GeneratedColumn<DateTime> get voidedAt =>
      $composableBuilder(column: $table.voidedAt, builder: (column) => column);

  GeneratedColumn<String> get shiftId =>
      $composableBuilder(column: $table.shiftId, builder: (column) => column);

  Expression<T> saleItemsRefs<T extends Object>(
    Expression<T> Function($$SaleItemsTableAnnotationComposer a) f,
  ) {
    final $$SaleItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.saleItems,
      getReferencedColumn: (t) => t.saleId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SaleItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.saleItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SalesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SalesTable,
          SaleRow,
          $$SalesTableFilterComposer,
          $$SalesTableOrderingComposer,
          $$SalesTableAnnotationComposer,
          $$SalesTableCreateCompanionBuilder,
          $$SalesTableUpdateCompanionBuilder,
          (SaleRow, $$SalesTableReferences),
          SaleRow,
          PrefetchHooks Function({bool saleItemsRefs})
        > {
  $$SalesTableTableManager(_$AppDatabase db, $SalesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SalesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SalesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SalesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> receiptNo = const Value.absent(),
                Value<double> subtotal = const Value.absent(),
                Value<double> discount = const Value.absent(),
                Value<double> total = const Value.absent(),
                Value<String> paymentMethod = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> customerName = const Value.absent(),
                Value<String?> mechanicId = const Value.absent(),
                Value<String?> mechanicName = const Value.absent(),
                Value<double?> mechanicDelta = const Value.absent(),
                Value<int> pointsGranted = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<bool> voided = const Value.absent(),
                Value<DateTime?> voidedAt = const Value.absent(),
                Value<String?> shiftId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SalesCompanion(
                id: id,
                receiptNo: receiptNo,
                subtotal: subtotal,
                discount: discount,
                total: total,
                paymentMethod: paymentMethod,
                customerId: customerId,
                customerName: customerName,
                mechanicId: mechanicId,
                mechanicName: mechanicName,
                mechanicDelta: mechanicDelta,
                pointsGranted: pointsGranted,
                date: date,
                voided: voided,
                voidedAt: voidedAt,
                shiftId: shiftId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String receiptNo,
                required double subtotal,
                Value<double> discount = const Value.absent(),
                required double total,
                required String paymentMethod,
                Value<String?> customerId = const Value.absent(),
                Value<String?> customerName = const Value.absent(),
                Value<String?> mechanicId = const Value.absent(),
                Value<String?> mechanicName = const Value.absent(),
                Value<double?> mechanicDelta = const Value.absent(),
                Value<int> pointsGranted = const Value.absent(),
                required DateTime date,
                Value<bool> voided = const Value.absent(),
                Value<DateTime?> voidedAt = const Value.absent(),
                Value<String?> shiftId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SalesCompanion.insert(
                id: id,
                receiptNo: receiptNo,
                subtotal: subtotal,
                discount: discount,
                total: total,
                paymentMethod: paymentMethod,
                customerId: customerId,
                customerName: customerName,
                mechanicId: mechanicId,
                mechanicName: mechanicName,
                mechanicDelta: mechanicDelta,
                pointsGranted: pointsGranted,
                date: date,
                voided: voided,
                voidedAt: voidedAt,
                shiftId: shiftId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$SalesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({saleItemsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (saleItemsRefs) db.saleItems],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (saleItemsRefs)
                    await $_getPrefetchedData<
                      SaleRow,
                      $SalesTable,
                      SaleItemRow
                    >(
                      currentTable: table,
                      referencedTable: $$SalesTableReferences
                          ._saleItemsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SalesTableReferences(db, table, p0).saleItemsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.saleId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SalesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SalesTable,
      SaleRow,
      $$SalesTableFilterComposer,
      $$SalesTableOrderingComposer,
      $$SalesTableAnnotationComposer,
      $$SalesTableCreateCompanionBuilder,
      $$SalesTableUpdateCompanionBuilder,
      (SaleRow, $$SalesTableReferences),
      SaleRow,
      PrefetchHooks Function({bool saleItemsRefs})
    >;
typedef $$SaleItemsTableCreateCompanionBuilder =
    SaleItemsCompanion Function({
      Value<int> rowId,
      required String saleId,
      required String productId,
      Value<String?> partNo,
      required String name,
      Value<String?> nameTH,
      required int qty,
      required double price,
      Value<double?> costAtSale,
    });
typedef $$SaleItemsTableUpdateCompanionBuilder =
    SaleItemsCompanion Function({
      Value<int> rowId,
      Value<String> saleId,
      Value<String> productId,
      Value<String?> partNo,
      Value<String> name,
      Value<String?> nameTH,
      Value<int> qty,
      Value<double> price,
      Value<double?> costAtSale,
    });

final class $$SaleItemsTableReferences
    extends BaseReferences<_$AppDatabase, $SaleItemsTable, SaleItemRow> {
  $$SaleItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SalesTable _saleIdTable(_$AppDatabase db) =>
      db.sales.createAlias('sale_items__sale_id__sales__id');

  $$SalesTableProcessedTableManager get saleId {
    final $_column = $_itemColumn<String>('sale_id')!;

    final manager = $$SalesTableTableManager(
      $_db,
      $_db.sales,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_saleIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SaleItemsTableFilterComposer
    extends Composer<_$AppDatabase, $SaleItemsTable> {
  $$SaleItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => ColumnFilters(column),
  );

  $$SalesTableFilterComposer get saleId {
    final $$SalesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.saleId,
      referencedTable: $db.sales,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SalesTableFilterComposer(
            $db: $db,
            $table: $db.sales,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SaleItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $SaleItemsTable> {
  $$SaleItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nameTH => $composableBuilder(
    column: $table.nameTH,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => ColumnOrderings(column),
  );

  $$SalesTableOrderingComposer get saleId {
    final $$SalesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.saleId,
      referencedTable: $db.sales,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SalesTableOrderingComposer(
            $db: $db,
            $table: $db.sales,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SaleItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SaleItemsTable> {
  $$SaleItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get partNo =>
      $composableBuilder(column: $table.partNo, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get nameTH =>
      $composableBuilder(column: $table.nameTH, builder: (column) => column);

  GeneratedColumn<int> get qty =>
      $composableBuilder(column: $table.qty, builder: (column) => column);

  GeneratedColumn<double> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => column,
  );

  $$SalesTableAnnotationComposer get saleId {
    final $$SalesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.saleId,
      referencedTable: $db.sales,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SalesTableAnnotationComposer(
            $db: $db,
            $table: $db.sales,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SaleItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SaleItemsTable,
          SaleItemRow,
          $$SaleItemsTableFilterComposer,
          $$SaleItemsTableOrderingComposer,
          $$SaleItemsTableAnnotationComposer,
          $$SaleItemsTableCreateCompanionBuilder,
          $$SaleItemsTableUpdateCompanionBuilder,
          (SaleItemRow, $$SaleItemsTableReferences),
          SaleItemRow,
          PrefetchHooks Function({bool saleId})
        > {
  $$SaleItemsTableTableManager(_$AppDatabase db, $SaleItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SaleItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SaleItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SaleItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                Value<String> saleId = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String?> partNo = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> nameTH = const Value.absent(),
                Value<int> qty = const Value.absent(),
                Value<double> price = const Value.absent(),
                Value<double?> costAtSale = const Value.absent(),
              }) => SaleItemsCompanion(
                rowId: rowId,
                saleId: saleId,
                productId: productId,
                partNo: partNo,
                name: name,
                nameTH: nameTH,
                qty: qty,
                price: price,
                costAtSale: costAtSale,
              ),
          createCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                required String saleId,
                required String productId,
                Value<String?> partNo = const Value.absent(),
                required String name,
                Value<String?> nameTH = const Value.absent(),
                required int qty,
                required double price,
                Value<double?> costAtSale = const Value.absent(),
              }) => SaleItemsCompanion.insert(
                rowId: rowId,
                saleId: saleId,
                productId: productId,
                partNo: partNo,
                name: name,
                nameTH: nameTH,
                qty: qty,
                price: price,
                costAtSale: costAtSale,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SaleItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({saleId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (saleId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.saleId,
                                referencedTable: $$SaleItemsTableReferences
                                    ._saleIdTable(db),
                                referencedColumn: $$SaleItemsTableReferences
                                    ._saleIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SaleItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SaleItemsTable,
      SaleItemRow,
      $$SaleItemsTableFilterComposer,
      $$SaleItemsTableOrderingComposer,
      $$SaleItemsTableAnnotationComposer,
      $$SaleItemsTableCreateCompanionBuilder,
      $$SaleItemsTableUpdateCompanionBuilder,
      (SaleItemRow, $$SaleItemsTableReferences),
      SaleItemRow,
      PrefetchHooks Function({bool saleId})
    >;
typedef $$PurchaseOrdersTableCreateCompanionBuilder =
    PurchaseOrdersCompanion Function({
      required String id,
      required String poNo,
      required String supplier,
      Value<String> status,
      required DateTime createdAt,
      Value<DateTime?> receivedAt,
      Value<DateTime?> cancelledAt,
      Value<int> rowid,
    });
typedef $$PurchaseOrdersTableUpdateCompanionBuilder =
    PurchaseOrdersCompanion Function({
      Value<String> id,
      Value<String> poNo,
      Value<String> supplier,
      Value<String> status,
      Value<DateTime> createdAt,
      Value<DateTime?> receivedAt,
      Value<DateTime?> cancelledAt,
      Value<int> rowid,
    });

final class $$PurchaseOrdersTableReferences
    extends
        BaseReferences<_$AppDatabase, $PurchaseOrdersTable, PurchaseOrderRow> {
  $$PurchaseOrdersTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$PoItemsTable, List<PoItemRow>> _poItemsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.poItems,
    aliasName: 'purchase_orders__id__po_items__po_id',
  );

  $$PoItemsTableProcessedTableManager get poItemsRefs {
    final manager = $$PoItemsTableTableManager(
      $_db,
      $_db.poItems,
    ).filter((f) => f.poId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_poItemsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PurchaseOrdersTableFilterComposer
    extends Composer<_$AppDatabase, $PurchaseOrdersTable> {
  $$PurchaseOrdersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get poNo => $composableBuilder(
    column: $table.poNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get supplier => $composableBuilder(
    column: $table.supplier,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cancelledAt => $composableBuilder(
    column: $table.cancelledAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> poItemsRefs(
    Expression<bool> Function($$PoItemsTableFilterComposer f) f,
  ) {
    final $$PoItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.poItems,
      getReferencedColumn: (t) => t.poId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PoItemsTableFilterComposer(
            $db: $db,
            $table: $db.poItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PurchaseOrdersTableOrderingComposer
    extends Composer<_$AppDatabase, $PurchaseOrdersTable> {
  $$PurchaseOrdersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get poNo => $composableBuilder(
    column: $table.poNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get supplier => $composableBuilder(
    column: $table.supplier,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cancelledAt => $composableBuilder(
    column: $table.cancelledAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PurchaseOrdersTableAnnotationComposer
    extends Composer<_$AppDatabase, $PurchaseOrdersTable> {
  $$PurchaseOrdersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get poNo =>
      $composableBuilder(column: $table.poNo, builder: (column) => column);

  GeneratedColumn<String> get supplier =>
      $composableBuilder(column: $table.supplier, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get cancelledAt => $composableBuilder(
    column: $table.cancelledAt,
    builder: (column) => column,
  );

  Expression<T> poItemsRefs<T extends Object>(
    Expression<T> Function($$PoItemsTableAnnotationComposer a) f,
  ) {
    final $$PoItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.poItems,
      getReferencedColumn: (t) => t.poId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PoItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.poItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PurchaseOrdersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PurchaseOrdersTable,
          PurchaseOrderRow,
          $$PurchaseOrdersTableFilterComposer,
          $$PurchaseOrdersTableOrderingComposer,
          $$PurchaseOrdersTableAnnotationComposer,
          $$PurchaseOrdersTableCreateCompanionBuilder,
          $$PurchaseOrdersTableUpdateCompanionBuilder,
          (PurchaseOrderRow, $$PurchaseOrdersTableReferences),
          PurchaseOrderRow,
          PrefetchHooks Function({bool poItemsRefs})
        > {
  $$PurchaseOrdersTableTableManager(
    _$AppDatabase db,
    $PurchaseOrdersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PurchaseOrdersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PurchaseOrdersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PurchaseOrdersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> poNo = const Value.absent(),
                Value<String> supplier = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> receivedAt = const Value.absent(),
                Value<DateTime?> cancelledAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PurchaseOrdersCompanion(
                id: id,
                poNo: poNo,
                supplier: supplier,
                status: status,
                createdAt: createdAt,
                receivedAt: receivedAt,
                cancelledAt: cancelledAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String poNo,
                required String supplier,
                Value<String> status = const Value.absent(),
                required DateTime createdAt,
                Value<DateTime?> receivedAt = const Value.absent(),
                Value<DateTime?> cancelledAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PurchaseOrdersCompanion.insert(
                id: id,
                poNo: poNo,
                supplier: supplier,
                status: status,
                createdAt: createdAt,
                receivedAt: receivedAt,
                cancelledAt: cancelledAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PurchaseOrdersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({poItemsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (poItemsRefs) db.poItems],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (poItemsRefs)
                    await $_getPrefetchedData<
                      PurchaseOrderRow,
                      $PurchaseOrdersTable,
                      PoItemRow
                    >(
                      currentTable: table,
                      referencedTable: $$PurchaseOrdersTableReferences
                          ._poItemsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$PurchaseOrdersTableReferences(
                            db,
                            table,
                            p0,
                          ).poItemsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.poId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$PurchaseOrdersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PurchaseOrdersTable,
      PurchaseOrderRow,
      $$PurchaseOrdersTableFilterComposer,
      $$PurchaseOrdersTableOrderingComposer,
      $$PurchaseOrdersTableAnnotationComposer,
      $$PurchaseOrdersTableCreateCompanionBuilder,
      $$PurchaseOrdersTableUpdateCompanionBuilder,
      (PurchaseOrderRow, $$PurchaseOrdersTableReferences),
      PurchaseOrderRow,
      PrefetchHooks Function({bool poItemsRefs})
    >;
typedef $$PoItemsTableCreateCompanionBuilder =
    PoItemsCompanion Function({
      Value<int> rowId,
      required String poId,
      required String partNo,
      required String name,
      required int qty,
      required double cost,
    });
typedef $$PoItemsTableUpdateCompanionBuilder =
    PoItemsCompanion Function({
      Value<int> rowId,
      Value<String> poId,
      Value<String> partNo,
      Value<String> name,
      Value<int> qty,
      Value<double> cost,
    });

final class $$PoItemsTableReferences
    extends BaseReferences<_$AppDatabase, $PoItemsTable, PoItemRow> {
  $$PoItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PurchaseOrdersTable _poIdTable(_$AppDatabase db) =>
      db.purchaseOrders.createAlias('po_items__po_id__purchase_orders__id');

  $$PurchaseOrdersTableProcessedTableManager get poId {
    final $_column = $_itemColumn<String>('po_id')!;

    final manager = $$PurchaseOrdersTableTableManager(
      $_db,
      $_db.purchaseOrders,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_poIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PoItemsTableFilterComposer
    extends Composer<_$AppDatabase, $PoItemsTable> {
  $$PoItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnFilters(column),
  );

  $$PurchaseOrdersTableFilterComposer get poId {
    final $$PurchaseOrdersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.poId,
      referencedTable: $db.purchaseOrders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PurchaseOrdersTableFilterComposer(
            $db: $db,
            $table: $db.purchaseOrders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PoItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $PoItemsTable> {
  $$PoItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnOrderings(column),
  );

  $$PurchaseOrdersTableOrderingComposer get poId {
    final $$PurchaseOrdersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.poId,
      referencedTable: $db.purchaseOrders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PurchaseOrdersTableOrderingComposer(
            $db: $db,
            $table: $db.purchaseOrders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PoItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PoItemsTable> {
  $$PoItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get partNo =>
      $composableBuilder(column: $table.partNo, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get qty =>
      $composableBuilder(column: $table.qty, builder: (column) => column);

  GeneratedColumn<double> get cost =>
      $composableBuilder(column: $table.cost, builder: (column) => column);

  $$PurchaseOrdersTableAnnotationComposer get poId {
    final $$PurchaseOrdersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.poId,
      referencedTable: $db.purchaseOrders,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PurchaseOrdersTableAnnotationComposer(
            $db: $db,
            $table: $db.purchaseOrders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PoItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PoItemsTable,
          PoItemRow,
          $$PoItemsTableFilterComposer,
          $$PoItemsTableOrderingComposer,
          $$PoItemsTableAnnotationComposer,
          $$PoItemsTableCreateCompanionBuilder,
          $$PoItemsTableUpdateCompanionBuilder,
          (PoItemRow, $$PoItemsTableReferences),
          PoItemRow,
          PrefetchHooks Function({bool poId})
        > {
  $$PoItemsTableTableManager(_$AppDatabase db, $PoItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PoItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PoItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PoItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                Value<String> poId = const Value.absent(),
                Value<String> partNo = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> qty = const Value.absent(),
                Value<double> cost = const Value.absent(),
              }) => PoItemsCompanion(
                rowId: rowId,
                poId: poId,
                partNo: partNo,
                name: name,
                qty: qty,
                cost: cost,
              ),
          createCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                required String poId,
                required String partNo,
                required String name,
                required int qty,
                required double cost,
              }) => PoItemsCompanion.insert(
                rowId: rowId,
                poId: poId,
                partNo: partNo,
                name: name,
                qty: qty,
                cost: cost,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PoItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({poId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (poId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.poId,
                                referencedTable: $$PoItemsTableReferences
                                    ._poIdTable(db),
                                referencedColumn: $$PoItemsTableReferences
                                    ._poIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PoItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PoItemsTable,
      PoItemRow,
      $$PoItemsTableFilterComposer,
      $$PoItemsTableOrderingComposer,
      $$PoItemsTableAnnotationComposer,
      $$PoItemsTableCreateCompanionBuilder,
      $$PoItemsTableUpdateCompanionBuilder,
      (PoItemRow, $$PoItemsTableReferences),
      PoItemRow,
      PrefetchHooks Function({bool poId})
    >;
typedef $$ReturnsTableCreateCompanionBuilder =
    ReturnsCompanion Function({
      required String id,
      required String cnNo,
      required String saleId,
      required String receiptNo,
      required double refundSubtotal,
      required double refundDiscount,
      required double refundTotal,
      required String refundMethod,
      Value<String> reason,
      Value<String?> customerId,
      Value<String?> mechanicId,
      Value<String?> mechanicName,
      required DateTime date,
      Value<int> rowid,
    });
typedef $$ReturnsTableUpdateCompanionBuilder =
    ReturnsCompanion Function({
      Value<String> id,
      Value<String> cnNo,
      Value<String> saleId,
      Value<String> receiptNo,
      Value<double> refundSubtotal,
      Value<double> refundDiscount,
      Value<double> refundTotal,
      Value<String> refundMethod,
      Value<String> reason,
      Value<String?> customerId,
      Value<String?> mechanicId,
      Value<String?> mechanicName,
      Value<DateTime> date,
      Value<int> rowid,
    });

final class $$ReturnsTableReferences
    extends BaseReferences<_$AppDatabase, $ReturnsTable, ReturnRow> {
  $$ReturnsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ReturnItemsTable, List<ReturnItemRow>>
  _returnItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.returnItems,
    aliasName: 'returns__id__return_items__return_id',
  );

  $$ReturnItemsTableProcessedTableManager get returnItemsRefs {
    final manager = $$ReturnItemsTableTableManager(
      $_db,
      $_db.returnItems,
    ).filter((f) => f.returnId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_returnItemsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ReturnsTableFilterComposer
    extends Composer<_$AppDatabase, $ReturnsTable> {
  $$ReturnsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cnNo => $composableBuilder(
    column: $table.cnNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get saleId => $composableBuilder(
    column: $table.saleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get refundSubtotal => $composableBuilder(
    column: $table.refundSubtotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get refundDiscount => $composableBuilder(
    column: $table.refundDiscount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get refundTotal => $composableBuilder(
    column: $table.refundTotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get refundMethod => $composableBuilder(
    column: $table.refundMethod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> returnItemsRefs(
    Expression<bool> Function($$ReturnItemsTableFilterComposer f) f,
  ) {
    final $$ReturnItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.returnItems,
      getReferencedColumn: (t) => t.returnId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReturnItemsTableFilterComposer(
            $db: $db,
            $table: $db.returnItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ReturnsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReturnsTable> {
  $$ReturnsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cnNo => $composableBuilder(
    column: $table.cnNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get saleId => $composableBuilder(
    column: $table.saleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get refundSubtotal => $composableBuilder(
    column: $table.refundSubtotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get refundDiscount => $composableBuilder(
    column: $table.refundDiscount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get refundTotal => $composableBuilder(
    column: $table.refundTotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get refundMethod => $composableBuilder(
    column: $table.refundMethod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReturnsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReturnsTable> {
  $$ReturnsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get cnNo =>
      $composableBuilder(column: $table.cnNo, builder: (column) => column);

  GeneratedColumn<String> get saleId =>
      $composableBuilder(column: $table.saleId, builder: (column) => column);

  GeneratedColumn<String> get receiptNo =>
      $composableBuilder(column: $table.receiptNo, builder: (column) => column);

  GeneratedColumn<double> get refundSubtotal => $composableBuilder(
    column: $table.refundSubtotal,
    builder: (column) => column,
  );

  GeneratedColumn<double> get refundDiscount => $composableBuilder(
    column: $table.refundDiscount,
    builder: (column) => column,
  );

  GeneratedColumn<double> get refundTotal => $composableBuilder(
    column: $table.refundTotal,
    builder: (column) => column,
  );

  GeneratedColumn<String> get refundMethod => $composableBuilder(
    column: $table.refundMethod,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get customerId => $composableBuilder(
    column: $table.customerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mechanicName => $composableBuilder(
    column: $table.mechanicName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);

  Expression<T> returnItemsRefs<T extends Object>(
    Expression<T> Function($$ReturnItemsTableAnnotationComposer a) f,
  ) {
    final $$ReturnItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.returnItems,
      getReferencedColumn: (t) => t.returnId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReturnItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.returnItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ReturnsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReturnsTable,
          ReturnRow,
          $$ReturnsTableFilterComposer,
          $$ReturnsTableOrderingComposer,
          $$ReturnsTableAnnotationComposer,
          $$ReturnsTableCreateCompanionBuilder,
          $$ReturnsTableUpdateCompanionBuilder,
          (ReturnRow, $$ReturnsTableReferences),
          ReturnRow,
          PrefetchHooks Function({bool returnItemsRefs})
        > {
  $$ReturnsTableTableManager(_$AppDatabase db, $ReturnsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReturnsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReturnsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReturnsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> cnNo = const Value.absent(),
                Value<String> saleId = const Value.absent(),
                Value<String> receiptNo = const Value.absent(),
                Value<double> refundSubtotal = const Value.absent(),
                Value<double> refundDiscount = const Value.absent(),
                Value<double> refundTotal = const Value.absent(),
                Value<String> refundMethod = const Value.absent(),
                Value<String> reason = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> mechanicId = const Value.absent(),
                Value<String?> mechanicName = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReturnsCompanion(
                id: id,
                cnNo: cnNo,
                saleId: saleId,
                receiptNo: receiptNo,
                refundSubtotal: refundSubtotal,
                refundDiscount: refundDiscount,
                refundTotal: refundTotal,
                refundMethod: refundMethod,
                reason: reason,
                customerId: customerId,
                mechanicId: mechanicId,
                mechanicName: mechanicName,
                date: date,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String cnNo,
                required String saleId,
                required String receiptNo,
                required double refundSubtotal,
                required double refundDiscount,
                required double refundTotal,
                required String refundMethod,
                Value<String> reason = const Value.absent(),
                Value<String?> customerId = const Value.absent(),
                Value<String?> mechanicId = const Value.absent(),
                Value<String?> mechanicName = const Value.absent(),
                required DateTime date,
                Value<int> rowid = const Value.absent(),
              }) => ReturnsCompanion.insert(
                id: id,
                cnNo: cnNo,
                saleId: saleId,
                receiptNo: receiptNo,
                refundSubtotal: refundSubtotal,
                refundDiscount: refundDiscount,
                refundTotal: refundTotal,
                refundMethod: refundMethod,
                reason: reason,
                customerId: customerId,
                mechanicId: mechanicId,
                mechanicName: mechanicName,
                date: date,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ReturnsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({returnItemsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (returnItemsRefs) db.returnItems],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (returnItemsRefs)
                    await $_getPrefetchedData<
                      ReturnRow,
                      $ReturnsTable,
                      ReturnItemRow
                    >(
                      currentTable: table,
                      referencedTable: $$ReturnsTableReferences
                          ._returnItemsRefsTable(db),
                      managerFromTypedResult: (p0) => $$ReturnsTableReferences(
                        db,
                        table,
                        p0,
                      ).returnItemsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.returnId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ReturnsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReturnsTable,
      ReturnRow,
      $$ReturnsTableFilterComposer,
      $$ReturnsTableOrderingComposer,
      $$ReturnsTableAnnotationComposer,
      $$ReturnsTableCreateCompanionBuilder,
      $$ReturnsTableUpdateCompanionBuilder,
      (ReturnRow, $$ReturnsTableReferences),
      ReturnRow,
      PrefetchHooks Function({bool returnItemsRefs})
    >;
typedef $$ReturnItemsTableCreateCompanionBuilder =
    ReturnItemsCompanion Function({
      Value<int> rowId,
      required String returnId,
      required String productId,
      required String name,
      required int qty,
      required double price,
      Value<int?> originalQty,
    });
typedef $$ReturnItemsTableUpdateCompanionBuilder =
    ReturnItemsCompanion Function({
      Value<int> rowId,
      Value<String> returnId,
      Value<String> productId,
      Value<String> name,
      Value<int> qty,
      Value<double> price,
      Value<int?> originalQty,
    });

final class $$ReturnItemsTableReferences
    extends BaseReferences<_$AppDatabase, $ReturnItemsTable, ReturnItemRow> {
  $$ReturnItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ReturnsTable _returnIdTable(_$AppDatabase db) =>
      db.returns.createAlias('return_items__return_id__returns__id');

  $$ReturnsTableProcessedTableManager get returnId {
    final $_column = $_itemColumn<String>('return_id')!;

    final manager = $$ReturnsTableTableManager(
      $_db,
      $_db.returns,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_returnIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ReturnItemsTableFilterComposer
    extends Composer<_$AppDatabase, $ReturnItemsTable> {
  $$ReturnItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get originalQty => $composableBuilder(
    column: $table.originalQty,
    builder: (column) => ColumnFilters(column),
  );

  $$ReturnsTableFilterComposer get returnId {
    final $$ReturnsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.returnId,
      referencedTable: $db.returns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReturnsTableFilterComposer(
            $db: $db,
            $table: $db.returns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReturnItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReturnItemsTable> {
  $$ReturnItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get originalQty => $composableBuilder(
    column: $table.originalQty,
    builder: (column) => ColumnOrderings(column),
  );

  $$ReturnsTableOrderingComposer get returnId {
    final $$ReturnsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.returnId,
      referencedTable: $db.returns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReturnsTableOrderingComposer(
            $db: $db,
            $table: $db.returns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReturnItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReturnItemsTable> {
  $$ReturnItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get qty =>
      $composableBuilder(column: $table.qty, builder: (column) => column);

  GeneratedColumn<double> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<int> get originalQty => $composableBuilder(
    column: $table.originalQty,
    builder: (column) => column,
  );

  $$ReturnsTableAnnotationComposer get returnId {
    final $$ReturnsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.returnId,
      referencedTable: $db.returns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReturnsTableAnnotationComposer(
            $db: $db,
            $table: $db.returns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReturnItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReturnItemsTable,
          ReturnItemRow,
          $$ReturnItemsTableFilterComposer,
          $$ReturnItemsTableOrderingComposer,
          $$ReturnItemsTableAnnotationComposer,
          $$ReturnItemsTableCreateCompanionBuilder,
          $$ReturnItemsTableUpdateCompanionBuilder,
          (ReturnItemRow, $$ReturnItemsTableReferences),
          ReturnItemRow,
          PrefetchHooks Function({bool returnId})
        > {
  $$ReturnItemsTableTableManager(_$AppDatabase db, $ReturnItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReturnItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReturnItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReturnItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                Value<String> returnId = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> qty = const Value.absent(),
                Value<double> price = const Value.absent(),
                Value<int?> originalQty = const Value.absent(),
              }) => ReturnItemsCompanion(
                rowId: rowId,
                returnId: returnId,
                productId: productId,
                name: name,
                qty: qty,
                price: price,
                originalQty: originalQty,
              ),
          createCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                required String returnId,
                required String productId,
                required String name,
                required int qty,
                required double price,
                Value<int?> originalQty = const Value.absent(),
              }) => ReturnItemsCompanion.insert(
                rowId: rowId,
                returnId: returnId,
                productId: productId,
                name: name,
                qty: qty,
                price: price,
                originalQty: originalQty,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ReturnItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({returnId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (returnId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.returnId,
                                referencedTable: $$ReturnItemsTableReferences
                                    ._returnIdTable(db),
                                referencedColumn: $$ReturnItemsTableReferences
                                    ._returnIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ReturnItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReturnItemsTable,
      ReturnItemRow,
      $$ReturnItemsTableFilterComposer,
      $$ReturnItemsTableOrderingComposer,
      $$ReturnItemsTableAnnotationComposer,
      $$ReturnItemsTableCreateCompanionBuilder,
      $$ReturnItemsTableUpdateCompanionBuilder,
      (ReturnItemRow, $$ReturnItemsTableReferences),
      ReturnItemRow,
      PrefetchHooks Function({bool returnId})
    >;
typedef $$QuotesTableCreateCompanionBuilder =
    QuotesCompanion Function({
      required String id,
      required String quoteNo,
      Value<String> status,
      required DateTime date,
      required DateTime validUntil,
      Value<DateTime?> convertedAt,
      Value<double?> subtotal,
      Value<double?> discount,
      Value<double?> total,
      Value<String?> customerName,
      Value<String?> customerPhone,
      Value<String?> notes,
      Value<int?> validDays,
      Value<int> rowid,
    });
typedef $$QuotesTableUpdateCompanionBuilder =
    QuotesCompanion Function({
      Value<String> id,
      Value<String> quoteNo,
      Value<String> status,
      Value<DateTime> date,
      Value<DateTime> validUntil,
      Value<DateTime?> convertedAt,
      Value<double?> subtotal,
      Value<double?> discount,
      Value<double?> total,
      Value<String?> customerName,
      Value<String?> customerPhone,
      Value<String?> notes,
      Value<int?> validDays,
      Value<int> rowid,
    });

final class $$QuotesTableReferences
    extends BaseReferences<_$AppDatabase, $QuotesTable, QuoteRow> {
  $$QuotesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$QuoteItemsTable, List<QuoteItemRow>>
  _quoteItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.quoteItems,
    aliasName: 'quotes__id__quote_items__quote_id',
  );

  $$QuoteItemsTableProcessedTableManager get quoteItemsRefs {
    final manager = $$QuoteItemsTableTableManager(
      $_db,
      $_db.quoteItems,
    ).filter((f) => f.quoteId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_quoteItemsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$QuotesTableFilterComposer
    extends Composer<_$AppDatabase, $QuotesTable> {
  $$QuotesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get quoteNo => $composableBuilder(
    column: $table.quoteNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get validUntil => $composableBuilder(
    column: $table.validUntil,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get convertedAt => $composableBuilder(
    column: $table.convertedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get subtotal => $composableBuilder(
    column: $table.subtotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get discount => $composableBuilder(
    column: $table.discount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customerPhone => $composableBuilder(
    column: $table.customerPhone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get validDays => $composableBuilder(
    column: $table.validDays,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> quoteItemsRefs(
    Expression<bool> Function($$QuoteItemsTableFilterComposer f) f,
  ) {
    final $$QuoteItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.quoteItems,
      getReferencedColumn: (t) => t.quoteId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$QuoteItemsTableFilterComposer(
            $db: $db,
            $table: $db.quoteItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$QuotesTableOrderingComposer
    extends Composer<_$AppDatabase, $QuotesTable> {
  $$QuotesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get quoteNo => $composableBuilder(
    column: $table.quoteNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get validUntil => $composableBuilder(
    column: $table.validUntil,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get convertedAt => $composableBuilder(
    column: $table.convertedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get subtotal => $composableBuilder(
    column: $table.subtotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get discount => $composableBuilder(
    column: $table.discount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customerPhone => $composableBuilder(
    column: $table.customerPhone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get validDays => $composableBuilder(
    column: $table.validDays,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuotesTableAnnotationComposer
    extends Composer<_$AppDatabase, $QuotesTable> {
  $$QuotesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get quoteNo =>
      $composableBuilder(column: $table.quoteNo, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);

  GeneratedColumn<DateTime> get validUntil => $composableBuilder(
    column: $table.validUntil,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get convertedAt => $composableBuilder(
    column: $table.convertedAt,
    builder: (column) => column,
  );

  GeneratedColumn<double> get subtotal =>
      $composableBuilder(column: $table.subtotal, builder: (column) => column);

  GeneratedColumn<double> get discount =>
      $composableBuilder(column: $table.discount, builder: (column) => column);

  GeneratedColumn<double> get total =>
      $composableBuilder(column: $table.total, builder: (column) => column);

  GeneratedColumn<String> get customerName => $composableBuilder(
    column: $table.customerName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get customerPhone => $composableBuilder(
    column: $table.customerPhone,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<int> get validDays =>
      $composableBuilder(column: $table.validDays, builder: (column) => column);

  Expression<T> quoteItemsRefs<T extends Object>(
    Expression<T> Function($$QuoteItemsTableAnnotationComposer a) f,
  ) {
    final $$QuoteItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.quoteItems,
      getReferencedColumn: (t) => t.quoteId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$QuoteItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.quoteItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$QuotesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $QuotesTable,
          QuoteRow,
          $$QuotesTableFilterComposer,
          $$QuotesTableOrderingComposer,
          $$QuotesTableAnnotationComposer,
          $$QuotesTableCreateCompanionBuilder,
          $$QuotesTableUpdateCompanionBuilder,
          (QuoteRow, $$QuotesTableReferences),
          QuoteRow,
          PrefetchHooks Function({bool quoteItemsRefs})
        > {
  $$QuotesTableTableManager(_$AppDatabase db, $QuotesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuotesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuotesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuotesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> quoteNo = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<DateTime> validUntil = const Value.absent(),
                Value<DateTime?> convertedAt = const Value.absent(),
                Value<double?> subtotal = const Value.absent(),
                Value<double?> discount = const Value.absent(),
                Value<double?> total = const Value.absent(),
                Value<String?> customerName = const Value.absent(),
                Value<String?> customerPhone = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int?> validDays = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuotesCompanion(
                id: id,
                quoteNo: quoteNo,
                status: status,
                date: date,
                validUntil: validUntil,
                convertedAt: convertedAt,
                subtotal: subtotal,
                discount: discount,
                total: total,
                customerName: customerName,
                customerPhone: customerPhone,
                notes: notes,
                validDays: validDays,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String quoteNo,
                Value<String> status = const Value.absent(),
                required DateTime date,
                required DateTime validUntil,
                Value<DateTime?> convertedAt = const Value.absent(),
                Value<double?> subtotal = const Value.absent(),
                Value<double?> discount = const Value.absent(),
                Value<double?> total = const Value.absent(),
                Value<String?> customerName = const Value.absent(),
                Value<String?> customerPhone = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int?> validDays = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuotesCompanion.insert(
                id: id,
                quoteNo: quoteNo,
                status: status,
                date: date,
                validUntil: validUntil,
                convertedAt: convertedAt,
                subtotal: subtotal,
                discount: discount,
                total: total,
                customerName: customerName,
                customerPhone: customerPhone,
                notes: notes,
                validDays: validDays,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$QuotesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({quoteItemsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (quoteItemsRefs) db.quoteItems],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (quoteItemsRefs)
                    await $_getPrefetchedData<
                      QuoteRow,
                      $QuotesTable,
                      QuoteItemRow
                    >(
                      currentTable: table,
                      referencedTable: $$QuotesTableReferences
                          ._quoteItemsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$QuotesTableReferences(db, table, p0).quoteItemsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.quoteId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$QuotesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $QuotesTable,
      QuoteRow,
      $$QuotesTableFilterComposer,
      $$QuotesTableOrderingComposer,
      $$QuotesTableAnnotationComposer,
      $$QuotesTableCreateCompanionBuilder,
      $$QuotesTableUpdateCompanionBuilder,
      (QuoteRow, $$QuotesTableReferences),
      QuoteRow,
      PrefetchHooks Function({bool quoteItemsRefs})
    >;
typedef $$QuoteItemsTableCreateCompanionBuilder =
    QuoteItemsCompanion Function({
      Value<int> rowId,
      required String quoteId,
      Value<String?> productId,
      required String name,
      required int qty,
      required double price,
      Value<double?> costAtSale,
    });
typedef $$QuoteItemsTableUpdateCompanionBuilder =
    QuoteItemsCompanion Function({
      Value<int> rowId,
      Value<String> quoteId,
      Value<String?> productId,
      Value<String> name,
      Value<int> qty,
      Value<double> price,
      Value<double?> costAtSale,
    });

final class $$QuoteItemsTableReferences
    extends BaseReferences<_$AppDatabase, $QuoteItemsTable, QuoteItemRow> {
  $$QuoteItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $QuotesTable _quoteIdTable(_$AppDatabase db) =>
      db.quotes.createAlias('quote_items__quote_id__quotes__id');

  $$QuotesTableProcessedTableManager get quoteId {
    final $_column = $_itemColumn<String>('quote_id')!;

    final manager = $$QuotesTableTableManager(
      $_db,
      $_db.quotes,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_quoteIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$QuoteItemsTableFilterComposer
    extends Composer<_$AppDatabase, $QuoteItemsTable> {
  $$QuoteItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => ColumnFilters(column),
  );

  $$QuotesTableFilterComposer get quoteId {
    final $$QuotesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.quoteId,
      referencedTable: $db.quotes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$QuotesTableFilterComposer(
            $db: $db,
            $table: $db.quotes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$QuoteItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $QuoteItemsTable> {
  $$QuoteItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get qty => $composableBuilder(
    column: $table.qty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get price => $composableBuilder(
    column: $table.price,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => ColumnOrderings(column),
  );

  $$QuotesTableOrderingComposer get quoteId {
    final $$QuotesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.quoteId,
      referencedTable: $db.quotes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$QuotesTableOrderingComposer(
            $db: $db,
            $table: $db.quotes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$QuoteItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $QuoteItemsTable> {
  $$QuoteItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get qty =>
      $composableBuilder(column: $table.qty, builder: (column) => column);

  GeneratedColumn<double> get price =>
      $composableBuilder(column: $table.price, builder: (column) => column);

  GeneratedColumn<double> get costAtSale => $composableBuilder(
    column: $table.costAtSale,
    builder: (column) => column,
  );

  $$QuotesTableAnnotationComposer get quoteId {
    final $$QuotesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.quoteId,
      referencedTable: $db.quotes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$QuotesTableAnnotationComposer(
            $db: $db,
            $table: $db.quotes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$QuoteItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $QuoteItemsTable,
          QuoteItemRow,
          $$QuoteItemsTableFilterComposer,
          $$QuoteItemsTableOrderingComposer,
          $$QuoteItemsTableAnnotationComposer,
          $$QuoteItemsTableCreateCompanionBuilder,
          $$QuoteItemsTableUpdateCompanionBuilder,
          (QuoteItemRow, $$QuoteItemsTableReferences),
          QuoteItemRow,
          PrefetchHooks Function({bool quoteId})
        > {
  $$QuoteItemsTableTableManager(_$AppDatabase db, $QuoteItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuoteItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuoteItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuoteItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                Value<String> quoteId = const Value.absent(),
                Value<String?> productId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> qty = const Value.absent(),
                Value<double> price = const Value.absent(),
                Value<double?> costAtSale = const Value.absent(),
              }) => QuoteItemsCompanion(
                rowId: rowId,
                quoteId: quoteId,
                productId: productId,
                name: name,
                qty: qty,
                price: price,
                costAtSale: costAtSale,
              ),
          createCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                required String quoteId,
                Value<String?> productId = const Value.absent(),
                required String name,
                required int qty,
                required double price,
                Value<double?> costAtSale = const Value.absent(),
              }) => QuoteItemsCompanion.insert(
                rowId: rowId,
                quoteId: quoteId,
                productId: productId,
                name: name,
                qty: qty,
                price: price,
                costAtSale: costAtSale,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$QuoteItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({quoteId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (quoteId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.quoteId,
                                referencedTable: $$QuoteItemsTableReferences
                                    ._quoteIdTable(db),
                                referencedColumn: $$QuoteItemsTableReferences
                                    ._quoteIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$QuoteItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $QuoteItemsTable,
      QuoteItemRow,
      $$QuoteItemsTableFilterComposer,
      $$QuoteItemsTableOrderingComposer,
      $$QuoteItemsTableAnnotationComposer,
      $$QuoteItemsTableCreateCompanionBuilder,
      $$QuoteItemsTableUpdateCompanionBuilder,
      (QuoteItemRow, $$QuoteItemsTableReferences),
      QuoteItemRow,
      PrefetchHooks Function({bool quoteId})
    >;
typedef $$MovementsTableCreateCompanionBuilder =
    MovementsCompanion Function({
      required String id,
      required String productId,
      required String partNo,
      required String name,
      required int delta,
      required String type,
      Value<String?> note,
      required int stockAfter,
      required DateTime date,
      Value<int> rowid,
    });
typedef $$MovementsTableUpdateCompanionBuilder =
    MovementsCompanion Function({
      Value<String> id,
      Value<String> productId,
      Value<String> partNo,
      Value<String> name,
      Value<int> delta,
      Value<String> type,
      Value<String?> note,
      Value<int> stockAfter,
      Value<DateTime> date,
      Value<int> rowid,
    });

class $$MovementsTableFilterComposer
    extends Composer<_$AppDatabase, $MovementsTable> {
  $$MovementsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get delta => $composableBuilder(
    column: $table.delta,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stockAfter => $composableBuilder(
    column: $table.stockAfter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MovementsTableOrderingComposer
    extends Composer<_$AppDatabase, $MovementsTable> {
  $$MovementsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partNo => $composableBuilder(
    column: $table.partNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get delta => $composableBuilder(
    column: $table.delta,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stockAfter => $composableBuilder(
    column: $table.stockAfter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MovementsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MovementsTable> {
  $$MovementsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get partNo =>
      $composableBuilder(column: $table.partNo, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get delta =>
      $composableBuilder(column: $table.delta, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get stockAfter => $composableBuilder(
    column: $table.stockAfter,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);
}

class $$MovementsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MovementsTable,
          MovementRow,
          $$MovementsTableFilterComposer,
          $$MovementsTableOrderingComposer,
          $$MovementsTableAnnotationComposer,
          $$MovementsTableCreateCompanionBuilder,
          $$MovementsTableUpdateCompanionBuilder,
          (
            MovementRow,
            BaseReferences<_$AppDatabase, $MovementsTable, MovementRow>,
          ),
          MovementRow,
          PrefetchHooks Function()
        > {
  $$MovementsTableTableManager(_$AppDatabase db, $MovementsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MovementsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MovementsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MovementsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String> partNo = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> delta = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<int> stockAfter = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MovementsCompanion(
                id: id,
                productId: productId,
                partNo: partNo,
                name: name,
                delta: delta,
                type: type,
                note: note,
                stockAfter: stockAfter,
                date: date,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productId,
                required String partNo,
                required String name,
                required int delta,
                required String type,
                Value<String?> note = const Value.absent(),
                required int stockAfter,
                required DateTime date,
                Value<int> rowid = const Value.absent(),
              }) => MovementsCompanion.insert(
                id: id,
                productId: productId,
                partNo: partNo,
                name: name,
                delta: delta,
                type: type,
                note: note,
                stockAfter: stockAfter,
                date: date,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MovementsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MovementsTable,
      MovementRow,
      $$MovementsTableFilterComposer,
      $$MovementsTableOrderingComposer,
      $$MovementsTableAnnotationComposer,
      $$MovementsTableCreateCompanionBuilder,
      $$MovementsTableUpdateCompanionBuilder,
      (
        MovementRow,
        BaseReferences<_$AppDatabase, $MovementsTable, MovementRow>,
      ),
      MovementRow,
      PrefetchHooks Function()
    >;
typedef $$SuppliersTableCreateCompanionBuilder =
    SuppliersCompanion Function({
      required String id,
      required String productId,
      required String name,
      required double unitCost,
      Value<double> freight,
      Value<int> rowid,
    });
typedef $$SuppliersTableUpdateCompanionBuilder =
    SuppliersCompanion Function({
      Value<String> id,
      Value<String> productId,
      Value<String> name,
      Value<double> unitCost,
      Value<double> freight,
      Value<int> rowid,
    });

class $$SuppliersTableFilterComposer
    extends Composer<_$AppDatabase, $SuppliersTable> {
  $$SuppliersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get unitCost => $composableBuilder(
    column: $table.unitCost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get freight => $composableBuilder(
    column: $table.freight,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SuppliersTableOrderingComposer
    extends Composer<_$AppDatabase, $SuppliersTable> {
  $$SuppliersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get productId => $composableBuilder(
    column: $table.productId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get unitCost => $composableBuilder(
    column: $table.unitCost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get freight => $composableBuilder(
    column: $table.freight,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SuppliersTableAnnotationComposer
    extends Composer<_$AppDatabase, $SuppliersTable> {
  $$SuppliersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get productId =>
      $composableBuilder(column: $table.productId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<double> get unitCost =>
      $composableBuilder(column: $table.unitCost, builder: (column) => column);

  GeneratedColumn<double> get freight =>
      $composableBuilder(column: $table.freight, builder: (column) => column);
}

class $$SuppliersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SuppliersTable,
          SupplierRow,
          $$SuppliersTableFilterComposer,
          $$SuppliersTableOrderingComposer,
          $$SuppliersTableAnnotationComposer,
          $$SuppliersTableCreateCompanionBuilder,
          $$SuppliersTableUpdateCompanionBuilder,
          (
            SupplierRow,
            BaseReferences<_$AppDatabase, $SuppliersTable, SupplierRow>,
          ),
          SupplierRow,
          PrefetchHooks Function()
        > {
  $$SuppliersTableTableManager(_$AppDatabase db, $SuppliersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SuppliersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SuppliersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SuppliersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<double> unitCost = const Value.absent(),
                Value<double> freight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SuppliersCompanion(
                id: id,
                productId: productId,
                name: name,
                unitCost: unitCost,
                freight: freight,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productId,
                required String name,
                required double unitCost,
                Value<double> freight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SuppliersCompanion.insert(
                id: id,
                productId: productId,
                name: name,
                unitCost: unitCost,
                freight: freight,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SuppliersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SuppliersTable,
      SupplierRow,
      $$SuppliersTableFilterComposer,
      $$SuppliersTableOrderingComposer,
      $$SuppliersTableAnnotationComposer,
      $$SuppliersTableCreateCompanionBuilder,
      $$SuppliersTableUpdateCompanionBuilder,
      (
        SupplierRow,
        BaseReferences<_$AppDatabase, $SuppliersTable, SupplierRow>,
      ),
      SupplierRow,
      PrefetchHooks Function()
    >;
typedef $$CreditPaymentsTableCreateCompanionBuilder =
    CreditPaymentsCompanion Function({
      required String id,
      required String receiptNo,
      required String mechanicId,
      required double amount,
      required DateTime date,
      Value<String?> note,
      Value<int> rowid,
    });
typedef $$CreditPaymentsTableUpdateCompanionBuilder =
    CreditPaymentsCompanion Function({
      Value<String> id,
      Value<String> receiptNo,
      Value<String> mechanicId,
      Value<double> amount,
      Value<DateTime> date,
      Value<String?> note,
      Value<int> rowid,
    });

class $$CreditPaymentsTableFilterComposer
    extends Composer<_$AppDatabase, $CreditPaymentsTable> {
  $$CreditPaymentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CreditPaymentsTableOrderingComposer
    extends Composer<_$AppDatabase, $CreditPaymentsTable> {
  $$CreditPaymentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiptNo => $composableBuilder(
    column: $table.receiptNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CreditPaymentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CreditPaymentsTable> {
  $$CreditPaymentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get receiptNo =>
      $composableBuilder(column: $table.receiptNo, builder: (column) => column);

  GeneratedColumn<String> get mechanicId => $composableBuilder(
    column: $table.mechanicId,
    builder: (column) => column,
  );

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);
}

class $$CreditPaymentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CreditPaymentsTable,
          CreditPaymentRow,
          $$CreditPaymentsTableFilterComposer,
          $$CreditPaymentsTableOrderingComposer,
          $$CreditPaymentsTableAnnotationComposer,
          $$CreditPaymentsTableCreateCompanionBuilder,
          $$CreditPaymentsTableUpdateCompanionBuilder,
          (
            CreditPaymentRow,
            BaseReferences<
              _$AppDatabase,
              $CreditPaymentsTable,
              CreditPaymentRow
            >,
          ),
          CreditPaymentRow,
          PrefetchHooks Function()
        > {
  $$CreditPaymentsTableTableManager(
    _$AppDatabase db,
    $CreditPaymentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CreditPaymentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CreditPaymentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CreditPaymentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> receiptNo = const Value.absent(),
                Value<String> mechanicId = const Value.absent(),
                Value<double> amount = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CreditPaymentsCompanion(
                id: id,
                receiptNo: receiptNo,
                mechanicId: mechanicId,
                amount: amount,
                date: date,
                note: note,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String receiptNo,
                required String mechanicId,
                required double amount,
                required DateTime date,
                Value<String?> note = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CreditPaymentsCompanion.insert(
                id: id,
                receiptNo: receiptNo,
                mechanicId: mechanicId,
                amount: amount,
                date: date,
                note: note,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CreditPaymentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CreditPaymentsTable,
      CreditPaymentRow,
      $$CreditPaymentsTableFilterComposer,
      $$CreditPaymentsTableOrderingComposer,
      $$CreditPaymentsTableAnnotationComposer,
      $$CreditPaymentsTableCreateCompanionBuilder,
      $$CreditPaymentsTableUpdateCompanionBuilder,
      (
        CreditPaymentRow,
        BaseReferences<_$AppDatabase, $CreditPaymentsTable, CreditPaymentRow>,
      ),
      CreditPaymentRow,
      PrefetchHooks Function()
    >;
typedef $$ShiftsTableCreateCompanionBuilder =
    ShiftsCompanion Function({
      required String id,
      required String dateStr,
      required double startingCash,
      required DateTime openedAt,
      Value<DateTime?> closedAt,
      Value<double?> physicalCash,
      Value<bool> isActive,
      Value<bool> autoArchived,
      Value<DateTime?> archivedAt,
      Value<int> rowid,
    });
typedef $$ShiftsTableUpdateCompanionBuilder =
    ShiftsCompanion Function({
      Value<String> id,
      Value<String> dateStr,
      Value<double> startingCash,
      Value<DateTime> openedAt,
      Value<DateTime?> closedAt,
      Value<double?> physicalCash,
      Value<bool> isActive,
      Value<bool> autoArchived,
      Value<DateTime?> archivedAt,
      Value<int> rowid,
    });

final class $$ShiftsTableReferences
    extends BaseReferences<_$AppDatabase, $ShiftsTable, ShiftRow> {
  $$ShiftsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$DrawerEntriesTable, List<DrawerEntryRow>>
  _drawerEntriesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.drawerEntries,
    aliasName: 'shifts__id__drawer_entries__shift_id',
  );

  $$DrawerEntriesTableProcessedTableManager get drawerEntriesRefs {
    final manager = $$DrawerEntriesTableTableManager(
      $_db,
      $_db.drawerEntries,
    ).filter((f) => f.shiftId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_drawerEntriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ShiftsTableFilterComposer
    extends Composer<_$AppDatabase, $ShiftsTable> {
  $$ShiftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dateStr => $composableBuilder(
    column: $table.dateStr,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get startingCash => $composableBuilder(
    column: $table.startingCash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get openedAt => $composableBuilder(
    column: $table.openedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get closedAt => $composableBuilder(
    column: $table.closedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get physicalCash => $composableBuilder(
    column: $table.physicalCash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoArchived => $composableBuilder(
    column: $table.autoArchived,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> drawerEntriesRefs(
    Expression<bool> Function($$DrawerEntriesTableFilterComposer f) f,
  ) {
    final $$DrawerEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.drawerEntries,
      getReferencedColumn: (t) => t.shiftId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DrawerEntriesTableFilterComposer(
            $db: $db,
            $table: $db.drawerEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ShiftsTableOrderingComposer
    extends Composer<_$AppDatabase, $ShiftsTable> {
  $$ShiftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dateStr => $composableBuilder(
    column: $table.dateStr,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get startingCash => $composableBuilder(
    column: $table.startingCash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get openedAt => $composableBuilder(
    column: $table.openedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get closedAt => $composableBuilder(
    column: $table.closedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get physicalCash => $composableBuilder(
    column: $table.physicalCash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoArchived => $composableBuilder(
    column: $table.autoArchived,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ShiftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ShiftsTable> {
  $$ShiftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get dateStr =>
      $composableBuilder(column: $table.dateStr, builder: (column) => column);

  GeneratedColumn<double> get startingCash => $composableBuilder(
    column: $table.startingCash,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get openedAt =>
      $composableBuilder(column: $table.openedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get closedAt =>
      $composableBuilder(column: $table.closedAt, builder: (column) => column);

  GeneratedColumn<double> get physicalCash => $composableBuilder(
    column: $table.physicalCash,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<bool> get autoArchived => $composableBuilder(
    column: $table.autoArchived,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => column,
  );

  Expression<T> drawerEntriesRefs<T extends Object>(
    Expression<T> Function($$DrawerEntriesTableAnnotationComposer a) f,
  ) {
    final $$DrawerEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.drawerEntries,
      getReferencedColumn: (t) => t.shiftId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DrawerEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.drawerEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ShiftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ShiftsTable,
          ShiftRow,
          $$ShiftsTableFilterComposer,
          $$ShiftsTableOrderingComposer,
          $$ShiftsTableAnnotationComposer,
          $$ShiftsTableCreateCompanionBuilder,
          $$ShiftsTableUpdateCompanionBuilder,
          (ShiftRow, $$ShiftsTableReferences),
          ShiftRow,
          PrefetchHooks Function({bool drawerEntriesRefs})
        > {
  $$ShiftsTableTableManager(_$AppDatabase db, $ShiftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ShiftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ShiftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ShiftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> dateStr = const Value.absent(),
                Value<double> startingCash = const Value.absent(),
                Value<DateTime> openedAt = const Value.absent(),
                Value<DateTime?> closedAt = const Value.absent(),
                Value<double?> physicalCash = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<bool> autoArchived = const Value.absent(),
                Value<DateTime?> archivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ShiftsCompanion(
                id: id,
                dateStr: dateStr,
                startingCash: startingCash,
                openedAt: openedAt,
                closedAt: closedAt,
                physicalCash: physicalCash,
                isActive: isActive,
                autoArchived: autoArchived,
                archivedAt: archivedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String dateStr,
                required double startingCash,
                required DateTime openedAt,
                Value<DateTime?> closedAt = const Value.absent(),
                Value<double?> physicalCash = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<bool> autoArchived = const Value.absent(),
                Value<DateTime?> archivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ShiftsCompanion.insert(
                id: id,
                dateStr: dateStr,
                startingCash: startingCash,
                openedAt: openedAt,
                closedAt: closedAt,
                physicalCash: physicalCash,
                isActive: isActive,
                autoArchived: autoArchived,
                archivedAt: archivedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$ShiftsTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({drawerEntriesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (drawerEntriesRefs) db.drawerEntries,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (drawerEntriesRefs)
                    await $_getPrefetchedData<
                      ShiftRow,
                      $ShiftsTable,
                      DrawerEntryRow
                    >(
                      currentTable: table,
                      referencedTable: $$ShiftsTableReferences
                          ._drawerEntriesRefsTable(db),
                      managerFromTypedResult: (p0) => $$ShiftsTableReferences(
                        db,
                        table,
                        p0,
                      ).drawerEntriesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.shiftId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ShiftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ShiftsTable,
      ShiftRow,
      $$ShiftsTableFilterComposer,
      $$ShiftsTableOrderingComposer,
      $$ShiftsTableAnnotationComposer,
      $$ShiftsTableCreateCompanionBuilder,
      $$ShiftsTableUpdateCompanionBuilder,
      (ShiftRow, $$ShiftsTableReferences),
      ShiftRow,
      PrefetchHooks Function({bool drawerEntriesRefs})
    >;
typedef $$DrawerEntriesTableCreateCompanionBuilder =
    DrawerEntriesCompanion Function({
      required String id,
      required String shiftId,
      required String type,
      required double amount,
      Value<String?> note,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$DrawerEntriesTableUpdateCompanionBuilder =
    DrawerEntriesCompanion Function({
      Value<String> id,
      Value<String> shiftId,
      Value<String> type,
      Value<double> amount,
      Value<String?> note,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$DrawerEntriesTableReferences
    extends BaseReferences<_$AppDatabase, $DrawerEntriesTable, DrawerEntryRow> {
  $$DrawerEntriesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ShiftsTable _shiftIdTable(_$AppDatabase db) =>
      db.shifts.createAlias('drawer_entries__shift_id__shifts__id');

  $$ShiftsTableProcessedTableManager get shiftId {
    final $_column = $_itemColumn<String>('shift_id')!;

    final manager = $$ShiftsTableTableManager(
      $_db,
      $_db.shifts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_shiftIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$DrawerEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $DrawerEntriesTable> {
  $$DrawerEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$ShiftsTableFilterComposer get shiftId {
    final $$ShiftsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.shiftId,
      referencedTable: $db.shifts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ShiftsTableFilterComposer(
            $db: $db,
            $table: $db.shifts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DrawerEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $DrawerEntriesTable> {
  $$DrawerEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$ShiftsTableOrderingComposer get shiftId {
    final $$ShiftsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.shiftId,
      referencedTable: $db.shifts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ShiftsTableOrderingComposer(
            $db: $db,
            $table: $db.shifts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DrawerEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $DrawerEntriesTable> {
  $$DrawerEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$ShiftsTableAnnotationComposer get shiftId {
    final $$ShiftsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.shiftId,
      referencedTable: $db.shifts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ShiftsTableAnnotationComposer(
            $db: $db,
            $table: $db.shifts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DrawerEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DrawerEntriesTable,
          DrawerEntryRow,
          $$DrawerEntriesTableFilterComposer,
          $$DrawerEntriesTableOrderingComposer,
          $$DrawerEntriesTableAnnotationComposer,
          $$DrawerEntriesTableCreateCompanionBuilder,
          $$DrawerEntriesTableUpdateCompanionBuilder,
          (DrawerEntryRow, $$DrawerEntriesTableReferences),
          DrawerEntryRow,
          PrefetchHooks Function({bool shiftId})
        > {
  $$DrawerEntriesTableTableManager(_$AppDatabase db, $DrawerEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DrawerEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DrawerEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DrawerEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> shiftId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<double> amount = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DrawerEntriesCompanion(
                id: id,
                shiftId: shiftId,
                type: type,
                amount: amount,
                note: note,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String shiftId,
                required String type,
                required double amount,
                Value<String?> note = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => DrawerEntriesCompanion.insert(
                id: id,
                shiftId: shiftId,
                type: type,
                amount: amount,
                note: note,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$DrawerEntriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({shiftId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (shiftId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.shiftId,
                                referencedTable: $$DrawerEntriesTableReferences
                                    ._shiftIdTable(db),
                                referencedColumn: $$DrawerEntriesTableReferences
                                    ._shiftIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$DrawerEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DrawerEntriesTable,
      DrawerEntryRow,
      $$DrawerEntriesTableFilterComposer,
      $$DrawerEntriesTableOrderingComposer,
      $$DrawerEntriesTableAnnotationComposer,
      $$DrawerEntriesTableCreateCompanionBuilder,
      $$DrawerEntriesTableUpdateCompanionBuilder,
      (DrawerEntryRow, $$DrawerEntriesTableReferences),
      DrawerEntryRow,
      PrefetchHooks Function({bool shiftId})
    >;
typedef $$ParkedSalesTableCreateCompanionBuilder =
    ParkedSalesCompanion Function({
      required String id,
      required DateTime parkedAt,
      required String payload,
      Value<int> rowid,
    });
typedef $$ParkedSalesTableUpdateCompanionBuilder =
    ParkedSalesCompanion Function({
      Value<String> id,
      Value<DateTime> parkedAt,
      Value<String> payload,
      Value<int> rowid,
    });

class $$ParkedSalesTableFilterComposer
    extends Composer<_$AppDatabase, $ParkedSalesTable> {
  $$ParkedSalesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get parkedAt => $composableBuilder(
    column: $table.parkedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ParkedSalesTableOrderingComposer
    extends Composer<_$AppDatabase, $ParkedSalesTable> {
  $$ParkedSalesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get parkedAt => $composableBuilder(
    column: $table.parkedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ParkedSalesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ParkedSalesTable> {
  $$ParkedSalesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get parkedAt =>
      $composableBuilder(column: $table.parkedAt, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);
}

class $$ParkedSalesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ParkedSalesTable,
          ParkedSaleRow,
          $$ParkedSalesTableFilterComposer,
          $$ParkedSalesTableOrderingComposer,
          $$ParkedSalesTableAnnotationComposer,
          $$ParkedSalesTableCreateCompanionBuilder,
          $$ParkedSalesTableUpdateCompanionBuilder,
          (
            ParkedSaleRow,
            BaseReferences<_$AppDatabase, $ParkedSalesTable, ParkedSaleRow>,
          ),
          ParkedSaleRow,
          PrefetchHooks Function()
        > {
  $$ParkedSalesTableTableManager(_$AppDatabase db, $ParkedSalesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ParkedSalesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ParkedSalesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ParkedSalesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<DateTime> parkedAt = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ParkedSalesCompanion(
                id: id,
                parkedAt: parkedAt,
                payload: payload,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required DateTime parkedAt,
                required String payload,
                Value<int> rowid = const Value.absent(),
              }) => ParkedSalesCompanion.insert(
                id: id,
                parkedAt: parkedAt,
                payload: payload,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ParkedSalesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ParkedSalesTable,
      ParkedSaleRow,
      $$ParkedSalesTableFilterComposer,
      $$ParkedSalesTableOrderingComposer,
      $$ParkedSalesTableAnnotationComposer,
      $$ParkedSalesTableCreateCompanionBuilder,
      $$ParkedSalesTableUpdateCompanionBuilder,
      (
        ParkedSaleRow,
        BaseReferences<_$AppDatabase, $ParkedSalesTable, ParkedSaleRow>,
      ),
      ParkedSaleRow,
      PrefetchHooks Function()
    >;
typedef $$SettingsRowTableCreateCompanionBuilder =
    SettingsRowCompanion Function({
      Value<int> id,
      required String shopName,
      required String shopNameEN,
      Value<double> taxRate,
      Value<int> quoteValidDays,
      Value<String?> address,
      Value<String?> phone,
      Value<String?> cashierName,
      Value<String?> taxId,
      Value<String?> branchNo,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
    });
typedef $$SettingsRowTableUpdateCompanionBuilder =
    SettingsRowCompanion Function({
      Value<int> id,
      Value<String> shopName,
      Value<String> shopNameEN,
      Value<double> taxRate,
      Value<int> quoteValidDays,
      Value<String?> address,
      Value<String?> phone,
      Value<String?> cashierName,
      Value<String?> taxId,
      Value<String?> branchNo,
      Value<DateTime?> updatedAt,
      Value<DateTime?> deletedAt,
    });

class $$SettingsRowTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsRowTable> {
  $$SettingsRowTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shopName => $composableBuilder(
    column: $table.shopName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shopNameEN => $composableBuilder(
    column: $table.shopNameEN,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get taxRate => $composableBuilder(
    column: $table.taxRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get quoteValidDays => $composableBuilder(
    column: $table.quoteValidDays,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cashierName => $composableBuilder(
    column: $table.cashierName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get taxId => $composableBuilder(
    column: $table.taxId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get branchNo => $composableBuilder(
    column: $table.branchNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsRowTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsRowTable> {
  $$SettingsRowTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shopName => $composableBuilder(
    column: $table.shopName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shopNameEN => $composableBuilder(
    column: $table.shopNameEN,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get taxRate => $composableBuilder(
    column: $table.taxRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get quoteValidDays => $composableBuilder(
    column: $table.quoteValidDays,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phone => $composableBuilder(
    column: $table.phone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cashierName => $composableBuilder(
    column: $table.cashierName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get taxId => $composableBuilder(
    column: $table.taxId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get branchNo => $composableBuilder(
    column: $table.branchNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsRowTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsRowTable> {
  $$SettingsRowTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get shopName =>
      $composableBuilder(column: $table.shopName, builder: (column) => column);

  GeneratedColumn<String> get shopNameEN => $composableBuilder(
    column: $table.shopNameEN,
    builder: (column) => column,
  );

  GeneratedColumn<double> get taxRate =>
      $composableBuilder(column: $table.taxRate, builder: (column) => column);

  GeneratedColumn<int> get quoteValidDays => $composableBuilder(
    column: $table.quoteValidDays,
    builder: (column) => column,
  );

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get phone =>
      $composableBuilder(column: $table.phone, builder: (column) => column);

  GeneratedColumn<String> get cashierName => $composableBuilder(
    column: $table.cashierName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get taxId =>
      $composableBuilder(column: $table.taxId, builder: (column) => column);

  GeneratedColumn<String> get branchNo =>
      $composableBuilder(column: $table.branchNo, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$SettingsRowTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsRowTable,
          SettingsRowData,
          $$SettingsRowTableFilterComposer,
          $$SettingsRowTableOrderingComposer,
          $$SettingsRowTableAnnotationComposer,
          $$SettingsRowTableCreateCompanionBuilder,
          $$SettingsRowTableUpdateCompanionBuilder,
          (
            SettingsRowData,
            BaseReferences<_$AppDatabase, $SettingsRowTable, SettingsRowData>,
          ),
          SettingsRowData,
          PrefetchHooks Function()
        > {
  $$SettingsRowTableTableManager(_$AppDatabase db, $SettingsRowTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsRowTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsRowTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsRowTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> shopName = const Value.absent(),
                Value<String> shopNameEN = const Value.absent(),
                Value<double> taxRate = const Value.absent(),
                Value<int> quoteValidDays = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<String?> phone = const Value.absent(),
                Value<String?> cashierName = const Value.absent(),
                Value<String?> taxId = const Value.absent(),
                Value<String?> branchNo = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
              }) => SettingsRowCompanion(
                id: id,
                shopName: shopName,
                shopNameEN: shopNameEN,
                taxRate: taxRate,
                quoteValidDays: quoteValidDays,
                address: address,
                phone: phone,
                cashierName: cashierName,
                taxId: taxId,
                branchNo: branchNo,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String shopName,
                required String shopNameEN,
                Value<double> taxRate = const Value.absent(),
                Value<int> quoteValidDays = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<String?> phone = const Value.absent(),
                Value<String?> cashierName = const Value.absent(),
                Value<String?> taxId = const Value.absent(),
                Value<String?> branchNo = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
              }) => SettingsRowCompanion.insert(
                id: id,
                shopName: shopName,
                shopNameEN: shopNameEN,
                taxRate: taxRate,
                quoteValidDays: quoteValidDays,
                address: address,
                phone: phone,
                cashierName: cashierName,
                taxId: taxId,
                branchNo: branchNo,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsRowTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsRowTable,
      SettingsRowData,
      $$SettingsRowTableFilterComposer,
      $$SettingsRowTableOrderingComposer,
      $$SettingsRowTableAnnotationComposer,
      $$SettingsRowTableCreateCompanionBuilder,
      $$SettingsRowTableUpdateCompanionBuilder,
      (
        SettingsRowData,
        BaseReferences<_$AppDatabase, $SettingsRowTable, SettingsRowData>,
      ),
      SettingsRowData,
      PrefetchHooks Function()
    >;
typedef $$AppMetaTableCreateCompanionBuilder =
    AppMetaCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppMetaTableUpdateCompanionBuilder =
    AppMetaCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppMetaTableFilterComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppMetaTable> {
  $$AppMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppMetaTable,
          AppMetaRow,
          $$AppMetaTableFilterComposer,
          $$AppMetaTableOrderingComposer,
          $$AppMetaTableAnnotationComposer,
          $$AppMetaTableCreateCompanionBuilder,
          $$AppMetaTableUpdateCompanionBuilder,
          (
            AppMetaRow,
            BaseReferences<_$AppDatabase, $AppMetaTable, AppMetaRow>,
          ),
          AppMetaRow,
          PrefetchHooks Function()
        > {
  $$AppMetaTableTableManager(_$AppDatabase db, $AppMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) =>
                  AppMetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppMetaTable,
      AppMetaRow,
      $$AppMetaTableFilterComposer,
      $$AppMetaTableOrderingComposer,
      $$AppMetaTableAnnotationComposer,
      $$AppMetaTableCreateCompanionBuilder,
      $$AppMetaTableUpdateCompanionBuilder,
      (AppMetaRow, BaseReferences<_$AppDatabase, $AppMetaTable, AppMetaRow>),
      AppMetaRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProductsTableTableManager get products =>
      $$ProductsTableTableManager(_db, _db.products);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db, _db.categories);
  $$CustomersTableTableManager get customers =>
      $$CustomersTableTableManager(_db, _db.customers);
  $$MechanicsTableTableManager get mechanics =>
      $$MechanicsTableTableManager(_db, _db.mechanics);
  $$SalesTableTableManager get sales =>
      $$SalesTableTableManager(_db, _db.sales);
  $$SaleItemsTableTableManager get saleItems =>
      $$SaleItemsTableTableManager(_db, _db.saleItems);
  $$PurchaseOrdersTableTableManager get purchaseOrders =>
      $$PurchaseOrdersTableTableManager(_db, _db.purchaseOrders);
  $$PoItemsTableTableManager get poItems =>
      $$PoItemsTableTableManager(_db, _db.poItems);
  $$ReturnsTableTableManager get returns =>
      $$ReturnsTableTableManager(_db, _db.returns);
  $$ReturnItemsTableTableManager get returnItems =>
      $$ReturnItemsTableTableManager(_db, _db.returnItems);
  $$QuotesTableTableManager get quotes =>
      $$QuotesTableTableManager(_db, _db.quotes);
  $$QuoteItemsTableTableManager get quoteItems =>
      $$QuoteItemsTableTableManager(_db, _db.quoteItems);
  $$MovementsTableTableManager get movements =>
      $$MovementsTableTableManager(_db, _db.movements);
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db, _db.suppliers);
  $$CreditPaymentsTableTableManager get creditPayments =>
      $$CreditPaymentsTableTableManager(_db, _db.creditPayments);
  $$ShiftsTableTableManager get shifts =>
      $$ShiftsTableTableManager(_db, _db.shifts);
  $$DrawerEntriesTableTableManager get drawerEntries =>
      $$DrawerEntriesTableTableManager(_db, _db.drawerEntries);
  $$ParkedSalesTableTableManager get parkedSales =>
      $$ParkedSalesTableTableManager(_db, _db.parkedSales);
  $$SettingsRowTableTableManager get settingsRow =>
      $$SettingsRowTableTableManager(_db, _db.settingsRow);
  $$AppMetaTableTableManager get appMeta =>
      $$AppMetaTableTableManager(_db, _db.appMeta);
}
