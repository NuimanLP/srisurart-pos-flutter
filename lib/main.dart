// App entry point. Opens the real on-device SQLite DB and wires it into the
// Riverpod graph by overriding databaseProvider, then runs SrisurartApp.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/db/database.dart';
import 'presentation/providers/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.open();
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const SrisurartApp(),
    ),
  );
}
