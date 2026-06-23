// CustomersScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CustomersScreen extends ConsumerWidget {
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('ลูกค้า')),
      body: const Center(child: Text('ลูกค้า')),
    );
  }
}
