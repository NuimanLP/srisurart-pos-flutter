// ShiftsRepository provider — kept OUT of the frozen providers.dart.
//
// Reads the shared databaseProvider (defined in providers.dart) so it wires
// into the same AppDatabase override set up in main.dart. The cash-drawer
// screen agent consumes `shiftsRepoProvider` for open/close shift, cash in/out,
// and shift history.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/shifts_repository.dart';
import 'providers.dart';

final shiftsRepoProvider = Provider<ShiftsRepository>(
    (ref) => ShiftsRepository(ref.watch(databaseProvider)));
