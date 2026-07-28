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
    $out = & $binPath settings remove --binary $binPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        Ok "Removed statusline entries and hooks from settings.json"
        Info $settingsPath
    } else {
        Warn "Failed to update settings.json"
        if ($out) { Info ($out -join ' ') }
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
foreach ($pattern in @('statusline-oc-*.txt', 'statusline-git-*.txt', 'statusline-tasks-*.json',
                       'statusline-notify-*.json', 'statusline-sa-*.txt')) {
    Get-ChildItem -Path $env:TEMP -Filter $pattern -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
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
