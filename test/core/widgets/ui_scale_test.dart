import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_circle_icon_button.dart';
import 'package:household_os/core/widgets/app_icon_chip.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';

Widget _host(Widget child, {double width = 337, double textScale = 1}) {
  return MaterialApp(
    theme: appTheme,
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('circle button is 56dp', (tester) async {
    await tester.pumpWidget(
      _host(
        Center(
          child: AppCircleIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            onPressed: () {},
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(AppCircleIconButton));
    expect(size, const Size(56, 56));
  });

  testWidgets('icon chip defaults to 44dp', (tester) async {
    await tester.pumpWidget(
      _host(
        const Center(
          child: AppIconChip(
            icon: Icons.add,
            background: Colors.white,
            foreground: Colors.black,
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AppIconChip)), const Size(44, 44));
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('header with a long title does not overflow at ${scale}x on a '
        '337dp viewport', (tester) async {
      await tester.pumpWidget(
        _host(
          AppScreenHeader(
            leading: const Center(child: AppBackButton()),
            title: 'A very long household name that must ellipsize',
            actions: [
              AppCircleIconButton(
                icon: Icons.more_vert,
                tooltip: 'More',
                onPressed: () {},
              ),
            ],
          ),
          textScale: scale,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [337.0, 414.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('card row with long text does not overflow at ${width}dp / '
          '${scale}x', (tester) async {
        await tester.pumpWidget(
          _host(
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AppSoftCard(
                  child: Row(
                    children: [
                      const AppIconChip(
                        icon: Icons.home_rounded,
                        background: Colors.white,
                        foreground: Colors.black,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Builder(
                              builder: (context) => Text(
                                'A very long household name that wraps '
                                'across several lines',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            Builder(
                              builder: (context) => Text(
                                '12 tasks · 4 members',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 24),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () {},
                  child: const Text('A fairly long primary action label'),
                ),
              ],
            ),
            width: width,
            textScale: scale,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
