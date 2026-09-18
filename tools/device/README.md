# Household device wrapper

A restricted, single-purpose interface for inspecting **Household OS** on one
physical device during UI verification work. This is not a general Android
automation tool and is not meant to become one.

## Why this exists

UI correction work (see the device-evidence UI correction plan) needs to
inspect the real app on a real device: screenshots, UI-hierarchy dumps, and
simple input to navigate between screens. Raw `adb` can do all of that, but it
can also install/uninstall apps, change system settings, wipe app data,
grant permissions, and act on whatever app happens to be in the foreground —
none of which any UI-verification task should ever need or risk. This script
is the boundary: it only exposes the narrow slice of `adb` that UI
verification actually needs, and it enforces that boundary in code, not by
convention.

## What it will do

| Command | Effect |
|---|---|
| `status` | Report device connection and whether Household OS is foreground (`yes`/`no`/`unknown`). Read-only, always allowed. |
| `launch` | Start Household OS and verify it becomes foreground. Fails closed. |
| `screenshot <name>` | Capture the current screen to `output/<name>-<timestamp>.png`. |
| `dump <name>` | Capture a UIAutomator XML hierarchy to `output/<name>-<timestamp>.xml`, verified to belong to Household OS before being kept. |
| `tap <x> <y>` | Tap a coordinate, validated against the device's real display bounds. |
| `swipe <x1> <y1> <x2> <y2> [durationMs]` | Swipe between two bounds-checked coordinates; duration constrained to 50–3000ms. |
| `text <string>` | Type text (safe character set only — see below). |
| `back` | Send the Android back key. |

`tap`, `swipe`, `text`, and `back` all re-verify Household OS is still
foreground immediately after the action, before reporting success.

## What it will refuse to do

- **Target any device other than `RFCT40P949Z`.** The serial is hard-coded,
  not a parameter. Every `adb` call passes `-s RFCT40P949Z` explicitly; the
  script never relies on "the one connected device" default.
- **Target any package other than `com.household.household_os`.** Also
  hard-coded, not a parameter.
- **Act while another app or system UI is in front.** Before every
  interactive command (`screenshot`, `dump`, `tap`, `swipe`, `text`, `back`)
  the script re-checks the foreground app via two independent signals
  (`dumpsys window`'s focused window and `dumpsys activity activities`'s top
  resumed activity). Both must agree the foreground package is Household OS.
  If either check fails to parse, or they disagree, or the foreground is
  something else, the script **refuses and exits non-zero without touching
  the device** — it does not fall back to "probably fine".
- **Continue after Household OS leaves foreground mid-action.** `tap`,
  `swipe`, `text`, and `back` re-check the foreground immediately after the
  action. If Household OS is no longer foreground, the script prints
  `Household OS left foreground after action. Further interaction is
  blocked.` and exits non-zero. It does **not** press Back again, dismiss
  whatever is now showing, auto-relaunch, or interact with the new
  foreground in any way. The only sanctioned recovery is an explicit later
  `launch`.
- **Tap or swipe outside the real display.** `tap`/`swipe` query the
  device's actual display size (`wm size`, preferring an active override
  size over the physical size) fresh before validating coordinates. A
  coordinate at or beyond the width/height, or a display size that can't be
  determined confidently, is refused. `swipe` duration is also constrained
  to 50–3000ms.
- **Run arbitrary adb commands.** There is no passthrough command. The verb
  set above is everything; `$Command` is validated against a fixed
  `ValidateSet` and PowerShell itself rejects anything outside it before the
  script body even runs. Display-bounds lookup is an internal helper only —
  there is no public command that exposes a generic device-info query.
- **Touch Android Settings, density, font scale, screen mode, or Eye Comfort
  Shield.** No command exists for any of these. Changing device display/
  accessibility settings is the user's decision, made through the device's
  own UI, never through this script.
- **Grant/revoke permissions, install, uninstall, or clear app data.** No
  commands exist for any of these.
