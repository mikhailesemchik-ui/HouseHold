import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/startup/data/startup_port.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/startup/domain/startup_state.dart';

final startupPortProvider = Provider<StartupPort>((ref) {
  return SupabaseStartupPort(
    supabaseClient,
    loadProfile: () => ref.read(currentProfileProvider.future),
    syncPushRegistration: (profile) async {
      // Opt-ins saved before accounts could change belong to this device's
      // only user so far.
      await HouseholdUpdatesPushSettings.adoptLegacyFor(profile.userId);
      await ref
          .read(pushRegistrationSyncProvider)
          .ensureRegistered(profile.userId);
    },
  );
});

final startupProvider = NotifierProvider<StartupNotifier, StartupState>(
  StartupNotifier.new,
);

/// Decides what the app shows first. It lives in the user-scoped root, so a
/// change of user (sign-in, sign-out, recovery) builds a fresh instance.
///
/// Invariants:
/// - an existing session is never replaced: with one present, startup only
///   loads its profile;
/// - without one, nothing is created until the user taps "Get started"; the
///   recovery branch never reaches [continueWithoutRegistration];
/// - interrupted cleanups (account deletion, user switch) run first, and an
///   anonymous account is not created while one is still unresolved.
class StartupNotifier extends Notifier<StartupState> {
  StartupPort get _port => ref.read(startupPortProvider);

  bool _cleanupDone = false;

  @override
  StartupState build() {
    Future.microtask(_resolve);
    return const StartupResolving();
  }

  Future<void> retry() async {
    if (state is StartupFailed) await _resolve();
  }

  /// "Get started": the only place an anonymous user is created.
  Future<void> continueWithoutRegistration() async {
    // Ignores a second tap, and any call outside the welcome state.
    if (state is! StartupWelcome) return;
    state = const StartupSigningIn();

    if (!_cleanupDone) _cleanupDone = await _tryCleanup();
    if (!ref.mounted) return;
    if (!_cleanupDone) {
      state = StartupFailed(StateError('Cleanup is still pending.'));
      return;
    }
    // A session appeared meanwhile: never replace it.
    if (!_port.hasSession) {
      try {
        await _port.signInAnonymously();
      } catch (e) {
        if (ref.mounted) state = StartupFailed(e);
        return;
      }
    }
    // The new user normally replaces this whole scope; only continue if not.
    if (!ref.mounted) return;
    await _loadProfile();
  }

  Future<void> _resolve() async {
    if (!ref.mounted) return;
    state = const StartupResolving();
    _cleanupDone = await _tryCleanup();
    if (!ref.mounted) return;
    if (!_port.hasSession) {
      state = const StartupWelcome();
      return;
    }
    await _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _port.loadProfile();
      if (!ref.mounted) return;
      state = StartupReady(profile);
      _syncPush(profile);
    } catch (e) {
      if (ref.mounted) state = StartupFailed(e);
    }
  }

  // Push registration is housekeeping: it never delays or fails startup, and
  // a failure is simply retried at the next launch. A user in the middle of
  // being deleted gets nothing registered.
  void _syncPush(Profile profile) {
    if (profile.accountState != 'active') return;
    _port.syncPushRegistration(profile).then<void>((_) {}, onError: (_) {});
  }

  // A failed cleanup does not block an existing session (it is retried next
  // launch) but does block creating a new anonymous one.
  Future<bool> _tryCleanup() async {
    try {
      await _port.resumePendingCleanup();
      return true;
    } catch (_) {
      return false;
    }
  }
}
