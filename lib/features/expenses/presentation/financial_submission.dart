import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/expenses/data/financial_submit_outcome.dart';
import 'package:household_os/features/expenses/domain/financial_request.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';

/// Sends one financial submission with a durable request id.
///
/// The id is saved to local storage BEFORE the request goes out, and removed
/// only when the outcome is known (success, or a definite server refusal).
/// If storage is unavailable the request is not sent at all: an identity that
/// could be lost after an ambiguous outcome would allow a duplicate record.
/// After an ambiguous failure the same id is reused by the next attempt, even
/// after the form was closed or the app restarted. Every unresolved identity
/// is kept separately. If the user changes the details while an earlier
/// attempt is unconfirmed, they must explicitly choose to record the new
/// details as a separate entry.
class FinancialSubmission {
  const FinancialSubmission._();

  /// Returns true when the server accepted the submission (or had already
  /// recorded this exact one). On false a message has been shown, or the user
  /// chose to review the history first.
  static Future<bool> run({
    required BuildContext context,
    required WidgetRef ref,
    required String kind,
    required String householdId,
    required List<String> payloadParts,
    required Future<void> Function(String requestId) send,
    required String failureMessage,
  }) async {
    final userId = ref.read(currentUserIdProvider);
    final hash = payloadFingerprint(payloadParts);

    final FinancialRequestStore store;
    final PendingFinancialOperation operation;
    try {
      store = await _openStore(ref);
      var existing = store.findByHash(
        userId: userId,
        householdId: householdId,
        kind: kind,
        payloadHash: hash,
      );
      if (existing == null &&
          store.hasUnacknowledged(
            userId: userId,
            householdId: householdId,
            kind: kind,
          )) {
        if (!context.mounted) return false;
        if (!await _confirmRecordAsNew(context)) return false;
        await store.acknowledgeAll(
          userId: userId,
          householdId: householdId,
          kind: kind,
        );
      }
      existing ??= await store.begin(
        userId: userId,
        householdId: householdId,
        kind: kind,
        payloadHash: hash,
      );
      operation = existing;
    } on FinancialPendingLimitException {
      // Nothing was sent, and no unresolved identity was removed.
      if (context.mounted) {
        _showMessage(
          context,
          'Too many earlier entries are still unconfirmed. '
          'Check the history and try again later.',
        );
      }
      return false;
    } catch (_) {
      // Nothing was sent, so retrying later is safe.
      if (context.mounted) _showMessage(context, failureMessage);
      return false;
    }

    try {
      await send(operation.requestId);
      await _resolve(store, userId, householdId, kind, operation.requestId);
      return true;
    } catch (error) {
      final outcome = classifyFinancialSubmitError(error);
      if (outcome != FinancialSubmitOutcome.ambiguous) {
        await _resolve(store, userId, householdId, kind, operation.requestId);
      }
      if (context.mounted) {
        _showMessage(context, _message(outcome, failureMessage));
      }
      return false;
    }
  }

  static Future<void> _resolve(
    FinancialRequestStore store,
    String userId,
    String householdId,
    String kind,
    String requestId,
  ) async {
    try {
      await store.remove(
        userId: userId,
        householdId: householdId,
        kind: kind,
        requestId: requestId,
      );
    } catch (_) {
      // A leftover identity is harmless: reusing it replays the same result.
    }
  }

  static void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _message(FinancialSubmitOutcome outcome, String failure) {
    return switch (outcome) {
      FinancialSubmitOutcome.alreadyRemoved =>
        'This was already recorded and has since been removed.',
      FinancialSubmitOutcome.keyReused =>
        'This entry was already used with different details. Please try again.',
      FinancialSubmitOutcome.currencyMismatch =>
        "This entry's currency does not match the household currency.",
      FinancialSubmitOutcome.amountTooLarge =>
        'The amount cannot exceed €1,000,000.00',
      _ => failure,
    };
  }

  /// Storage must be ready quickly; otherwise the submission is not sent.
  static Future<FinancialRequestStore> _openStore(WidgetRef ref) {
    return ref
        .read(financialRequestStoreProvider.future)
        .timeout(const Duration(seconds: 2));
  }

  static Future<bool> _confirmRecordAsNew(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Earlier attempt not confirmed'),
        content: const Text(
          'An earlier attempt with different details may already have been '
          'saved. Check the history first, or record these details as a '
          'new entry.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Check history'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Record as new'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
