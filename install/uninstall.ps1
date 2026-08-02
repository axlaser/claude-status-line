#Requires -Version 5.1
# Removes the claude-statusline binary and every settings.json entry the
# installer wrote.
#
# BOM-LESS and ASCII-ONLY, and no `exit` anywhere -- see install.ps1 for both.
# This file is fetched with `irm <url> | iex` and runs in the user's live
# session.

if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    Write-Host "  PowerShell 5.1+ required (current: $($PSVersionTable.PSVersion))" -ForegroundColor Red
    return
}

$claudeDir    = "$env:USERPROFILE\.claude"
$binDir       = "$claudeDir\bin"
$binPath      = "$binDir\claude-statusline.exe"
$sidecarPath  = "$binDir\claude-statusline.exe.old"
$settingsPath = "$claudeDir\settings.json"
$configPath   = "$claudeDir\notify-config.json"
$iconPath     = "$claudeDir\claude-icon.png"
$modelWindows = "$claudeDir\statusline-model-windows.json"
$stagePrefix  = ".claude-statusline.stage."

$ESC    = [char]27
$RESET  = "$ESC[0m"
$BOLD   = "$ESC[1m"
$DIM    = "$ESC[2m"
$CYAN   = "$ESC[36m"
$GREEN  = "$ESC[32m"
$YELLOW = "$ESC[33m"
$GRAY   = "$ESC[90m"

function Step([string]$msg)  { Write-Host "  ${CYAN}${BOLD}>>>${RESET} $msg" }
function Ok([string]$msg)    { Write-Host "  ${GREEN}${BOLD} +${RESET} $msg" }
function Warn([string]$msg)  { Write-Host "  ${YELLOW}${BOLD} !${RESET} $msg" }
function Info([string]$msg)  { Write-Host "  ${DIM}   $msg${RESET}" }

# See install.ps1's copy for the full reasoning. $LASTEXITCODE is only written
# by a process that starts, so an executable that cannot launch leaves the
# previous command's code in place and a bare check reads it as success. Here
# that would report the settings entries removed when nothing ran.
function Invoke-Binary {
    param([string]$Exe, [string[]]$BinArgs)
    $global:LASTEXITCODE = $null
    $output = $null
    try {
        $output = & $Exe @BinArgs 2>&1
    } catch {
        return [PSCustomObject]@{ Ran = $false; Code = $null; Output = $_.Exception.Message }
    }
    if ($null -eq $LASTEXITCODE) {
        return [PSCustomObject]@{ Ran = $false; Code = $null; Output = $output }
    }
    return [PSCustomObject]@{ Ran = $true; Code = $LASTEXITCODE; Output = $output }
}

Write-Host ""
Write-Host "  ${DIM}claude-statusline uninstaller${RESET}"
Write-Host "  ${GRAY}-----------------------------------------${RESET}"
Write-Host ""

# --- settings.json first, while the binary that can edit it still exists ---
# Order matters: the merge logic lives in the binary, so removing the entries
# has to happen before removing the tool that removes them.
Step "Updating Claude Code settings"
if (-not (Test-Path $settingsPath)) {
    Warn "settings.json not found"
} elseif (Test-Path $binPath) {
    $removed = Invoke-Binary $binPath @('settings', 'remove', '--binary', $binPath)
    if ($removed.Ran -and $removed.Code -eq 0) {
        Ok "Removed statusline entries and hooks from settings.json"
        Info $settingsPath
    } else {
        Warn "Failed to update settings.json"
        if ($removed.Output) { Info ($removed.Output -join ' ') }
        Info "Remove the statusLine, subagentStatusLine and claude-statusline hook entries manually"
    }
} else {
    Warn "Binary already removed - cannot edit settings.json automatically"
    Info "Remove the statusLine, subagentStatusLine and claude-statusline hook entries manually"
    Info $settingsPath
}
Write-Host ""