- **Disclose another foreground application's identity.** `status` and every
  refusal message report only `Household OS foreground: yes / no / unknown`
  — never another app's package name. The real package is still resolved
  internally (that's how the foreground check itself works), it is simply
  never printed when it isn't Household OS.
- **Keep a UI dump that doesn't belong to Household OS.** After pulling a
  dump, the script parses it as XML and confirms it contains a
  `package="com.household.household_os"` node. If the file is malformed,
  empty, or has no matching node, the local copy is deleted, the known
  remote temp file is cleaned up, and the command refuses — a dump
  belonging to another app or system UI is never inspected or retained.
- **Write output outside the repository, or silently rename an invalid
  name into a valid one.** `screenshot`/`dump` names must already match
  `^[a-zA-Z0-9_-]+$` exactly. A name containing `..`, `/`, `\`, `.`, or any
  other character is refused outright — it is never stripped or rewritten
  into something "safe". Valid names are always written under this script's
  own `output/` directory.
- **Send unsafe `text` input.** Input is checked against a whitelist
  (letters, digits, space, and `. , ! ? @ # _ -`) before being sent, so it
  cannot smuggle shell metacharacters through `adb shell input text` to the
  device's remote shell.

## Usage

```powershell
cd tools/device
.\household-device.ps1 status
.\household-device.ps1 launch
.\household-device.ps1 screenshot dashboard
.\household-device.ps1 dump dashboard
.\household-device.ps1 tap 540 1200
.\household-device.ps1 swipe 540 1800 540 600 300
.\household-device.ps1 text "Buy milk"
.\household-device.ps1 back
```

Output lands in `tools/device/output/`, which is git-ignored — screenshots
and dumps are working artifacts, never committed.

## Verified

**Setup session:**
- `status` correctly reports device/package/foreground state.
- `launch` starts Household OS and confirms it becomes foreground.
- `screenshot` and `dump` both produced valid, non-empty files reflecting the
  real on-screen app state.
- Negative: home-screen foreground (Samsung launcher) correctly refused
  `screenshot` with no file written.
- Negative: an unrecognized command (`shell`) was rejected by PowerShell's
  own parameter validation before the script body ran.

**Hardening session:**
- `status` while Household OS foreground reports `Household OS foreground:
  yes` — no package name printed either way.
- `launch` reports `Launch confirmed.` only after re-verifying foreground;
  the previous "warning but still exits 0" path no longer exists.
- Valid `screenshot`/`dump` still succeed; `dump` output confirmed to
  contain a `package="com.household.household_os"` node before being kept.
- Valid in-bounds `tap` (a harmless screen corner, not a destructive
  control) succeeded and reported the post-action foreground check passing.
- Negative: `tap 5000 5000` and `tap 1080 100` (exactly at the display
  width boundary, one past the valid `0..1079` range) both refused with the
  real display bounds shown.
- Negative: `swipe 100 100 9999 9999` refused (end point out of bounds).
- Negative: `swipe ... 10` (below 50ms) and `swipe ... 5000` (above 3000ms)
  both refused.
- Negative: `screenshot "../../evil"`, `screenshot "a.b"`, and
  `screenshot 'a\b'` were all refused outright — no file written, no name
  rewritten.
- Negative: unsafe `text "hello; rm -rf /"` refused by the whitelist.
- Negative: unknown command (`shell`) still rejected by `ValidateSet`.
- Post-action "left foreground" path: verified by static code inspection —
  `Confirm-PostActionForeground` (called after every `tap`/`swipe`/`text`/
  `back`) contains only a foreground re-check, `Write-Refusal`, and `exit 1`
  on failure; there is no `Invoke-Adb` call of any kind in its failure
  branch, so it cannot press Back, dismiss, relaunch, or otherwise interact
  with whatever became foreground. Deliberately not exercised by actually
  navigating into another (private) app; repeated `back` through the
  wrapper itself did not exit Household OS on this build (the app absorbs
  back presses at its root rather than exiting), which is itself further
  evidence the check has never had an uncontrolled opportunity to fire
  incorrectly.

## Known limitations

- The foreground check is a point-in-time `adb` query immediately before
  (and, for interactive commands, immediately after) the action; it cannot
  guard against the foreground changing in the few milliseconds outside
  those two windows.
- `dumpsys window`/`dumpsys activity activities` output format is an Android
  implementation detail — this has been verified on this device's current
  Android/One UI build, but a major OS update could change the format enough
  to break parsing. If that happens, `Get-ForegroundPackage` returns `$null`
  (unknown), which this script always treats as a refusal — it fails closed,
  not open.
- `wm size`'s "Physical size"/"Override size" text format is likewise an
  Android implementation detail; if it can't be parsed, `tap`/`swipe` refuse
  rather than guessing a display size.
- This script assumes exactly one physical device is ever attached with
  serial `RFCT40P949Z`. If a device with a different serial is connected
  instead, every command refuses at `Assert-DeviceOnline`.
- PowerShell 5.1's native-command stderr handling is fragile (see the code
  comment at the top of the script); this script deliberately never
  redirects `adb`'s stderr and trusts only `$LASTEXITCODE`, so informational
  adb warnings (e.g. "Activity not started, intent delivered to top-most
  instance") print to the console but do not abort the script.
