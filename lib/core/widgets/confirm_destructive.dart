import 'package:flutter/material.dart';

/// Shows the app's single destructive-confirmation dialog and returns `true`
/// only if the user chose the destructive action.
///
/// Use for actions with a meaningful or hard-to-reverse consequence (leaving
/// or deleting a household, task, expense, or settlement; removing a member;
/// revoking an invite; removing an avatar) — not for every delete
/// indiscriminately. A lightweight action like deleting a single Shopping
/// item is deliberately left unconfirmed. Consumers write their own
/// [title]/[message]; this only unifies the button roles, styling, and
/// ordering.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
