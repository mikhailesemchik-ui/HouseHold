import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';

const deleteAccountPhrase = 'DELETE';

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
    builder: (_) => _DeleteAccountDialog(
      resuming: resuming,
      onDelete: () async {
        // Recorded before the request so an app kill in between is recovered
        // on the next launch.
        await cleanup.mark(userId);
        try {
          await repo.deleteAccount();
        } on AccountDeletionException catch (e) {
          if (e.failure == AccountDeletionFailure.ownsHouseholds) {
            await cleanup.unmark();
          }
          rethrow;
        }
      },
    ),
  );
  if (deleted != true) return;

  await cleanup.finish(userId, repo);
  ref.invalidate(currentProfileProvider);
  ref.invalidate(homesProvider);
  if (context.mounted) context.go('/homes');
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

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.resuming, required this.onDelete});

  final bool resuming;
  final Future<void> Function() onDelete;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();
  bool _isDeleting = false;
  String? _error;

  bool get _phraseMatches => _controller.text == deleteAccountPhrase;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_isDeleting || !_phraseMatches) return;
    setState(() {
      _isDeleting = true;
      _error = null;
    });
    try {
      await widget.onDelete();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDeleting = false;
        _error = switch (e) {
          AccountDeletionException(
            failure: AccountDeletionFailure.ownsHouseholds,
          ) =>
            'You still own a home. Transfer or delete it first.',
          _ =>
            'Deleting did not finish. Your account is not usable any more, '
                'so please try again.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.resuming ? 'Finish deleting account?' : 'Delete account?',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your account, name, avatar and notification settings are '
              'permanently deleted. This cannot be undone and you cannot sign '
              'back in to this account.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Shared homes keep their tasks, shopping and expenses. Entries '
              'you made stay as "Deleted member" for the other members, and '
              'any text you wrote in them is kept.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Open balances with other members can no longer be settled '
              'with you. Payments are not forgiven or changed.',
            ),
            const SizedBox(height: 12),
            Text('Type $deleteAccountPhrase to confirm.'),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              enabled: !_isDeleting,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Confirmation'),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isDeleting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _phraseMatches && !_isDeleting ? _delete : null,
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          child: _isDeleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete account'),
        ),
      ],
    );
  }
}
