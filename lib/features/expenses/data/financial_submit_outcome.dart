import 'package:supabase_flutter/supabase_flutter.dart';

/// What a failed financial submission tells us about the server state.
enum FinancialSubmitOutcome {
  /// The server answered and refused: nothing was stored, a new attempt may
  /// use a fresh request id.
  rejected,

  /// No trustworthy answer (network loss, timeout, gateway error): the record
  /// may or may not exist, so the SAME request id must be retried.
  ambiguous,

  /// The request id was already processed and its record was removed (HF003).
  alreadyRemoved,

  /// The request id was already used for different details (HF002).
  keyReused,

  /// The currency is not the household's currency (HE008, HS009). Nothing
  /// was stored.
  currencyMismatch,

  /// The amount is above the per-operation limit (HE009, HS010). Nothing was
  /// stored.
  amountTooLarge,
}

final _sqlState = RegExp(r'^[0-9A-Z]{5}$');
final _unknownCommitState = RegExp(r'^(08|57P|58|XX)');

FinancialSubmitOutcome classifyFinancialSubmitError(Object error) {
  if (error is PostgrestException) {
    final code = error.code;
    if (code == 'HF003') return FinancialSubmitOutcome.alreadyRemoved;
    if (code == 'HF002') return FinancialSubmitOutcome.keyReused;
    if (code == 'HE008' || code == 'HS009') {
      return FinancialSubmitOutcome.currencyMismatch;
    }
    if (code == 'HE009' || code == 'HS010') {
      return FinancialSubmitOutcome.amountTooLarge;
    }
    // SQLSTATE and PostgREST error codes mean the server processed the call;
    // a bare HTTP status (502, 503, 504, ...) means a gateway gave up. Errors
    // that signal a lost or restarting database connection (classes 08, 57P,
    // 58, XX) can arrive at commit time, so the outcome is still unknown.
    if (code != null &&
        (_sqlState.hasMatch(code) || code.startsWith('PGRST')) &&
        !_unknownCommitState.hasMatch(code)) {
      return FinancialSubmitOutcome.rejected;
    }
  }
  return FinancialSubmitOutcome.ambiguous;
}
