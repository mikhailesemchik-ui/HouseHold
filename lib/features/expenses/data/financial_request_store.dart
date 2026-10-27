import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/features/expenses/domain/financial_request.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A financial submission whose outcome is not known yet.
class PendingFinancialOperation {
  const PendingFinancialOperation({
    required this.requestId,
    required this.payloadHash,
    this.acknowledged = false,
  });

  final String requestId;
  final String payloadHash;

  /// The user was told the outcome is unconfirmed and chose to continue with
  /// other details. The identity is kept so these exact details can still be
  /// retried safely, but it no longer triggers a prompt.
  final bool acknowledged;

  Map<String, dynamic> toJson() => {
    'id': requestId,
    'hash': payloadHash,
    'ack': acknowledged,
  };

  PendingFinancialOperation acknowledge() => PendingFinancialOperation(
    requestId: requestId,
    payloadHash: payloadHash,
    acknowledged: true,
  );
}

/// Raised instead of sending a new submission when the local registry of
/// unresolved identities is full. An unresolved identity is never evicted: it
/// might belong to a request the server already committed.
class FinancialPendingLimitException implements Exception {
  const FinancialPendingLimitException();

  @override
  String toString() => 'FinancialPendingLimitException';
}

/// Remembers, per user, household and kind, every submission that may have
/// reached the server, so the same logical operation is always retried with
/// the same request id, even after the form is closed or the app restarts.
/// Several unresolved operations can coexist: an identity is removed only when
/// its own outcome is known, never because another submission started.
///
/// All changes are serialized through one in-process lock and read the stored
/// state inside it, so overlapping updates cannot lose each other. Durability
/// is whatever `shared_preferences` provides: a write is confirmed before a
/// request is sent, but an operating-system crash during the write itself, or
/// a second isolate writing the same keys without reloading, are not covered.
///
/// Only request ids and content fingerprints are stored: no amounts, names or
/// tokens.
class FinancialRequestStore {
  FinancialRequestStore(this._prefs);

  final SharedPreferences _prefs;

  /// Capacity per scope. Reaching it rejects a NEW submission; it never
  /// removes an existing identity.
  static const maxPending = 50;

  // One queue per SharedPreferences instance, shared by every store over it.
  static final Expando<Future<void>> _tails = Expando<Future<void>>();

  /// Runs [action] after every earlier store change has finished.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = (_tails[_prefs] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _tails[_prefs] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static String _key(String userId, String householdId, String kind) =>
      'pending_financial_op/$kind/$userId/$householdId';

  List<PendingFinancialOperation> pending({
    required String userId,
    required String householdId,
    required String kind,
  }) {
    final raw = _prefs.getString(_key(userId, householdId, kind));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      final entries = decoded is List ? decoded : [decoded];
      return [
        for (final e in entries)
          if (e is Map<String, dynamic> &&
              e['id'] is String &&
              e['hash'] is String)
            PendingFinancialOperation(
              requestId: e['id'] as String,
              payloadHash: e['hash'] as String,
              acknowledged: e['ack'] == true,
            ),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// The unresolved operation recorded for exactly these details, if any.
  PendingFinancialOperation? findByHash({
    required String userId,
    required String householdId,
    required String kind,
    required String payloadHash,
  }) {
    for (final op in pending(
      userId: userId,
      householdId: householdId,
      kind: kind,
    )) {
      if (op.payloadHash == payloadHash) return op;
    }
    return null;
  }

  /// Whether an earlier, unconfirmed attempt exists that the user has not yet
  /// been asked about.
  bool hasUnacknowledged({
    required String userId,
    required String householdId,
    required String kind,
  }) => pending(
    userId: userId,
    householdId: householdId,
    kind: kind,
  ).any((op) => !op.acknowledged);

  /// Keeps every unresolved identity but stops prompting about them.
  Future<void> acknowledgeAll({
    required String userId,
    required String householdId,
    required String kind,
  }) => _serialized(
    () => _write(userId, householdId, kind, [
      for (final op in pending(
        userId: userId,
        householdId: householdId,
        kind: kind,
      ))
        op.acknowledge(),
    ]),
  );

  /// Durably records a fresh request id for [payloadHash] and returns it.
  /// Throws [FinancialPendingLimitException] when the registry is full and a
  /// [StateError] if the write is not confirmed, so nothing is ever sent with
  /// an identity that could be lost after an ambiguous outcome.
  Future<PendingFinancialOperation> begin({
    required String userId,
    required String householdId,
    required String kind,
    required String payloadHash,
  }) => _serialized(() async {
    final existing = pending(
      userId: userId,
      householdId: householdId,
      kind: kind,
    );
    if (existing.length >= maxPending) {
      throw const FinancialPendingLimitException();
    }
    final op = PendingFinancialOperation(
      requestId: generateRequestId(),
      payloadHash: payloadHash,
    );
    await _write(userId, householdId, kind, [...existing, op]);
    return op;
  });

  /// Forgets one operation once its outcome is known.
  Future<void> remove({
    required String userId,
    required String householdId,
    required String kind,
    required String requestId,
  }) => _serialized(
    () => _write(userId, householdId, kind, [
      for (final op in pending(
        userId: userId,
        householdId: householdId,
        kind: kind,
      ))
        if (op.requestId != requestId) op,
    ]),
  );

  Future<void> _write(
    String userId,
    String householdId,
    String kind,
    List<PendingFinancialOperation> ops,
  ) async {
    final key = _key(userId, householdId, kind);
    final ok = ops.isEmpty
        ? await _prefs.remove(key)
        : await _prefs.setString(
            key,
            jsonEncode([for (final op in ops) op.toJson()]),
          );
    if (!ok) throw StateError('pending financial operation was not saved');
  }
}

final financialRequestStoreProvider = FutureProvider<FinancialRequestStore>((
  ref,
) async {
  return FinancialRequestStore(await SharedPreferences.getInstance());
});
