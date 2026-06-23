// MechanicsScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MechanicsScreen extends ConsumerWidget {
  const MechanicsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('ช่าง')),
      body: const Center(child: Text('ช่าง')),
    );
  }
}
