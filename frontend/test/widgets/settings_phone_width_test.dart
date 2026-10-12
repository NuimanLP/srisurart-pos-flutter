// UX pass 2026-10-11 — Settings at a 390 px phone width: every tab is
// reachable without a sideways scroll (the tab strip wraps), and the tabs that
// need no signed-in session lay out without a RenderFlex overflow. The account
// tab needs an AuthCubit and is covered by its own tests.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srisurart_pos/data/db/database.dart';
import 'package:srisurart_pos/presentation/blocs/cart_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/pending_quote_cubit.dart';
import 'package:srisurart_pos/presentation/blocs/ui_zoom_cubit.dart';
import 'package:srisurart_pos/presentation/repositories/repository_providers.dart';
import 'package:srisurart_pos/presentation/screens/settings_screen.dart';
import 'package:srisurart_pos/presentation/widgets/font_scale_controller.dart';
import 'package:srisurart_pos/presentation/widgets/theme_controller.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('every settings tab is on screen and lays out at 390 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: repositoryProviders(db, useApiRepositories: false),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
              BlocProvider<FontScaleCubit>(create: (_) => FontScaleCubit()),
              BlocProvider<UiZoomCubit>(create: (_) => UiZoomCubit()),
              BlocProvider<PendingQuoteCubit>(
                create: (_) => PendingQuoteCubit(),
              ),
              BlocProvider<CartCubit>(create: (_) => CartCubit()),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }

      await settle();
      expect(tester.takeException(), isNull, reason: 'general tab');

      const tabs = [
        '⚙ ทั่วไป',
        '🔐 บัญชี / ผูกเครื่อง',
        '📱 บัญชีรับเงิน QR',
        '🎨 ธีม',
        '💾 สำรอง/กู้คืน',
        '📤 ส่งออก CSV',
      ];
      final screenWidth = tester.view.physicalSize.width;
      for (final t in tabs) {
        final rect = tester.getRect(find.text(t));
        expect(
          rect.right <= screenWidth && rect.left >= 0,
          isTrue,
          reason: '$t must be visible without scrolling the tab strip',
        );
      }

      for (final t in ['🎨 ธีม', '💾 สำรอง/กู้คืน', '📤 ส่งออก CSV']) {
        await tester.tap(find.text(t));
        await settle();
        expect(tester.takeException(), isNull, reason: t);
      }

      // Restore sub-tab and the export custom-date fields too.
      await tester.tap(find.text('💾 สำรอง/กู้คืน'));
      await settle();
      await tester.tap(find.text('📥 กู้คืนข้อมูล'));
      await settle();
      expect(tester.takeException(), isNull, reason: 'restore');

      await tester.tap(find.text('📤 ส่งออก CSV'));
      await settle();
      await tester.tap(find.text('กำหนดเอง'));
      await settle();
      expect(tester.takeException(), isNull, reason: 'custom range');
      expect(find.byTooltip('เลือกจากปฏิทิน'), findsNWidgets(2));

      await db.close();
    });
  });
}
