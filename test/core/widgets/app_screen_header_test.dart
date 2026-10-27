import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_bar_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';

Widget _header({required String title, bool centerTitle = true}) => MaterialApp(
  home: Scaffold(
    body: AppScreenHeader(
      leading: const Center(child: SizedBox(width: 48, height: 48)),
      title: title,
      centerTitle: centerTitle,
      actions: const [SizedBox(width: 48, height: 48)],
    ),
  ),
);

void main() {
  testWidgets('centerTitle centers the title on the header width', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'Home'));
    final title = tester.getCenter(find.text('Home')).dx;
    expect(
      title,
      closeTo(tester.getSize(find.byType(AppScreenHeader)).width / 2, 0.5),
    );
  });

  testWidgets('without centerTitle the title stays left-aligned', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'Home', centerTitle: false));
    expect(
      tester.getTopLeft(find.text('Home')).dx,
      closeTo(AppBarMetrics.leadingWidth + AppBarMetrics.titleSpacing, 0.5),
    );
  });

  testWidgets('a long centered title ellipsizes without touching controls', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'A very long household name ' * 4));
    final box = tester.getRect(find.byType(Text));
    final width = tester.getSize(find.byType(AppScreenHeader)).width;
    expect(box.left, greaterThanOrEqualTo(AppBarMetrics.leadingWidth));
    expect(box.right, lessThanOrEqualTo(width - AppBarMetrics.leadingWidth));
  });

  for (final width in [337.0, 360.0, 414.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final withAction in [true, false]) {
        testWidgets(
          'centred compact title stays centred and fits at ${width}dp / '
          '${scale}x ${withAction ? 'with' : 'without'} an action',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 800),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: AppScreenHeader(
                      leading: const Center(
                        child: SizedBox(width: 56, height: 56),
                      ),
                      title: 'Statistics',
                      centerTitle: true,
                      compactTitle: true,
                      actions: withAction
                          ? const [SizedBox(width: 56, height: 56)]
                          : const [],
                    ),
                  ),
                ),
              ),
            );

            expect(tester.takeException(), isNull);
            final box = tester.getRect(find.text('Statistics'));
            // Geometrically centred whether or not an action exists.
            expect(box.center.dx, closeTo(width / 2, 1));
            // Never reaches into the leading or trailing slot.
            expect(box.left, greaterThanOrEqualTo(AppBarMetrics.leadingWidth));
            expect(
              box.right,
              lessThanOrEqualTo(width - AppBarMetrics.leadingWidth),
            );
            // The title stays inside the fixed-height toolbar row at any
            // text scale instead of growing the header.
            expect(box.top, greaterThanOrEqualTo(0));
            expect(box.bottom, lessThanOrEqualTo(AppBarMetrics.toolbarHeight));
          },
        );
      }
    }
  }

  group('long centred title beside a text action (real Nunito metrics)', () {
    setUpAll(() async {
      final loader = FontLoader('Nunito');
      for (final weight in ['Regular', 'ExtraBold']) {
        final bytes = File('assets/fonts/Nunito-$weight.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    });

    Future<Rect> pumpRecord(
      WidgetTester tester,
      double width, {
      double scale = 1,
      double actionWidth = 72,
    }) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: AppScreenHeader(
                leading: const Center(child: SizedBox(width: 56, height: 56)),
                title: 'Record settlement',
                centerTitle: true,
                compactTitle: true,
                actions: [SizedBox(width: actionWidth, height: 48)],
              ),
            ),
          ),
        ),
      );
      return tester.getRect(find.text('Record\nsettlement'));
    }

    for (final width in [337.0, 360.0, 414.0]) {
      testWidgets('is centred on two lines at ${width}dp', (tester) async {
        final box = await pumpRecord(tester, width);
        expect(box.center.dx, closeTo(width / 2, 1));
        expect(tester.takeException(), isNull);
        // Two lines inside the 72dp toolbar, not shrunk to a sliver.
        expect(box.height, lessThanOrEqualTo(AppBarMetrics.toolbarHeight));
        expect(box.height, greaterThan(50));
      });
    }

    testWidgets('large text uses the free space instead of shrinking to the '
        'centre', (tester) async {
      final box = await pumpRecord(tester, 360, scale: 2, actionWidth: 160);
      expect(tester.takeException(), isNull);
      expect(box.left, greaterThanOrEqualTo(AppBarMetrics.leadingWidth));
      expect(box.right, lessThanOrEqualTo(360 - 160));
      expect(box.width, greaterThan(60));
    });
  });
}
