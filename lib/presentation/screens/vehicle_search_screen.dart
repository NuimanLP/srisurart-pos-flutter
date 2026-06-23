// VehicleSearchScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VehicleSearchScreen extends ConsumerWidget {
  const VehicleSearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('ค้นหารุ่น')),
      body: const Center(child: Text('ค้นหารุ่น')),
    );
  }
}
