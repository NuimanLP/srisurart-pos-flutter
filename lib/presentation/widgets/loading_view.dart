// LoadingView — a centered spinner for async/in-flight states.
//
//   ref.watch(someFutureProvider).when(
//     data: ..., error: ..., loading: () => const LoadingView());
//
// [message] shows optional Thai text under the spinner.

import 'package:flutter/material.dart';

class LoadingView extends StatelessWidget {
  final String? message;
  const LoadingView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
