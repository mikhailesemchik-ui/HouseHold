import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/app.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';

void main() {
  testWidgets('app renders startup loading screen on launch', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Simulate slow profile load so we stay on startup screen
          currentProfileProvider.overrideWith(
            (ref) => Future<Profile>.delayed(const Duration(seconds: 60)),
          ),
        ],
        child: const App(),
      ),
    );
    await tester.pump();
    // Startup screen shows a loading indicator, not a login form
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Sign up'), findsNothing);
  });
}
