import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:household_os/features/profile/presentation/delete_account_dialog.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';

/// Runs the whole "Delete account" flow: ownership check, typed
/// confirmation, server deletion, then local sign-out and a fresh start.
///
/// A new anonymous account is only created after the server confirmed the
/// deletion; while it is unresolved the user stays signed in and can retry.
Future<void> startAccountDeletion(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required bool resuming,
}) async {
  final repo = ref.read(accountRepositoryProvider);
  final List<OwnedHousehold> blockers;
  try {
    blockers = resuming ? const [] : await repo.fetchBlockers();
  } catch (_) {
    if (context.mounted) {
      _snack(context, 'Could not check your homes. Please try again.');
    }
    return;
  }
  if (!context.mounted) return;
  if (blockers.isNotEmpty) {
    await _showBlockedDialog(context, blockers);
    return;
  }

  final cleanup = await ref.read(accountLocalCleanupProvider.future);
  if (!context.mounted) return;
  final deleted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DeleteAccountDialog(
      resuming: resuming,
      onRequestCode: () async {
        _requireSameUser(repo, userId);
        await repo.sendDeletionCode();
      },
      onDelete: (code) async {
        _requireSameUser(repo, userId);
        // Recorded before the request so an app kill in between is recovered
        // on the next launch.
        await cleanup.mark(userId);
        try {
          await repo.deleteAccount(code: code);
        } on AccountDeletionException catch (e) {
          // Refused before anything changed: nothing to recover later.
          if (e.failure.leavesAccountUntouched) await cleanup.unmark();
          rethrow;
        }
      },
    ),
  );
  if (deleted != true) return;

  await cleanup.finish(userId, repo);
  // Ending the session replaces the user-scoped root; if that already
  // happened there is nothing left to refresh or navigate.
  if (!context.mounted) return;
  ref.invalidate(currentProfileProvider);
  ref.invalidate(homesProvider);
  if (context.mounted) context.go('/homes');
}

/// The flow belongs to the user who opened it; another account must not be
/// asked for a code or deleted by it.
void _requireSameUser(AccountRepository repo, String userId) {
  if (repo.currentUserId != userId) {
    throw const AccountDeletionException(AccountDeletionFailure.sessionChanged);
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> _showBlockedDialog(
  BuildContext context,
  List<OwnedHousehold> owned,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Hand over your homes first'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You own these homes. Transfer ownership to another member, or '
              'delete the home, before deleting your account.',
            ),
            const SizedBox(height: 12),
            for (final home in owned)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  home.activeMemberCount > 1
                      ? '${home.name} (${home.activeMemberCount} members)'
                      : '${home.name} (only you)',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
