# CLAUDE.md

## Project

Household OS is a privacy-respecting collaborative Flutter app for managing shared households, tasks, shopping, expenses, and related household activity.

Current target platforms:
- Android
- iOS

Use English for code, filenames, comments, commits, and UI text unless a task explicitly says otherwise.

## Core Principles

Follow these rules in priority order:

1. KISS — choose the simplest correct solution.
2. YAGNI — do not build features before they are needed.
3. Single Responsibility — each class, method, and file should have one clear purpose.
4. Fail Fast — validate important assumptions and handle errors early.
5. Prefer maintainable code over clever code.
6. Do not introduce architecture, abstractions, or dependencies without a concrete need.

## Task Scope

For every task:

- Change only files required for the task.
- Do not refactor unrelated code.
- Do not rename or move unrelated files.
- Do not add speculative features.
- Do not add packages unless necessary.
- Reuse existing project patterns before introducing new ones.
- Preserve existing behavior unless the task explicitly changes it.
- Do not generate large reports or long explanations.
- If the task is clear, implement it directly without asking unnecessary questions.
- If a critical detail is genuinely missing, ask one concise question.

## Flutter and Dart Standards

- Use stable Flutter and Dart versions available in the environment.
- Use null safety.
- Use Material 3.
- Follow Effective Dart conventions.
- Format code with `dart format`.
- Keep `flutter analyze` clean.
- Prefer immutable widgets and models where practical.
- Use `const` constructors whenever valid.
- Avoid `dynamic` unless required by an external API.
- Avoid force unwraps (`!`) unless safety is guaranteed and obvious.
- Do not suppress analyzer warnings without a strong reason.
- Avoid deeply nested widget trees; extract meaningful widgets when readability improves.
- Keep UI, business logic, and data access separated.

## Naming

- Files: `snake_case.dart`
- Variables and methods: `lowerCamelCase`
- Classes, enums, typedefs: `UpperCamelCase`
- Constants: `lowerCamelCase`
- Private members: `_leadingUnderscore`
- Booleans should read clearly: `isLoading`, `hasError`, `canSubmit`

Use descriptive names. Avoid vague names such as `data`, `item`, `manager`, or `helper` when a clearer domain name exists.

## Project Structure

Use feature-first organization.

Preferred structure:

```text
lib/
  app/
    app.dart
    theme/
    routing/
  core/
    errors/
    services/
    utils/
    widgets/
  features/
    feature_name/
      data/
      domain/
      presentation/
```

Rules:

- Keep feature code inside its feature folder.
- Put shared code in `core/` only when used by multiple features.
- Do not create empty architectural layers.
- Do not introduce Clean Architecture boilerplate unless the feature complexity justifies it.
- Keep tests close in structure to the code they cover under `test/`.

## File and Method Size

Use these as guidelines, not reasons for artificial splitting:

- Prefer files under 400 lines.
- Prefer classes under 150 lines.
- Prefer methods under 40 lines.
- Prefer widget `build` methods that remain easy to scan.
- Split files when they contain multiple responsibilities.

Do not create many tiny files with no clear benefit.

## State Management

- Use the state-management approach already selected in the project.
- Do not add Riverpod, BLoC, Provider, GetX, or another solution unless explicitly required.
- Keep transient local UI state inside widgets when appropriate.
- Keep business state outside widgets when complexity requires it.
- Do not mix multiple state-management approaches without a clear reason.

## Dependencies

- Add packages only when the Flutter/Dart SDK or existing packages cannot solve the task cleanly.
- Check `pubspec.yaml` before adding anything.
- Use `flutter pub add <package>` instead of manually editing dependency versions when possible.
- Do not upgrade unrelated dependencies.
- Prefer actively maintained packages with clear documentation.
- Avoid overlapping packages that solve the same problem.

## Error Handling

- Never silently ignore failures.
- Catch only errors that can be handled meaningfully.
- Show user-friendly messages in the UI.
- Keep technical details in logs, not user-facing text.
- Preserve stack traces when rethrowing.
- Represent expected domain failures explicitly where useful.
- Handle loading, empty, success, and error states.

## Async Code

- Await futures when order or error handling matters.
- Avoid unawaited work unless intentional and documented.
- Check widget lifecycle before using `BuildContext` after async gaps.
- Prevent duplicate submissions and repeated API calls.
- Cancel subscriptions, controllers, and timers in `dispose`.

## Security

- Never commit API keys, tokens, passwords, certificates, or secrets.
- Use environment configuration for secrets.
- Do not log sensitive user data.
- Validate external input.
- Use HTTPS for remote communication.
- Store sensitive local data only with appropriate secure storage.
- Do not expose AI or backend secrets directly in the mobile client.

## Testing

Add tests when the task includes business logic, state transitions, parsing, validation, or a critical user flow.

Testing priorities:

1. Unit tests for business logic.
2. Widget tests for important UI behavior.
3. Integration tests for critical end-to-end flows.

Rules:

- Use descriptive test names.
- Test success, failure, and edge cases.
- Do not add low-value tests only to increase coverage.
- Do not rewrite unrelated tests.
- Keep tests deterministic.
- Avoid excessive mocking.

A UI-only visual adjustment does not always require a new test.

## Required Validation

Run only checks relevant to the change.

Default minimum after code changes:

```bash
dart format .
flutter analyze
```

Run tests when logic or tested behavior changed:

```bash
flutter test
```

For a narrow change, prefer a targeted test first:

```bash
flutter test test/path/to/test_file.dart
```

Do not repeatedly run expensive commands without a reason.

## Commands and Search

Use efficient commands.

Preferred:

```bash
rg "pattern"
rg --files
rg --files -g "*.dart"
```

Avoid `grep -r` and `find -name` when `rg` can do the job faster.

Before editing:

- Inspect only relevant files.
- Do not scan the entire repository unless necessary.
- Do not read generated directories such as `.dart_tool/`, `build/`, or platform build outputs.

## Generated Code

- Do not manually edit generated files.
- Regenerate them using the correct command.
- Keep generated output consistent with source annotations.
- Do not introduce code generation unless it provides clear value.

## Git Rules

- Never mention Claude, Codex, AI, or generated-by text in commit messages.
- Do not commit unless explicitly asked.
- Do not push unless explicitly asked.
- Do not rewrite Git history.
- Do not discard user changes.
- Check `git status` before destructive operations.

Commit format:

```text
<type>(<scope>): <subject>
```

Allowed types:

- `feat`
- `fix`
- `refactor`
- `test`
- `docs`
- `style`
- `chore`

## Documentation

- Keep comments concise and useful.
- Comment why, not what.
- Avoid obvious comments.
- Update README only when setup, architecture, or usage changes.
- Do not create extra documentation files unless requested.
- Document non-obvious architectural decisions briefly.

## Performance

- Do not optimize without evidence.
- Avoid unnecessary rebuilds in frequently updated UI.
- Use lazy lists for large collections.
- Avoid expensive work inside `build`.
- Cache only when there is a proven need.
- Resize and compress large images when appropriate.

## Final Response Format

Keep the final response concise.

Include only:

1. What changed.
2. Files changed.
3. Checks run and result.
4. Any unresolved issue or manual step.

Do not include:
- long tutorials;
- repeated summaries;
- full file contents unless requested;
- speculative recommendations;
- unrelated improvements.

## Critical Restrictions

- Do not modify unrelated files.
- Do not add unnecessary dependencies.
- Do not overengineer.
- Do not guess file paths, APIs, or existing architecture.
- Verify relevant names and paths before editing.
- Do not claim checks passed unless they were actually run.
- Do not hide failures.
- Do not replace working code simply to match personal preference.
