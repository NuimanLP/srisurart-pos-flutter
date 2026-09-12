// App entry point. Opens the real on-device SQLite DB and wires it into the
// flutter_bloc RepositoryProvider tree.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'app.dart';
import 'core/network/api_client.dart';
import 'data/db/database.dart';
import 'data/repositories/auth_repository.dart';
import 'presentation/blocs/auth_cubit.dart';
import 'presentation/blocs/cart_cubit.dart';
import 'presentation/blocs/pending_quote_cubit.dart';
import 'presentation/repositories/repository_providers.dart';
import 'presentation/widgets/font_scale_controller.dart';
import 'presentation/widgets/theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
              )..init();
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