# --- Binary ---
# Windows will not delete a running executable but will rename it, so the
# rename-aside is what makes uninstall work while Claude Code is open. A failed
# delete of the sidecar is tolerated; the next install sweeps it.
Step "Removing the binary"
if (Test-Path $binPath) {
    $moved = $false
    try {
        Move-Item -Path $binPath -Destination $sidecarPath -Force -ErrorAction Stop
        $moved = $true
    } catch {
        Warn "Could not move $binPath aside - is Claude Code still running?"
    }
    if ($moved) {
        Remove-Item $sidecarPath -Force -ErrorAction SilentlyContinue
        if (Test-Path $sidecarPath) {
            Ok "Binary disabled (a locked copy remains as claude-statusline.exe.old)"
            Info "It will be removed automatically on the next install or uninstall."
        } else {
            Ok "Deleted $binPath"
        }
    }
} else {
    Warn "Binary not found (already removed?)"
}

Get-ChildItem -Path $binDir -Filter "$stagePrefix*" -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# The self-check log and quarantined binary a failed install leaves behind
# for diagnosis.
Remove-Item (Join-Path $binDir "claude-statusline.self-check.txt") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $binDir "claude-statusline.failed") -Force -ErrorAction SilentlyContinue

# Only if it is now empty - the user may keep other tools here.
if ((Test-Path $binDir) -and -not (Get-ChildItem -Path $binDir -Force -ErrorAction SilentlyContinue)) {
    Remove-Item $binDir -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $binDir)) { Ok "Removed empty $binDir" }
}
Write-Host ""

# --- Notification icon ---
Step "Removing the notification icon"
if (Test-Path $iconPath) {
    Remove-Item $iconPath -Force -ErrorAction SilentlyContinue
    Ok "Deleted $iconPath"
} else {
    Info "Icon not found (not installed)"
}
Write-Host ""

# --- Data files ---
Step "Removing data files"
if (Test-Path $modelWindows) {
    Remove-Item $modelWindows -Force -ErrorAction SilentlyContinue
    Ok "Deleted $modelWindows"
} else {
    Info "No learned model-window map to remove"
}
# statusline-oc-* is kept in the list even though the binary never writes one:
# it cleans up after a script-era install that did.
foreach ($pattern in @('statusline-oc-*.txt', 'statusline-git-*.txt', 'statusline-tasks-*.json',
                       'statusline-notify-*.json', 'statusline-sa-*.txt',
                       'statusline-tokens-*.txt')) {
    Get-ChildItem -Path $env:TEMP -Filter $pattern -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
# Current installs group the same files under claude-statusline-<owner>, where
# <owner> is a digest of this user's SID. The flat patterns above stay: a session
# upgraded mid-flight leaves its files behind in the old layout, and nothing at
# runtime ever sweeps them.
#
# Matched on a digit suffix rather than a claude-statusline-* wildcard. The test
# harness stages claude-statusline-test-* scratch roots in this same directory
# and the README's manual verification downloads claude-statusline-checksums.txt
# here; neither belongs to the uninstaller.
#
# Two further filters, both matching what the runtime already does with the same
# directory. The owner check is the Windows form of uninstall.sh's `id -u`
# scoping: %TEMP% is per-user on a default install, but a redirected or
# system-wide TEMP puts every user's state directory in one place, and none of
# the others are this uninstaller's to remove. The reparse-point check is why
# this is not a bare recursive delete: under Windows PowerShell 5.1 -- the shell
# the documented irm | iex path runs in -- Remove-Item -Recurse follows a
# junction and empties its target instead of unlinking it. Any user can plant one
# with mklink /J. verify_through_handle in src/platform/mod.rs refuses a reparse
# point at exactly this path, so such a directory is by construction never ours.
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Get-ChildItem -Path $env:TEMP -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '^claude-statusline-\d+$' -and
        -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
        $(try { (Get-Acl $_.FullName -ErrorAction Stop).Owner -eq $me } catch { $false })
    } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Ok "Cleared temporary session state"
Write-Host ""

# --- Notification config and debug log ---
# Both are removed unconditionally, which is what the script uninstaller did.
# The uninstaller preserves today's prompts, and today there is none here --
# adding one would be a UX change smuggled in under a port.
Step "Removing notification configuration"
if (Test-Path $configPath) {
    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
    Ok "Deleted $configPath"
} else {
    Info "No notification config found"
}

$debugLog = "$claudeDir\statusline-debug.log"
if (Test-Path $debugLog) {
    Remove-Item $debugLog -Force -ErrorAction SilentlyContinue
    Ok "Deleted $debugLog"
}

Write-Host ""
Write-Host "  ${GRAY}-----------------------------------------${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to apply."
Write-Host ""
