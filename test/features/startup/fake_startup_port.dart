import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/startup/data/startup_port.dart';

Profile fakeStartupProfile() => Profile(
  userId: 'uid-1',
  publicId: 'ABCD-1234',
  displayName: 'User-ABCD',
  createdAt: DateTime(2026),
);

/// In-memory [StartupPort]. `calls` records every outside effect in order, so
/// tests can assert what startup did (and did not) do.
class FakeStartupPort implements StartupPort {
  FakeStartupPort({
    this.hasSession = true,
    this.onLoad,
    this.cleanupError,
    this.signInError,
    this.onResume,
    this.onSignIn,
  });

  @override
  bool hasSession;

  Future<Profile> Function()? onLoad;
  Object? cleanupError;
  Object? signInError;
  Future<void> Function()? onResume;
  Future<void> Function()? onSignIn;

  final calls = <String>[];

  @override
  Future<void> resumePendingCleanup() async {
    calls.add('resumePendingCleanup');
    await onResume?.call();
    if (cleanupError != null) throw cleanupError!;
  }

  @override
  Future<void> signInAnonymously() async {
    calls.add('signInAnonymously');
    await onSignIn?.call();
    if (signInError != null) throw signInError!;
    hasSession = true;
  }

  Object? syncError;

  @override
  Future<void> syncPushRegistration(Profile profile) async {
    calls.add('syncPush:${profile.userId}');
    if (syncError != null) throw syncError!;
  }

  @override
  Future<Profile> loadProfile() async {
    calls.add('loadProfile');
    return (onLoad ?? () async => fakeStartupProfile())();
  }
}
