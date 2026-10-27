import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_member_info.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/household_detail_screen.dart';
import 'package:household_os/features/homes/presentation/widgets/delete_household_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

const _name = 'Test Home';

Widget _dialogHost(
  Future<void> Function() onDelete, {
  void Function(bool)? onResult,
}) {
  return MaterialApp(
    theme: appTheme,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showDeleteHouseholdDialog(
              context,
              householdName: _name,
              onDelete: onDelete,
              errorMessage: (e) => e is PostgrestException
                  ? 'Only the owner can delete this home.'
                  : 'Failed to delete home. Please try again.',
            );
            onResult?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Finder get _deleteButton => find.byType(FilledButton);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_deleteButton).onPressed != null;

void main() {
  group('delete household dialog', () {
    testWidgets('states what is deleted and keeps Delete disabled at first', (
      tester,
    ) async {
      await tester.pumpWidget(_dialogHost(() async {}));
      await _open(tester);

      expect(find.textContaining('permanently deleted'), findsOneWidget);
      expect(find.textContaining('Test Home'), findsOneWidget);
      expect(_enabled(tester), isFalse);
    });

    testWidgets('only an exact name enables Delete', (tester) async {
      await tester.pumpWidget(_dialogHost(() async {}));
      await _open(tester);

      await tester.enterText(find.byType(TextField), 'test home');
      await tester.pump();
      expect(_enabled(tester), isFalse);

      await tester.enterText(find.byType(TextField), 'Test Hom');
      await tester.pump();
      expect(_enabled(tester), isFalse);

      await tester.enterText(find.byType(TextField), _name);
      await tester.pump();
      expect(_enabled(tester), isTrue);
    });

    testWidgets('Cancel closes without deleting', (tester) async {
      var deletes = 0;
      bool? result;
      await tester.pumpWidget(
        _dialogHost(() async => deletes++, onResult: (r) => result = r),
      );
      await _open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(deletes, 0);
      expect(result, isFalse);
      expect(find.text('Delete home?'), findsNothing);
    });

    testWidgets('a confirmed deletion runs once and reports success', (
      tester,
    ) async {
      var deletes = 0;
      bool? result;
      await tester.pumpWidget(
        _dialogHost(() async => deletes++, onResult: (r) => result = r),
      );
      await _open(tester);
      await tester.enterText(find.byType(TextField), _name);
      await tester.pump();
      await tester.tap(_deleteButton);
      await tester.pumpAndSettle();

      expect(deletes, 1);
      expect(result, isTrue);
      expect(find.text('Delete home?'), findsNothing);
    });

    testWidgets('a second tap while deleting is ignored and a spinner shows', (
      tester,
    ) async {
      var deletes = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        _dialogHost(() {
          deletes++;
          return gate.future;
        }),
      );
      await _open(tester);
      await tester.enterText(find.byType(TextField), _name);
      await tester.pump();
      await tester.tap(_deleteButton);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_enabled(tester), isFalse);
      await tester.tap(_deleteButton, warnIfMissed: false);
      await tester.pump();
      expect(deletes, 1);

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a failure keeps the dialog open with a message', (
      tester,
    ) async {
      var attempts = 0;
      await tester.pumpWidget(
        _dialogHost(() async {
          attempts++;
          throw PostgrestException(message: 'denied', code: 'HD002');
        }),
      );
      await _open(tester);
      await tester.enterText(find.byType(TextField), _name);
      await tester.pump();
      await tester.tap(_deleteButton);
      await tester.pumpAndSettle();

      expect(find.text('Only the owner can delete this home.'), findsOneWidget);
      expect(find.text('Delete home?'), findsOneWidget);
      expect(_enabled(tester), isTrue);

      await tester.tap(_deleteButton);
      await tester.pumpAndSettle();
      expect(attempts, 2);
    });
  });

  group('Delete home menu entry', () {
    final household = Household(
      id: 'hh',
      name: _name,
      createdBy: 'owner-1',
      createdAt: DateTime.utc(2026, 10, 27),
    );

    HouseholdMemberInfo member(String id, String role) => HouseholdMemberInfo(
      userId: id,
      displayName: id,
      publicId: 'P-$id',
      role: role,
      joinedAt: DateTime.utc(2026, 10, 27),
    );

    Widget screen({required String userId}) {
      return ProviderScope(
        overrides: [
          householdByIdProvider('hh').overrideWith((ref) async => household),
          householdInvitesProvider('hh').overrideWith((ref) async => []),
          householdMembersProvider('hh').overrideWith(
            (ref) async => [
              member('owner-1', 'owner'),
              member('member-1', 'member'),
            ],
          ),
          householdSummaryProvider('hh').overrideWith(
            (ref) async => const HouseholdSummary(
              incompleteTaskCount: 0,
              incompleteShoppingCount: 0,
              expenseCount: 0,
              activeMemberCount: 2,
            ),
          ),
          householdRecentActivityProvider('hh').overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          theme: appTheme,
          home: HouseholdDetailScreen(
            householdId: 'hh',
            currentUserIdOverride: userId,
          ),
        ),
      );
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Home actions'));
      await tester.pumpAndSettle();
    }

    testWidgets('the owner sees Delete home next to Leave home', (
      tester,
    ) async {
      await tester.pumpWidget(screen(userId: 'owner-1'));
      await tester.pumpAndSettle();
      await openMenu(tester);

      expect(find.text('Leave home'), findsOneWidget);
      expect(find.text('Delete home'), findsOneWidget);
    });

    testWidgets('a regular member only sees Leave home', (tester) async {
      await tester.pumpWidget(screen(userId: 'member-1'));
      await tester.pumpAndSettle();
      await openMenu(tester);

      expect(find.text('Leave home'), findsOneWidget);
      expect(find.text('Delete home'), findsNothing);
    });

    testWidgets('choosing Delete home opens the name confirmation', (
      tester,
    ) async {
      await tester.pumpWidget(screen(userId: 'owner-1'));
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.text('Delete home'));
      await tester.pumpAndSettle();

      expect(find.text('Delete home?'), findsOneWidget);
      expect(find.text('Home name'), findsOneWidget);
    });
  });
}
