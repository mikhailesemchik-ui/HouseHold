# Development setup

How to run Household OS against your own Supabase and Firebase projects. The app needs a Supabase
backend with this repository's migrations applied; `flutter run` alone does not create one.

Everything below comes from the repository. Steps that depend on your own accounts (project
creation, key management) are described in general terms.

## 1. Flutter app

Requirements: Flutter stable (3.47 or newer) and an Android SDK.

```bash
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable-or-anon-key>
```

`lib/core/config/app_config.dart` reads both values with `String.fromEnvironment` and throws at
startup if either is missing. To keep them out of shell history, put them in a JSON file and pass
`--dart-define-from-file=<file>`. `.env.*` is git-ignored, so `.env.hosted.json` is a safe name.

Use the publishable or anon key only. Never put the service-role key in the app.

Release builds are signed with `android/key.properties`, which is git-ignored. Without that file the
release build falls back to the debug key, so it is not suitable for distribution.

## 2. Supabase project

1. Create a Supabase project and link it with the Supabase CLI (`supabase link --project-ref <ref>`).
2. Enable anonymous sign-ins in the project's Auth settings; the app creates accounts that way.
3. Enable the `pg_cron` extension before applying migrations. Migration
   `20261107000002_account_reconciliation_schedule.sql` fails on purpose when `pg_cron` is missing or
   `cron.database_name` is not the project database. It schedules the `account-deletion-reconcile`
   job, which runs every five minutes.
4. Apply the migrations in `supabase/migrations` (`supabase db push`).

The SQL and shell tests in `supabase/tests` are written for a local Supabase stack and are not
needed to run the app.

## 3. Edge Functions

Two functions live in `supabase/functions`. Deploy them with JWT verification left on:

```bash
supabase functions deploy delete-account --project-ref <ref> --use-api
supabase functions deploy process-notification-outbox --project-ref <ref> --use-api
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided by the platform.
Set the rest with `supabase secrets set`:

| Secret | Used by | Purpose |
|---|---|---|
| `PUSH_WORKER_INVOKE_SECRET` | `process-notification-outbox` | Shared secret the caller sends in the `X-Worker-Secret` header. The function returns 500 if it is shorter than 32 characters. |
| `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL`, `FCM_PRIVATE_KEY` | `process-notification-outbox` | Firebase service-account values for FCM HTTP v1 (Android). |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY`, `APNS_PRODUCTION` | `process-notification-outbox` | APNs delivery for iOS. iOS push is untested. |

`delete-account` needs no extra secrets.

## 4. Push notifications

- Replace `android/app/google-services.json` with the file from your own Firebase project and keep
  the package name `com.household.household_os`.
- The migrations create the `notification_outbox` table and the functions that claim and complete
  rows. They do **not** schedule the worker. Something has to call `process-notification-outbox`
  with a POST that carries a valid project JWT in `Authorization` and the secret in
  `X-Worker-Secret`. The reference deployment does this with `pg_cron` and `pg_net`, reading both
  values from Supabase Vault. That scheduler is configured by hand and is not part of the repository.
- Do not send the service-role key from a scheduler. The function does not accept it.

## 5. Checks

```bash
flutter analyze
flutter test
node --test supabase/functions/process-notification-outbox/auth.test.ts
```

The Flutter commands also run in [CI](../.github/workflows/ci.yml). The Node test covers the push
worker's authentication and does not run in CI.
