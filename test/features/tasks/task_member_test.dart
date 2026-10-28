import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';

void main() {
  group('TaskMember.fromMap', () {
    test('reads a valid profile', () {
      final m = TaskMember.fromMap({
        'user_id': 'u1',
        'profiles': {'display_name': 'Anna', 'public_id': 'P1'},
      });
      expect(m.displayName, 'Anna');
      expect(m.publicId, 'P1');
    });

    test('a missing joined profile does not throw', () {
      final m = TaskMember.fromMap({'user_id': 'u1', 'profiles': null});
      expect(m.userId, 'u1');
      expect(m.displayName, 'Someone');
      expect(m.publicId, '');
    });

    test('null or empty names get a neutral label', () {
      for (final name in [null, '', '  ']) {
        final m = TaskMember.fromMap({
          'user_id': 'u1',
          'profiles': {'display_name': name, 'public_id': 'P1'},
        });
        expect(m.displayName, 'Someone');
      }
    });

    test('a deleted profile is anonymized', () {
      final m = TaskMember.fromMap({
        'user_id': 'u1',
        'profiles': {
          'display_name': 'Deleted member',
          'public_id': 'DELETED-x',
          'account_state': 'deleted',
        },
      });
      expect(m.displayName, 'Deleted member');
    });
  });

  group('taskAssigneeLabel', () {
    const anna = TaskMember(userId: 'u1', displayName: 'Anna', publicId: 'P1');

    test('no assignee is Unassigned', () {
      expect(taskAssigneeLabel([anna], null), 'Unassigned');
      expect(taskAssigneeLabel(null, null), 'Unassigned');
    });

    test('an active assignee shows their name', () {
      expect(taskAssigneeLabel([anna], 'u1'), 'Anna');
    });

    test('an assignee missing from the list is not shown as Unassigned', () {
      expect(taskAssigneeLabel([anna], 'gone'), 'Assigned');
    });

    test('an unavailable member list says nothing more about the assignee', () {
      expect(taskAssigneeLabel(null, 'u1'), 'Assigned');
    });
  });

  group('checkAssigneeSave', () {
    const anna = TaskMember(userId: 'u1', displayName: 'Anna', publicId: 'P1');

    test('none and active members save as they are', () {
      expect(checkAssigneeSave([anna], null), AssigneeSaveOutcome.save);
      expect(checkAssigneeSave([anna], 'u1'), AssigneeSaveOutcome.save);
      expect(checkAssigneeSave(null, null), AssigneeSaveOutcome.save);
    });

    test('a stale assignee needs confirmation, even with an empty list', () {
      expect(
        checkAssigneeSave([anna], 'gone'),
        AssigneeSaveOutcome.confirmClear,
      );
      expect(checkAssigneeSave([], 'gone'), AssigneeSaveOutcome.confirmClear);
    });

    test('an unavailable list is not an empty list', () {
      expect(checkAssigneeSave(null, 'u1'), AssigneeSaveOutcome.unavailable);
    });
  });
}
