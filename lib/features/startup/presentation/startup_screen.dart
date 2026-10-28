import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/routing/app_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/startup/domain/startup_state.dart';
import 'package:household_os/features/startup/presentation/startup_provider.dart';
import 'package:household_os/features/startup/presentation/welcome_view.dart';

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
    final notifier = ref.read(startupProvider.notifier);
    return switch (ref.watch(startupProvider)) {
      StartupReady() => const _EnterApp(),
      StartupWelcome() => WelcomeView(
        onGetStarted: notifier.continueWithoutRegistration,
        onRecover: () => context.push('/recover'),
      ),
      StartupFailed(:final error) => _ErrorView(
        message: startupFriendlyErrorMessage(error),
        onRetry: notifier.retry,
      ),
      // Resolving a restored session shows the same quiet loading frame, so
      // the welcome screen never flashes for a returning user.
      StartupResolving() || StartupSigningIn() => const _LoadingView(),
    };
  }
}

/// Leaves the startup route for the app once, after the first frame.
class _EnterApp extends StatefulWidget {
  const _EnterApp();

  @override
  State<_EnterApp> createState() => _EnterAppState();
}

class _EnterAppState extends State<_EnterApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => appRouter.go('/today'));
  }

  @override
  Widget build(BuildContext context) => const _LoadingView();
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
