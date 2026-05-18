#Requires -Version 5.1
# Uninstaller: removes ~/.claude/statusline.ps1 and the statusLine key from settings.json.

$claudeDir = "$env:USERPROFILE\.claude"
$scriptPath = "$claudeDir\statusline.ps1"
$settingsPath = "$claudeDir\settings.json"
$notifyPath = "$claudeDir\notify.ps1"
$gitRefreshPath = "$claudeDir\git-refresh.ps1"

# ── Colors / log helpers ──────────────────────────────────────────────────────
$ESC    = [char]27
$RESET  = "$ESC[0m"
$BOLD   = "$ESC[1m"
$DIM    = "$ESC[2m"
$CYAN   = "$ESC[36m"
$GREEN  = "$ESC[32m"
$YELLOW = "$ESC[33m"
$RED    = "$ESC[31m"
$GRAY   = "$ESC[90m"

function Step([string]$msg)  { Write-Host "  ${CYAN}${BOLD}>>>${RESET} $msg" }
function Ok([string]$msg)    { Write-Host "  ${GREEN}${BOLD} +${RESET} $msg" }
function Warn([string]$msg)  { Write-Host "  ${YELLOW}${BOLD} !${RESET} $msg" }
function Info([string]$msg)  { Write-Host "  ${DIM}   $msg${RESET}" }
function HumanSize([long]$bytes) {
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

# --- Header ---
Write-Host ""
Write-Host "  ${DIM}claude-status-line $([char]0x00B7) Uninstaller${RESET}"
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host ""

# --- Remove the script ---
Step "Removing status line script"
if (Test-Path $scriptPath) {
    $sz = HumanSize (Get-Item $scriptPath).Length
    Remove-Item $scriptPath -Force
    Ok "Deleted $scriptPath ($sz)"
} else {
    Warn "Script not found (already removed?)"
}
Write-Host ""

# --- Remove from settings.json ---
# UTF-8 without BOM — Claude Code rejects a leading BOM on settings.json.
Step "Updating Claude Code settings"
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existing.PSObject.Properties.Remove('statusLine')

        $json = $existing | ConvertTo-Json -Depth 10
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding $false))
        Move-Item $tmpPath $settingsPath -Force
        Ok "Removed statusLine from settings.json"
    } catch {
        Warn "Could not parse settings.json — please remove the `"statusLine`" key manually"
        Info $settingsPath
    }
} else {
    Warn "settings.json not found"
}

# --- Remove notification script ---
Write-Host ""
Step "Removing notification script"
if (Test-Path $notifyPath) {
    $sz = HumanSize (Get-Item $notifyPath).Length
    Remove-Item $notifyPath -Force
    Ok "Deleted $notifyPath ($sz)"
} else {
    Info "Notification script not found (not installed)"
}

# --- Remove git-refresh script ---
if (Test-Path $gitRefreshPath) {
    $sz = HumanSize (Get-Item $gitRefreshPath).Length
    Remove-Item $gitRefreshPath -Force
    Ok "Deleted $gitRefreshPath ($sz)"
} else {
    Info "Git-refresh script not found (not installed)"
}

# --- Remove notification hooks ---
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasNotifyHooks = $false
        if ($existing.hooks) {
            foreach ($eventName in @('PermissionRequest', 'Stop')) {
                $eventHooks = $existing.hooks.$eventName
                if ($eventHooks) {
                    foreach ($entry in $eventHooks) {
                        if ($entry.hooks) {
                            foreach ($h in $entry.hooks) {
                                if ($h.command -and $h.command.Contains('notify.ps1')) {
                                    $hasNotifyHooks = $true
                                    break
                                }
                            }
                        }
                        if ($hasNotifyHooks) { break }
                    }
                }
                if ($hasNotifyHooks) { break }
            }
        }
        if ($hasNotifyHooks) {
            foreach ($eventName in @('PermissionRequest', 'Stop')) {
                $eventHooks = $existing.hooks.$eventName
                if ($eventHooks) {
                    $kept = [System.Collections.ArrayList]::new()
                    foreach ($entry in $eventHooks) {
                        $hasNotify = $false
                        if ($entry.hooks) {
                            foreach ($h in $entry.hooks) {
                                if ($h.command -and $h.command.Contains('notify.ps1')) {
                                    $hasNotify = $true
                                    break
                                }
                            }
                        }
                        if (-not $hasNotify) { [void]$kept.Add($entry) }
                    }
                    if ($kept.Count -gt 0) {
                        $existing.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($kept) -Force
                    } else {
                        $existing.hooks.PSObject.Properties.Remove($eventName)
                    }
                }
            }
            if (($existing.hooks.PSObject.Properties | Measure-Object).Count -eq 0) {
                $existing.PSObject.Properties.Remove('hooks')
            }
            Write-Host ""
            Step "Removing notification hooks"
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $tmpPath = "$settingsPath.tmp"
            [System.IO.File]::WriteAllText($tmpPath, ($existing | ConvertTo-Json -Depth 10), $utf8NoBom)
            Move-Item $tmpPath $settingsPath -Force
            Ok "Removed notification hooks from settings.json"
            }
    } catch {
        Warn "Could not update hooks in settings.json - please remove notification hooks manually"
    }
}

# --- Remove PostToolUse git-refresh hook ---
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasRefreshHook = $false
        if ($existing.hooks -and $existing.hooks.PostToolUse) {
            foreach ($entry in $existing.hooks.PostToolUse) {
                if ($entry.hooks) {
                    foreach ($h in $entry.hooks) {
                        if ($h.command -and $h.command.Contains('git-refresh.ps1')) {
                            $hasRefreshHook = $true
                            break
                        }
                    }
                }
                if ($hasRefreshHook) { break }
            }
        }
        if ($hasRefreshHook) {
            $kept = [System.Collections.ArrayList]::new()
            foreach ($entry in $existing.hooks.PostToolUse) {
                $hasRefresh = $false
                if ($entry.hooks) {
                    foreach ($h in $entry.hooks) {
                        if ($h.command -and $h.command.Contains('git-refresh.ps1')) {
                            $hasRefresh = $true
                            break
                        }
                    }
                }
                if (-not $hasRefresh) { [void]$kept.Add($entry) }
            }
            if ($kept.Count -gt 0) {
                $existing.hooks | Add-Member -NotePropertyName 'PostToolUse' -NotePropertyValue @($kept) -Force
            } else {
                $existing.hooks.PSObject.Properties.Remove('PostToolUse')
            }
            if (($existing.hooks.PSObject.Properties | Measure-Object).Count -eq 0) {
                $existing.PSObject.Properties.Remove('hooks')
            }
            Write-Host ""
            Step "Removing git-refresh hook"
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $tmpPath = "$settingsPath.tmp"
            [System.IO.File]::WriteAllText($tmpPath, ($existing | ConvertTo-Json -Depth 10), $utf8NoBom)
            Move-Item $tmpPath $settingsPath -Force
            Ok "Removed PostToolUse hook from settings.json"
        }
    } catch {
        Warn "Could not update hooks in settings.json - please remove PostToolUse hook manually"
    }
}

# --- Clean up temp state files ---
Write-Host ""
Step "Cleaning up temporary files"
$tempFiles = Get-ChildItem -Path $env:TEMP -Filter "statusline-*.txt" -ErrorAction SilentlyContinue
if ($tempFiles) {
    foreach ($tf in $tempFiles) {
        $sz = HumanSize $tf.Length
        Remove-Item $tf.FullName -Force -ErrorAction SilentlyContinue
        Ok "Deleted $($tf.FullName) ($sz)"
    }
} else {
    Info "No temporary state files found"
}

# --- Done ---
Write-Host ""
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to use the default status bar."
Write-Host ""
