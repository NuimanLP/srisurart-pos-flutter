// App entry point. Opens the real on-device SQLite DB and wires it into the
// flutter_bloc RepositoryProvider tree.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app.dart';
import 'core/network/api_client.dart';
import 'data/db/database.dart';
import 'data/repositories/auth_repository.dart';
import 'data/services/doc_counter_seeder.dart';
import 'presentation/blocs/auth_cubit.dart';
import 'presentation/blocs/cart_cubit.dart';
import 'presentation/blocs/doc_counter_seeding.dart';
import 'presentation/blocs/pending_quote_cubit.dart';
import 'presentation/repositories/repository_providers.dart';
import 'presentation/widgets/font_scale_controller.dart';
import 'presentation/widgets/theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // #271: Sarabun is a bundled asset font (see app_theme.dart) — nothing in
  // the app should ever fetch a font over the network. Belt-and-braces safety
  // net; the offline PWA shell can't reach fonts.gstatic.com (flutter#163554).
  GoogleFonts.config.allowRuntimeFetching = false;
  final db = AppDatabase.open();
  runApp(
    MultiRepositoryProvider(
      providers: repositoryProviders(db),
      child: MultiBlocProvider(
        providers: [
          BlocProvider<ThemeModeCubit>(create: (_) => ThemeModeCubit()),
          BlocProvider<FontScaleCubit>(create: (_) => FontScaleCubit()),
          BlocProvider<PendingQuoteCubit>(create: (_) => PendingQuoteCubit()),
          BlocProvider<CartCubit>(create: (_) => CartCubit()),
          BlocProvider<AuthCubit>(
            create: (ctx) {
              final cubit = AuthCubit(
                authRepository: ctx.read<AuthRepository>(),
              );
              // #188: seed the document-number counter on app open and login.
              // Only the API build has a server to seed from.
              if (const bool.fromEnvironment('USE_API_WRITES')) {
                seedDocCountersOnSignIn(cubit, ctx.read<DocCounterSeeder>());
              }
              cubit.init();
              // The refresh path clears the tokens and calls this; without the
              // wiring the app kept a signed-in state that every request 401'd
              // against. #54 AC3.
              ctx.read<ApiClient>().onSessionExpired = cubit.sessionExpired;
              return cubit;
            },
          ),
        ],
        child: const SrisurartApp(),
      ),
    ),
  );
}
