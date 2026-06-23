// ProductsScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('สินค้า/สต็อก')),
      body: const Center(child: Text('สินค้า/สต็อก')),
    );
  }
}
