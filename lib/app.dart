// SrisurartApp — root MaterialApp.router. Thai-first locale, brand light/dark
// themes, go_router navigation. Font-scale multiplier via MediaQuery.textScaler.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'presentation/widgets/font_scale_controller.dart';
import 'presentation/widgets/theme_controller.dart';

class SrisurartApp extends StatelessWidget {
  const SrisurartApp({super.key});

  @override
  Widget build(BuildContext context) {
    final fontScale = context.watch<FontScaleCubit>().state;
    return MaterialApp.router(
      title: 'Srisurart POS',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: context.watch<ThemeModeCubit>().state,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('th'),
        Locale('en'),
      ],
      locale: const Locale('th'),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(fontScale),
          ),
          child: child!,
        );
      },
    );
  }
}
