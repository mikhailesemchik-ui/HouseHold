import 'package:flutter/foundation.dart';

@immutable
class Profile {
  const Profile({
    required this.userId,
    required this.publicId,
    required this.displayName,
    required this.createdAt,
    this.avatarUrl,
    this.accountState = 'active',
  });

  final String userId;
  final String publicId;
  final String displayName;
  final String? avatarUrl;
  final DateTime createdAt;

  /// 'active', or 'deleting' while an account deletion is unfinished.
  final String accountState;

  bool get isDeletionPending => accountState == 'deleting';

  factory Profile.fromMap(Map<String, dynamic> map) {
    return Profile(
      userId: map['user_id'] as String,
      publicId: map['public_id'] as String,
      displayName: map['display_name'] as String,
      avatarUrl: map['avatar_url'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      accountState: map['account_state'] as String? ?? 'active',
    );
  }
}
