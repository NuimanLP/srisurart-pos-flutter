// ReturnsScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ReturnsScreen extends ConsumerWidget {
  const ReturnsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('คืนสินค้า')),
      body: const Center(child: Text('คืนสินค้า')),
    );
  }
}
