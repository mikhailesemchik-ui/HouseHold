import 'package:flutter/foundation.dart';
import 'package:household_os/core/utils/member_identity.dart';

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
    final profile = map['profiles'] as Map<String, dynamic>?;
    return TaskMember(
      userId: map['user_id'] as String,
      displayName: memberNameLabel(
        accountState: profile?['account_state'] as String?,
        displayName: profile?['display_name'] as String?,
      ),
      publicId: profile?['public_id'] as String? ?? '',
    );
  }
}

/// Label for a task's assignee. [members] is the ACTIVE member list, or null
/// while it is unavailable. An assignee missing from the list is a real
/// assignment that must not read as "Unassigned", but the list cannot say WHY
/// they are missing (left, removed, deleted, or joined after the list was
/// loaded), so the label claims nothing more than "Assigned".
String taskAssigneeLabel(List<TaskMember>? members, String? assignedTo) {
  if (assignedTo == null) return 'Unassigned';
  for (final member in members ?? const <TaskMember>[]) {
    if (member.userId == assignedTo) return member.displayName;
  }
  return 'Assigned';
}

enum AssigneeSaveOutcome {
  /// Safe to save with the selection as it is (none, or an active member).
  save,

  /// The assignee is no longer an active member. The server accepts only an
  /// active member or none, so saving means clearing the assignee on the task
  /// row; the user has to agree first.
  confirmClear,

  /// The active member list is not available (loading or failed), so the
  /// selection cannot be checked and must not be sent.
  unavailable,
}

/// Decides how to save an EXISTING task's assignee. [members] is the ACTIVE
/// member list, or null while it is unavailable; null is never read as empty.
AssigneeSaveOutcome checkAssigneeSave(
  List<TaskMember>? members,
  String? selectedId,
) {
  if (selectedId == null) return AssigneeSaveOutcome.save;
  if (members == null) return AssigneeSaveOutcome.unavailable;
  return members.any((m) => m.userId == selectedId)
      ? AssigneeSaveOutcome.save
      : AssigneeSaveOutcome.confirmClear;
}
