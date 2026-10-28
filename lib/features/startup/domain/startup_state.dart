import 'package:household_os/features/profile/domain/profile.dart';

/// Where app startup is. Anonymous accounts are only ever created by the
/// user's explicit choice on the welcome screen; recovery (see
/// `recovery_flow.dart`) has its own states and never reaches this machine's
/// anonymous branch.
sealed class StartupState {
  const StartupState();
}

/// Restoring the persisted session and finishing interrupted cleanups.
final class StartupResolving extends StartupState {
  const StartupResolving();
}

/// No session on this device: the user chooses how to begin.
final class StartupWelcome extends StartupState {
  const StartupWelcome();
}

/// The user chose "Get started"; one anonymous sign-in is in flight.
final class StartupSigningIn extends StartupState {
  const StartupSigningIn();
}

/// A session exists and its profile is loaded.
final class StartupReady extends StartupState {
  const StartupReady(this.profile);

  final Profile profile;
}

/// Something recoverable failed; [error] feeds the friendly message.
final class StartupFailed extends StartupState {
  const StartupFailed(this.error);

  final Object error;
}
