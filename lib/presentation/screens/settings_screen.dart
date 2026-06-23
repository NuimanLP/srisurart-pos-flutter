// SettingsScreen — STUB. Implementation owned by its screen agent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('ตั้งค่า')),
      body: const Center(child: Text('ตั้งค่า')),
    );
  }
}
