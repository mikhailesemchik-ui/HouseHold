import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The root of the app's state, keyed by the signed-in user id.
///
/// Every provider, cached value, stream subscription and pending notifier lives
/// in the `ProviderScope` below. When the user id changes (sign-in, sign-out,
/// recovery, switching) the scope gets a new key, so Flutter disposes the whole
/// old container (cancelling its Realtime streams and dropping its caches) and
/// builds a fresh one: nothing of user A can be read by user B, even for a
/// frame. A token refresh or profile update keeps the same user id and so
/// keeps the scope.
///
/// A nested `ProviderScope` would NOT do this: providers it does not override
/// still resolve to the parent container's cached state.
///
/// What lives outside the container is handled elsewhere: device state
/// (reminders, widget, push token) by `SessionSwitchCoordinator` and the
/// startup cleanup; pending financial request ids are stored per user id; the
/// global router is reset through [onUserChanged].
class UserScopedRoot extends StatefulWidget {
  const UserScopedRoot({
    super.key,
    required this.initialUserId,
    required this.userIdChanges,
    required this.onUserChanged,
    required this.child,
    this.retry,
    this.overrides = const [],
  });

  /// The signed-in user at launch, or null with no session.
  final String? initialUserId;

  /// The signed-in user id after every auth event (null when signed out).
  /// Repeats of the same id are ignored here.
  final Stream<String?> userIdChanges;

  /// Called synchronously when the user id changes, in the same frame as the
  /// scope swap, to put the router back at the startup route.
  final VoidCallback onUserChanged;

  final Widget child;
  final Duration? Function(int retryCount, Object error)? retry;
  final List<Override> overrides;

  @override
  State<UserScopedRoot> createState() => _UserScopedRootState();
}

class _UserScopedRootState extends State<UserScopedRoot> {
  late String? _userId = widget.initialUserId;
  StreamSubscription<String?>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.userIdChanges.listen(_onUserId);
  }

  void _onUserId(String? userId) {
    if (userId == _userId || !mounted) return;
    widget.onUserChanged();
    setState(() => _userId = userId);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: ValueKey<String>('user:${_userId ?? 'none'}'),
      retry: widget.retry,
      overrides: widget.overrides,
      child: widget.child,
    );
  }
}
