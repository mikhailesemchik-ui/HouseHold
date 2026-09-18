<#
.SYNOPSIS
    Restricted device-automation wrapper for Household OS UI verification.

.DESCRIPTION
    A locked-down interface over `adb` for exactly one purpose: inspecting the
    Household OS app on one specific physical device during UI work. It is NOT
    a general adb wrapper.

    Hard-coded, non-configurable restrictions (see README.md for the full
    rationale):
      - Only ever targets device serial RFCT40P949Z (`adb -s` is always
        explicit; the "any single connected device" adb default is never
        relied on).
      - Only ever targets package com.household.household_os.
      - Before every interactive action (screenshot, dump, tap, swipe, text,
        back) the script re-checks that Household OS is the current foreground
        app. If it is not - including if the check itself fails for any
        reason - the action is refused and the script exits non-zero without
        touching the device.
      - After tap/swipe/text/back, the foreground is re-checked again. If
        Household OS is no longer foreground, the script reports that and
        exits non-zero without taking any further action (no Back, no
        dismiss, no auto-relaunch, no interaction with whatever is now in
        front). The only recovery is an explicit later `launch`.
      - tap/swipe coordinates are validated against the device's real display
        bounds (queried fresh from the device), not just "non-negative".
        swipe duration is constrained to a safe range.
      - `launch` fails closed: it is only a success if Household OS is
        confirmed foreground afterward.
      - `dump` output is checked for Household OS ownership before being kept;
        a dump that doesn't clearly belong to Household OS is deleted, not
        returned.
      - `status` and every refusal message report only "yes / no / unknown"
        for whether Household OS is foreground - never another app's package
        name or identity.
      - Screenshot/dump filenames must already be a valid `[a-zA-Z0-9_-]+`
        name; anything else (path separators, `..`, dots, absolute paths) is
        refused outright, never silently rewritten into a "safe" name.
      - No arbitrary adb passthrough command is exposed. Only the fixed verb
        set below exists.
      - No Android Settings, no density/font-scale/screen-mode/Eye-comfort
        changes, no permission grants, no install/uninstall, no clear-data,
        no interaction with any other app or system UI.
      - Screenshot/dump output is always written under this script's own
        `output/` directory (inside the repository).

.USAGE
    .\household-device.ps1 status
    .\household-device.ps1 launch
    .\household-device.ps1 screenshot <name>
    .\household-device.ps1 dump <name>
    .\household-device.ps1 tap <x> <y>
    .\household-device.ps1 swipe <x1> <y1> <x2> <y2> [durationMs]
    .\household-device.ps1 text <string>
    .\household-device.ps1 back
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'launch', 'screenshot', 'dump', 'tap', 'swipe', 'text', 'back')]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

# NOTE: deliberately NOT setting $ErrorActionPreference = 'Stop' globally.
# adb routinely writes non-fatal, informational text to stderr (e.g. "Warning:
# Activity not started, intent has been delivered to currently running
# top-most instance."). Under PowerShell 5.1, redirecting a native command's
# stderr (`2>...`) wraps each stderr line in a NativeCommandError and, with
# ErrorActionPreference=Stop, that becomes a terminating exception even
# though adb's own exit code is 0. This script treats $LASTEXITCODE as the
# only source of truth for adb success/failure and never redirects stderr.

# ---------------------------------------------------------------------------
# Fixed, non-configurable targets. These are deliberately not parameters.
# ---------------------------------------------------------------------------
$AllowedSerial  = 'RFCT40P949Z'
$AllowedPackage = 'com.household.household_os'
$MainActivity   = "$AllowedPackage/.MainActivity"

$OutputDir = Join-Path $PSScriptRoot 'output'
$RemoteTmpDir = '/sdcard/household_device_wrapper_tmp'

# Safe range for `input swipe` duration, milliseconds.
$MinSwipeDurationMs = 50
$MaxSwipeDurationMs = 3000

function Write-Refusal {
    param([string]$Message)
    Write-Host "REFUSED: $Message" -ForegroundColor Red
}

