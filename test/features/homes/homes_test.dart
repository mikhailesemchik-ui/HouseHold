import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_invite.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/homes_screen.dart';

void main() {
  group('Household.validateName', () {
    test('returns error for empty string', () {
      expect(Household.validateName(''), isNotNull);
    });

    test('returns error for whitespace-only string', () {
      expect(Household.validateName('   '), isNotNull);
    });

    test('returns null for a valid name', () {
      expect(Household.validateName('My Home'), isNull);
    });

    test('returns null for a single-character name', () {
      expect(Household.validateName('A'), isNull);
    });
  });

  group('HouseholdInvite.isActive', () {
    final now = DateTime.now();

    test('is active when not revoked and no expiry', () {
      final invite = HouseholdInvite(
        id: '1',
        householdId: '2',
        code: 'ABCD-EFGH',
        createdBy: '3',
        createdAt: now,
      );
      expect(invite.isActive, isTrue);
    });

    test('is not active when revoked', () {
      final invite = HouseholdInvite(
        id: '1',
        householdId: '2',
        code: 'ABCD-EFGH',
        createdBy: '3',
        createdAt: now,
        revokedAt: now,
      );
      expect(invite.isActive, isFalse);
    });

    test('is not active when expired', () {
      final invite = HouseholdInvite(
        id: '1',
        householdId: '2',
        code: 'ABCD-EFGH',
        createdBy: '3',
        createdAt: now,
        expiresAt: now.subtract(const Duration(hours: 1)),
      );
      expect(invite.isActive, isFalse);
    });

    test('is active when expiry is in the future', () {
      final invite = HouseholdInvite(
        id: '1',
        householdId: '2',
        code: 'ABCD-EFGH',
        createdBy: '3',
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      expect(invite.isActive, isTrue);
    });
  });

  group('HouseholdRepository.normalizeInviteCode', () {
    test('uppercases lowercase letters', () {
      expect(HouseholdRepository.normalizeInviteCode('abcd-efgh'), 'ABCD-EFGH');
    });

    test('inserts dash when 8 alphanumeric chars are given without one', () {
      expect(HouseholdRepository.normalizeInviteCode('ABCDEFGH'), 'ABCD-EFGH');
    });

    test('strips spaces and inserts dash', () {
      expect(HouseholdRepository.normalizeInviteCode('abcd efgh'), 'ABCD-EFGH');
    });

    test('strips mixed extra punctuation', () {
      expect(
        HouseholdRepository.normalizeInviteCode(' abcd - efgh '),
        'ABCD-EFGH',
      );
    });

    test('leaves already canonical code unchanged', () {
      expect(HouseholdRepository.normalizeInviteCode('ABCD-EFGH'), 'ABCD-EFGH');
    });

    test('leaves short input unchanged without adding dash', () {
      expect(HouseholdRepository.normalizeInviteCode('ABC'), 'ABC');
    });
  });

  group('HouseholdRepository.validateInviteCode', () {
    test('returns null for a valid canonical code', () {
      expect(HouseholdRepository.validateInviteCode('ABCD-EFGH'), isNull);
    });

    test('returns null for a valid lowercase code (normalizes internally)', () {
      expect(HouseholdRepository.validateInviteCode('abcd-efgh'), isNull);
    });

    test('returns null for a code without dash (normalizes internally)', () {
      expect(HouseholdRepository.validateInviteCode('ABCDEFGH'), isNull);
    });

    test('returns error for empty input', () {
      expect(HouseholdRepository.validateInviteCode(''), isNotNull);
    });

    test('returns error for too-short code', () {
      expect(HouseholdRepository.validateInviteCode('ABCD'), isNotNull);
    });

    test('returns error for too-long code', () {
      expect(HouseholdRepository.validateInviteCode('ABCDEFGHI'), isNotNull);
    });
  });

  group('HomesScreen widget', () {
    Widget buildHomesScreen(List<Household> homes) {
      return ProviderScope(
        overrides: [
          homesProvider.overrideWith(() => _FakeHomesNotifier(homes)),
          for (final h in homes)
            householdSummaryProvider(h.id).overrideWith(
              (ref) async => const HouseholdSummary(
                incompleteTaskCount: 2,
                incompleteShoppingCount: 0,
                expenseCount: 0,
                activeMemberCount: 3,
              ),
            ),
        ],
        child: MaterialApp(theme: appTheme, home: const HomesScreen()),
      );
    }

    testWidgets('renders a very long household name without overflow', (
      tester,
    ) async {
      final longName =
          'The Extended Family Household At The End Of The Long Street '
          'With Many Members And A Very Descriptive Name';
      await tester.pumpWidget(
        buildHomesScreen([
          Household(
            id: 'hh-1',
            name: longName,
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
        ]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('The Extended Family'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows real per-household metadata as a row destination', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHomesScreen([
          Household(
            id: 'hh-1',
            name: 'Main Home',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
        ]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Main Home'), findsOneWidget);
      expect(find.text('2 tasks · 3 members'), findsOneWidget);
      // Row-based, not a Card: no elevated Card should wrap the destination.
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('renders several households as a scannable list', (
      tester,
    ) async {
      final homes = [
        for (var i = 0; i < 6; i++)
          Household(
            id: 'hh-$i',
            name: 'Home $i',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
      ];
      await tester.pumpWidget(buildHomesScreen(homes));
      await tester.pump();
      await tester.pump();

      for (var i = 0; i < 6; i++) {
        expect(find.text('Home $i'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('many households at 2.0x text scale does not overflow', (
      tester,
    ) async {
      final homes = [
        for (var i = 0; i < 6; i++)
          Household(
            id: 'hh-$i',
            name: 'Home $i',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
      ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2.0),
          ),
          child: buildHomesScreen(homes),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'empty state stays scrollable and reachable at a large text scale',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(2.0),
            ),
            child: buildHomesScreen(const []),
          ),
        );
        await tester.pump();
        await tester.pump();
        // Let the loading→empty state transition finish before inspecting
        // the tree — mid-transition, the outgoing and incoming states are
        // briefly mounted together.
        await tester.pumpAndSettle();

        // Previously a non-scrolling centred Column: at this scale the copy
        // plus both actions exceed a short viewport and overflowed.
        expect(tester.takeException(), isNull);
        expect(find.byType(SingleChildScrollView), findsWidgets);

        // Both actions must remain reachable by scrolling.
        await tester.scrollUntilVisible(find.text('Join home'), 100);
        expect(find.text('Join home'), findsOneWidget);
      },
    );
  });
}

class _FakeHomesNotifier extends HomesNotifier {
  _FakeHomesNotifier(this._homes);

  final List<Household> _homes;

  @override
  Future<List<Household>> build() async => _homes;
}
