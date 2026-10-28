import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/widgets/app_icon_chip.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/auth/presentation/link_email_screen.dart';
import 'package:household_os/features/auth/presentation/recovery_screen.dart';
import 'package:household_os/features/profile/domain/profile.dart';

/// What the Auth SERVER says about the signed-in account, asked fresh each time
/// Profile is shown (never a cached "linked" flag). Null for an account that
/// is not offered anything. Errors are kept so Profile can say so.
final accountProtectionProvider =
    FutureProvider.autoDispose<AccountProtection?>((ref) async {
      final identity = await ref
          .watch(emailAccountRepositoryProvider)
          .currentIdentity();
      return protectionOf(identity);
    });

/// The Profile "Account" rows that belong to email protection. A deleting
/// account is offered nothing here: it cannot be restored to active.
List<Widget> accountProtectionRows(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) {
  if (profile.accountState != 'active') return const [];
  final colorScheme = Theme.of(context).colorScheme;
  final protection = ref.watch(accountProtectionProvider);

  Widget chip(IconData icon) => AppIconChip(
    icon: icon,
    background: colorScheme.primary.withValues(alpha: 0.10),
    foreground: colorScheme.primary,
    size: 32,
    iconSize: 16,
  );

  return protection.when(
    loading: () => [
      ListTile(
        leading: chip(Icons.shield_outlined),
        title: const Text('Checking account protection…'),
      ),
    ],
    error: (_, _) => [
      ListTile(
        leading: chip(Icons.shield_outlined),
        title: const Text("Couldn't check account protection"),
        subtitle: const Text('Tap to try again.'),
        onTap: () => ref.invalidate(accountProtectionProvider),
      ),
    ],
    data: (state) => switch (state) {
      null => const [],
      AccountUnprotected() => [
        ListTile(
          leading: chip(Icons.shield_outlined),
          title: const Text('Protect your account'),
          subtitle: const Text(
            'Link an email to recover your home if you change devices or '
            'reinstall the app. You can only sign out once an email is linked.',
          ),
          onTap: () => _openLinkScreen(context, ref, null),
        ),
      ],
      AccountVerificationPending() => [
        ListTile(
          leading: chip(Icons.mark_email_unread_outlined),
          title: const Text('Finish verifying your email'),
          subtitle: Text(
            '${state.email} is not verified yet, so your account is not '
            'protected.',
          ),
          onTap: () => _openLinkScreen(context, ref, state),
        ),
      ],
      AccountProtected() => [
        ListTile(
          leading: chip(Icons.verified_user_rounded),
          title: const Text('Account protected'),
          subtitle: Text(state.email),
        ),
        ListTile(
          leading: chip(Icons.logout_rounded),
          title: const Text('Sign out'),
          subtitle: const Text(
            'Sign back in later with a code sent to your email',
          ),
          onTap: () => _confirmSignOut(context, ref),
        ),
      ],
    },
  );
}

Future<void> _openLinkScreen(
  BuildContext context,
  WidgetRef ref,
  AccountVerificationPending? pending,
) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => LinkEmailScreen(pending: pending)),
  );
  ref.invalidate(accountProtectionProvider);
}

Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
  final confirmed = await confirmDestructive(
    context,
    title: 'Sign out?',
    message:
        'This device will leave your home. To get back in, choose "I already '
        'have an account" and enter the code we email you.',
    confirmLabel: 'Sign out',
  );
  if (!confirmed || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final coordinator = await ref.read(sessionSwitchCoordinatorProvider.future);
    // No acknowledgement: an account without a verified email is refused.
    await coordinator.signOut();
    // The user-scoped root replaces the whole app and shows Welcome.
  } on EmailAuthException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(recoveryMessage(e.failure))));
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't sign out. Try again.")),
    );
  }
}
