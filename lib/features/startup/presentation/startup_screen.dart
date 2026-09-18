import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/routing/app_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';

/// Returns a user-friendly message for a startup auth/network error.
String startupFriendlyErrorMessage(Object error) {
  final msg = error.toString();
  if (error is SocketException ||
      msg.contains('SocketException') ||
      msg.contains('Failed host lookup') ||
      msg.contains('ClientException')) {
    return "Couldn't connect. Check your internet connection and try again.";
  }
  return 'Something went wrong. Try again.';
}

class StartupScreen extends ConsumerWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      data: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          appRouter.go('/today');
        });
        return const _LoadingView();
      },
      loading: () => const _LoadingView(),
      error: (error, _) => _ErrorView(
        message: startupFriendlyErrorMessage(error),
        onRetry: () => ref.invalidate(currentProfileProvider),
      ),
    );
  }
}

/// Shared identity block ("Household OS") both the loading and error frames
/// build around, so startup reads as a quiet branded moment rather than a
/// bare system spinner or a bare error string on an empty page.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      'Household OS',
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      // Pushed outside the shell's `AppBackground` — see
      // `appFlatBackgroundFallback`'s doc comment.
      backgroundColor: appFlatBackgroundFallback,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BrandMark(),
            SizedBox(height: 32),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      // Pushed outside the shell's `AppBackground` — see
      // `appFlatBackgroundFallback`'s doc comment.
      backgroundColor: appFlatBackgroundFallback,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _BrandMark(),
              const SizedBox(height: 32),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
