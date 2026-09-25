# household_os

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Build and run

Requires Flutter (stable) and an Android SDK. The app reads its Supabase
project from compile-time defines; a build without them fails at startup:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` (the publishable client key, not a server secret)

Firebase client config is committed at `android/app/google-services.json`.

```bash
# debug run
flutter run \
  --dart-define=SUPABASE_URL=<project-url> \
  --dart-define=SUPABASE_ANON_KEY=<publishable-key>

# release APK (debug-signed, for demo use)
flutter build apk --release \
  --dart-define=SUPABASE_URL=<project-url> \
  --dart-define=SUPABASE_ANON_KEY=<publishable-key>
```