function Invoke-Adb {
    # Every adb invocation in this script goes through here so the target
    # device is always explicit and never left to adb's own default.
    param([string[]]$AdbArgs)
    $full = @('-s', $AllowedSerial) + $AdbArgs
    $out = & adb @full
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Assert-DeviceOnline {
    $result = & adb devices
    $line = $result | Where-Object { $_ -match [regex]::Escape($AllowedSerial) }
    if (-not $line) {
        Write-Refusal "Device $AllowedSerial is not connected (per 'adb devices')."
        exit 1
    }
    if ($line -notmatch "$([regex]::Escape($AllowedSerial))\s+device\b") {
        Write-Refusal "Device $AllowedSerial is connected but not in 'device' state: $line"
        exit 1
    }
}

function Get-ForegroundPackage {
    # Two independent signals must agree with each other's package before we
    # trust either: the currently focused window, and the top resumed
    # activity. Disagreement or a parse failure is treated as "unknown".
    # This function returns the real package name for internal enforcement
    # only - callers that print to the user must never surface this value
    # directly for a non-Household-OS result (see Write-ForegroundStatus).
    $winResult = Invoke-Adb @('shell', 'dumpsys', 'window')
    $winLine = $winResult.Output | Where-Object { $_ -match 'mCurrentFocus=' } | Select-Object -Last 1
    $winPkg = $null
    if ($winLine -and $winLine -match 'mCurrentFocus=Window\{[^\s]+\s+[^\s]+\s+([A-Za-z0-9_.]+)/') {
        $winPkg = $Matches[1]
    }

    $actResult = Invoke-Adb @('shell', 'dumpsys', 'activity', 'activities')
    $actLine = $actResult.Output | Where-Object { $_ -match 'topResumedActivity=' } | Select-Object -Last 1
    $actPkg = $null
    if ($actLine -and $actLine -match 'topResumedActivity=ActivityRecord\{[^\s]+\s+[^\s]+\s+([A-Za-z0-9_.]+)/') {
        $actPkg = $Matches[1]
    }

    if (-not $winPkg -or -not $actPkg -or $winPkg -ne $actPkg) {
        return $null
    }
    return $winPkg
}

function Get-ForegroundState {
    # Privacy-safe tri-state for external reporting: 'yes' / 'no' / 'unknown'.
    # Never returns or leaks another app's package name.
    $fg = Get-ForegroundPackage
    if (-not $fg) { return 'unknown' }
    if ($fg -eq $AllowedPackage) { return 'yes' }
    return 'no'
}

function Write-ForegroundStatus {
    param([string]$State)
    switch ($State) {
        'yes' { Write-Host 'Household OS foreground: yes' -ForegroundColor Green }
        'no' { Write-Host 'Household OS foreground: no' -ForegroundColor Yellow }
        default { Write-Host 'Household OS foreground: unknown' -ForegroundColor Yellow }
    }
}

function Assert-HouseholdForeground {
    Assert-DeviceOnline
    $state = Get-ForegroundState
    if ($state -ne 'yes') {
        Write-Refusal 'Household OS is not the foreground application. Refusing device interaction.'
        exit 1
    }
}

function Confirm-PostActionForeground {
    # Called after tap/swipe/text/back. Deliberately does nothing to recover
    # if Household OS is no longer foreground - no Back, no dismiss, no
    # auto-relaunch, no interaction with whatever is now in front. The only
    # sanctioned recovery is an explicit later `launch`.
    Start-Sleep -Milliseconds 400
    $state = Get-ForegroundState
    if ($state -ne 'yes') {
        Write-Refusal 'Household OS left foreground after action. Further interaction is blocked.'
        Write-Host 'Recovery: run "launch" explicitly before further interaction.' -ForegroundColor Yellow
        exit 1
    }
}

function Get-DisplaySize {
    # Reads the device's real display bounds fresh from the device. Prefers
    # an active "Override size" (what `input tap`/`input swipe` coordinates
    # are actually measured against) over "Physical size" when both are
    # reported. Returns $null if either line cannot be parsed confidently -
    # callers must fail closed on that, not assume a size.
    $r = Invoke-Adb @('shell', 'wm', 'size')
    $physical = $null
    $override = $null
    foreach ($line in $r.Output) {
        if ($line -match 'Physical size:\s*(\d+)x(\d+)') {
            $physical = @{ Width = [int]$Matches[1]; Height = [int]$Matches[2] }
        }
        if ($line -match 'Override size:\s*(\d+)x(\d+)') {
            $override = @{ Width = [int]$Matches[1]; Height = [int]$Matches[2] }
        }
    }
    $size = if ($override) { $override } else { $physical }
    if (-not $size -or $size.Width -le 0 -or $size.Height -le 0) {
        return $null
    }
    return $size
}

function Assert-CoordinateInBounds {
    param([int]$X, [int]$Y, [hashtable]$Size, [string]$Label)
    if ($X -lt 0 -or $X -ge $Size.Width -or $Y -lt 0 -or $Y -ge $Size.Height) {
        Write-Refusal "$Label ($X, $Y) is outside the device display bounds (0..$($Size.Width - 1), 0..$($Size.Height - 1))."
        exit 1
    }
}

function Get-SafeOutputPath {
    # Strict: the name must ALREADY be a valid simple filename. Nothing is
    # sanitized or rewritten - an invalid name (path separators, "..", dots,
    # absolute paths, or any other character) is refused outright.
    param([string]$Name, [string]$Extension)
    if (-not $Name -or $Name -notmatch '^[a-zA-Z0-9_\-]+$') {
        Write-Refusal "Output name '$Name' is invalid. Use only letters, digits, '_' and '-' - no dots, slashes, backslashes, or path syntax."
        exit 1
    }
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $OutputDir "$Name-$stamp.$Extension"
}

function Confirm-SafeText {
    param([string]$Text)
    if ($Text -notmatch '^[a-zA-Z0-9 .,!?@#_\-]+$') {
        Write-Refusal "Text input contains characters outside the allowed safe set (letters, digits, spaces, and . , ! ? @ # _ -)."
        exit 1
    }
}

function Test-DumpOwnership {
    # Confirms the pulled XML both parses as well-formed XML and visibly
    # contains at least one Household OS node. Anything else - malformed
    # XML, no Household OS package attribute, an empty/truncated pull - is
    # treated as "cannot establish ownership confidently".
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $content = $null
    try {
        $content = Get-Content -Raw -Path $Path -ErrorAction Stop
    } catch {
        return $false
    }
    if (-not $content) { return $false }
    try {
        [xml]$null = $content
    } catch {
        return $false
    }
    if ($content -notmatch [regex]::Escape("package=`"$AllowedPackage`"")) {
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

switch ($Command) {

    'status' {
        Assert-DeviceOnline
        Write-Host "Device:  $AllowedSerial (online, verified)"
        Write-Host "Package: $AllowedPackage (only allowed target)"
        Write-ForegroundStatus -State (Get-ForegroundState)
    }

    'launch' {
        Assert-DeviceOnline
        Write-Host 'Launching Household OS ...'
        $r = Invoke-Adb @('shell', 'am', 'start', '-n', $MainActivity)
        $r.Output | ForEach-Object { Write-Host $_ }
        Start-Sleep -Milliseconds 1500
        $state = Get-ForegroundState
        if ($state -eq 'yes') {
            Write-ForegroundStatus -State $state
            Write-Host 'Launch confirmed.' -ForegroundColor Green
        } else {
            Write-Refusal 'Household OS could not be confirmed as foreground after launch.'
            exit 1
        }
    }

    'screenshot' {
        Assert-HouseholdForeground
        $name = $Rest[0]
        $localPath = Get-SafeOutputPath -Name $name -Extension 'png'
        $remotePath = "$RemoteTmpDir/screenshot.png"
        Invoke-Adb @('shell', 'mkdir', '-p', $RemoteTmpDir) | Out-Null
        $cap = Invoke-Adb @('shell', 'screencap', '-p', $remotePath)
        if ($cap.ExitCode -ne 0) {
            Write-Refusal 'screencap failed on device.'
            exit 1
        }
        & adb -s $AllowedSerial pull $remotePath $localPath | Out-Null
        Invoke-Adb @('shell', 'rm', '-f', $remotePath) | Out-Null
        if (Test-Path $localPath) {
            Write-Host "Screenshot saved: $localPath" -ForegroundColor Green
        } else {
            Write-Refusal 'Screenshot pull failed.'
            exit 1
        }
    }

    'dump' {
        Assert-HouseholdForeground
        $name = $Rest[0]
        $localPath = Get-SafeOutputPath -Name $name -Extension 'xml'
        $remotePath = "$RemoteTmpDir/dump.xml"
        Invoke-Adb @('shell', 'mkdir', '-p', $RemoteTmpDir) | Out-Null
        $r = Invoke-Adb @('shell', 'uiautomator', 'dump', $remotePath)
        $r.Output | ForEach-Object { Write-Host $_ }
        & adb -s $AllowedSerial pull $remotePath $localPath | Out-Null
        Invoke-Adb @('shell', 'rm', '-f', $remotePath) | Out-Null
        if (-not (Test-Path $localPath)) {
            Write-Refusal 'UI dump pull failed.'
            exit 1
        }
        if (-not (Test-DumpOwnership -Path $localPath)) {
            Remove-Item -Path $localPath -Force -ErrorAction SilentlyContinue
            Invoke-Adb @('shell', 'rm', '-f', $remotePath) | Out-Null
            Write-Refusal 'UI dump ownership could not be confirmed as Household OS (malformed, empty, or no matching package node). Deleted.'
            exit 1
        }
        Write-Host "UI dump saved: $localPath" -ForegroundColor Green
    }

    'tap' {
        Assert-HouseholdForeground
        if ($Rest.Count -lt 2) {
            Write-Refusal 'tap requires <x> <y>.'
            exit 1
        }
        $xRaw = $Rest[0]; $yRaw = $Rest[1]
        if ($xRaw -notmatch '^\d+$' -or $yRaw -notmatch '^\d+$') {
            Write-Refusal 'tap coordinates must be non-negative integers.'
            exit 1
        }
        $size = Get-DisplaySize
        if (-not $size) {
            Write-Refusal 'Could not determine device display bounds confidently. Refusing to act.'
            exit 1
        }
        $x = [int]$xRaw; $y = [int]$yRaw
        Assert-CoordinateInBounds -X $x -Y $y -Size $size -Label 'tap'
        Invoke-Adb @('shell', 'input', 'tap', $xRaw, $yRaw) | Out-Null
        Confirm-PostActionForeground
        Write-Host "Tapped ($x, $y) on Household OS." -ForegroundColor Green
    }

    'swipe' {
        Assert-HouseholdForeground
        if ($Rest.Count -lt 4) {
            Write-Refusal 'swipe requires <x1> <y1> <x2> <y2> [durationMs].'
            exit 1
        }
        foreach ($v in $Rest[0..3]) {
            if ($v -notmatch '^\d+$') {
                Write-Refusal 'swipe coordinates must be non-negative integers.'
                exit 1
            }
        }
        $durationRaw = if ($Rest.Count -ge 5) { $Rest[4] } else { '300' }
        if ($durationRaw -notmatch '^\d+$') {
            Write-Refusal 'swipe duration must be a non-negative integer (ms).'
            exit 1
        }
        $duration = [int]$durationRaw
        if ($duration -lt $MinSwipeDurationMs -or $duration -gt $MaxSwipeDurationMs) {
            Write-Refusal "swipe duration ${duration}ms is outside the allowed range ($MinSwipeDurationMs..$MaxSwipeDurationMs ms)."
            exit 1
        }
        $size = Get-DisplaySize
        if (-not $size) {
            Write-Refusal 'Could not determine device display bounds confidently. Refusing to act.'
            exit 1
        }
        $x1 = [int]$Rest[0]; $y1 = [int]$Rest[1]; $x2 = [int]$Rest[2]; $y2 = [int]$Rest[3]
        Assert-CoordinateInBounds -X $x1 -Y $y1 -Size $size -Label 'swipe start'
        Assert-CoordinateInBounds -X $x2 -Y $y2 -Size $size -Label 'swipe end'
        Invoke-Adb @('shell', 'input', 'swipe', $Rest[0], $Rest[1], $Rest[2], $Rest[3], $durationRaw) | Out-Null
        Confirm-PostActionForeground
        Write-Host "Swiped ($x1,$y1) -> ($x2,$y2) over ${duration}ms on Household OS." -ForegroundColor Green
    }

    'text' {
        Assert-HouseholdForeground
        $text = $Rest -join ' '
        Confirm-SafeText -Text $text
        $encoded = $text -replace ' ', '%s'
        Invoke-Adb @('shell', 'input', 'text', $encoded) | Out-Null
        Confirm-PostActionForeground
        Write-Host 'Typed text into Household OS.' -ForegroundColor Green
    }

    'back' {
        Assert-HouseholdForeground
        Invoke-Adb @('shell', 'input', 'keyevent', '4') | Out-Null
        Confirm-PostActionForeground
        Write-Host 'Sent back key to Household OS.' -ForegroundColor Green
    }

    default {
        Write-Host 'Usage: household-device.ps1 <status|launch|screenshot|dump|tap|swipe|text|back> [args]'
        exit 1
    }
}
