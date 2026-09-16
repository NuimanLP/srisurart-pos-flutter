// SrisurartApp — root MaterialApp.router. Thai-first locale, brand light/dark
// themes, go_router navigation. Font-scale multiplier via MediaQuery.textScaler.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'presentation/blocs/auth_cubit.dart';
import 'presentation/widgets/font_scale_controller.dart';
import 'presentation/widgets/theme_controller.dart';

class SrisurartApp extends StatefulWidget {
  const SrisurartApp({
    super.key,
    this.requireLogin = const bool.fromEnvironment('USE_API_WRITES'),
    @visibleForTesting this.themeOverride,
  });

  /// #143: hold every route behind a signed-in session. Follows the same
  /// `USE_API_WRITES` switch as `repositoryProviders(useApi:)` — the Drift-only
  /// shop build has no server to sign in to, so with it off the app keeps the
  /// plain [appRouter] and never reads the AuthCubit here.
  final bool requireLogin;

  /// Replaces both brand themes. Tests only, for a plain deterministic theme
  /// where a test doesn't care about AppTheme's brand styling. (Historically
  /// this also dodged a google_fonts network fetch inside AppTheme — #271
  /// removed that; Sarabun is a bundled asset font now, so that reason no
  /// longer applies, but the override hook is still useful on its own.)
  final ThemeData? themeOverride;

  @override
  State<SrisurartApp> createState() => _SrisurartAppState();
}

class _SrisurartAppState extends State<SrisurartApp> {
  late final GoRouter _router;
  AuthRefreshListenable? _authRefresh;

  @override
  void initState() {
    super.initState();
    if (widget.requireLogin) {
      final auth = context.read<AuthCubit>();
      _authRefresh = AuthRefreshListenable(auth);
      _router = buildAppRouter(auth: auth, refresh: _authRefresh);
    } else {
      _router = appRouter;
    }
  }

  @override
  void dispose() {
    if (_authRefresh != null) {
      _router.dispose();
      _authRefresh!.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fontScale = context.watch<FontScaleCubit>().state;
    return MaterialApp.router(
      title: 'Srisurart POS',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: widget.themeOverride ?? AppTheme.light,
      darkTheme: widget.themeOverride ?? AppTheme.dark,
      themeMode: context.watch<ThemeModeCubit>().state,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('th'), Locale('en')],
      locale: const Locale('th'),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(fontScale)),
          child: child!,
        );
      },
    );
  }
}
