import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';

/// Phase B: theme-foundation contracts. These pin semantic token values and
/// state coverage intentionally — not for pixel-perfect matching, but because
/// the whole point of this phase is that these are now design-system
/// contracts, not incidental Material defaults.
void main() {
  final colorScheme = appTheme.colorScheme;
  final tokens = AppTokens.light;

  group('semantic text colors', () {
    test('secondary text is pinned, not auto-derived from the seed', () {
      expect(colorScheme.onSurfaceVariant, const Color(0xFF5C5F55));
    });

    test('tertiary text token exists and is distinct from secondary', () {
      expect(tokens.textTertiary, const Color(0xFF8D8F83));
      expect(tokens.textTertiary, isNot(colorScheme.onSurfaceVariant));
    });

    test('primary stays the shipped richer green, not the seed', () {
      expect(colorScheme.primary, const Color(0xFF1B6B48));
    });
  });

  group('surfaces', () {
    test('a real white surface exists', () {
      expect(colorScheme.surfaceBright, const Color(0xFFFFFFFF));
    });

    test('ground and the white surface are distinct tokens', () {
      expect(colorScheme.surface, isNot(colorScheme.surfaceBright));
    });

    test(
      'dialogs and sheets resolve to a surface distinct from the ground',
      () {
        // Visual pivot (docs/new_design): the scaffold ground is transparent
        // so the single shell-root `AppBackground` shows through instead of
        // a flat colour — see `appFlatBackgroundFallback` for the handful of
        // screens that render outside the shell and opt back into a flat
        // ground explicitly.
        expect(appTheme.scaffoldBackgroundColor, Colors.transparent);
        expect(
          appTheme.dialogTheme.backgroundColor,
          isNot(colorScheme.surface),
        );
        expect(
          appTheme.bottomSheetTheme.backgroundColor,
          isNot(colorScheme.surface),
        );
        // Both modal surfaces agree with each other.
        expect(
          appTheme.dialogTheme.backgroundColor,
          appTheme.bottomSheetTheme.backgroundColor,
        );
      },
    );
  });

  group('outline / divider', () {
    test('ColorScheme.outline matches the divider color everywhere else', () {
      expect(colorScheme.outline, appTheme.dividerTheme.color);
      final cardSide =
          (appTheme.cardTheme.shape! as RoundedRectangleBorder).side;
      expect(cardSide.color, colorScheme.outline);
    });

    test('OutlinedButton borders with the same outline token', () {
      final side = appTheme.outlinedButtonTheme.style!.side!.resolve(
        <WidgetState>{},
      );
      expect(side!.color, colorScheme.outline);
    });
  });

  group('InputDecorationTheme — complete border-state model', () {
    final theme = appTheme.inputDecorationTheme;

    test('every state is defined, not falling back to a different shape', () {
      final borders = <InputBorder?>[
        theme.border,
        theme.enabledBorder,
        theme.focusedBorder,
        theme.errorBorder,
        theme.focusedErrorBorder,
        theme.disabledBorder,
      ];
      for (final border in borders) {
        expect(border, isNotNull);
        expect(border, isA<OutlineInputBorder>());
      }
    });

    test('all states share the same corner radius', () {
      final radii = <InputBorder?>[
        theme.border,
        theme.enabledBorder,
        theme.focusedBorder,
        theme.errorBorder,
        theme.focusedErrorBorder,
        theme.disabledBorder,
      ].map((b) => (b! as OutlineInputBorder).borderRadius.topLeft.x).toSet();
      expect(radii, hasLength(1), reason: 'shape must not drift by state');
    });

    test('focused and error states are visibly distinct from enabled', () {
      final enabled = theme.enabledBorder! as OutlineInputBorder;
      final focused = theme.focusedBorder! as OutlineInputBorder;
      final error = theme.errorBorder! as OutlineInputBorder;
      expect(focused.borderSide.color, isNot(enabled.borderSide.color));
      expect(error.borderSide.color, isNot(enabled.borderSide.color));
      expect(error.borderSide.color, isNot(focused.borderSide.color));
    });
  });

  group('borderless input pattern', () {
    test(
      'every border slot is none, so a feature only overrides what it needs',
      () {
        expect(kBorderlessInputDecoration.border, InputBorder.none);
        expect(kBorderlessInputDecoration.enabledBorder, InputBorder.none);
        expect(kBorderlessInputDecoration.focusedBorder, InputBorder.none);
        expect(kBorderlessInputDecoration.errorBorder, InputBorder.none);
        expect(kBorderlessInputDecoration.focusedErrorBorder, InputBorder.none);
        expect(kBorderlessInputDecoration.disabledBorder, InputBorder.none);
      },
    );

    test('adding back only a focus indicator keeps every other state none', () {
      final decoration = kBorderlessInputDecoration.copyWith(
        focusedBorder: const UnderlineInputBorder(),
      );
      expect(decoration.enabledBorder, InputBorder.none);
      expect(decoration.errorBorder, InputBorder.none);
      expect(decoration.disabledBorder, InputBorder.none);
      expect(decoration.focusedBorder, isA<UnderlineInputBorder>());
    });
  });

  group('CheckboxTheme', () {
    test('selected resolves to primary, unselected to transparent', () {
      final fillColor = appTheme.checkboxTheme.fillColor!;
      expect(
        fillColor.resolve(<WidgetState>{WidgetState.selected}),
        colorScheme.primary,
      );
      expect(fillColor.resolve(<WidgetState>{}), Colors.transparent);
    });

    test('disabled is visibly muted, not identical to enabled', () {
      final fillColor = appTheme.checkboxTheme.fillColor!;
      final disabled = fillColor.resolve(<WidgetState>{WidgetState.disabled});
      final unselected = fillColor.resolve(<WidgetState>{});
      expect(disabled, isNot(unselected));
    });
  });

  group('SegmentedButtonTheme', () {
    testWidgets('renders without overflow at 2.0x text scale', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: MaterialApp(
            theme: appTheme,
            home: Scaffold(
              body: Center(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('7 days')),
                    ButtonSegment(value: 1, label: Text('30 days')),
                    ButtonSegment(value: 2, label: Text('All time')),
                  ],
                  selected: const {0},
                  onSelectionChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('AppBarTheme', () {
    testWidgets(
      'title is the visual-pivot foundation style (docs/new_design)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: Scaffold(appBar: AppBar(title: const Text('Shopping'))),
          ),
        );

        final text = tester.widget<Text>(find.text('Shopping'));
        final resolvedStyle = DefaultTextStyle.of(
          tester.element(find.text('Shopping')),
        ).style.merge(text.style);

        // Phase 0 of the visual pivot intentionally overrides the title
        // style (bigger/bolder, matching the reference's large rounded
        // titles) instead of following the M3 default `titleLarge` — this
        // replaces the prior "no override" contract.
        expect(resolvedStyle.fontSize, 28.0);
        expect(resolvedStyle.fontWeight, FontWeight.w800);
        expect(resolvedStyle.color, colorScheme.onSurface);
      },
    );

    test('background is transparent so AppBackground shows through', () {
      expect(appTheme.appBarTheme.backgroundColor, Colors.transparent);
      expect(appTheme.appBarTheme.scrolledUnderElevation, 0);
    });
  });

  test('fontFamily is Nunito', () {
    expect(appTheme.textTheme.bodyMedium!.fontFamily, 'Nunito');
  });
}
