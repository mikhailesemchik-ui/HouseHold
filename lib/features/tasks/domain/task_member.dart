import 'package:flutter/foundation.dart';

/// A household member as needed for task assignment display.
/// Slim subset of the full profile — only what the tasks feature requires.
@immutable
class TaskMember {
  const TaskMember({
    required this.userId,
    required this.displayName,
    required this.publicId,
  });

  final String userId;
  final String displayName;
  final String publicId;

  factory TaskMember.fromMap(Map<String, dynamic> map) {
    final profile = map['profiles'] as Map<String, dynamic>;
    return TaskMember(
      userId: map['user_id'] as String,
      displayName: profile['display_name'] as String,
      publicId: profile['public_id'] as String,
    );
  }
}
