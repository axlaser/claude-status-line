#Requires -Version 5.1
# Claude Code Status Line — Uninstaller for Windows

$claudeDir = "$env:USERPROFILE\.claude"
$scriptPath = "$claudeDir\statusline.ps1"
$settingsPath = "$claudeDir\settings.json"

# ── Colors ────────────────────────────────────────────────────────────────────
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

# ── Header ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ${DIM}claude-status-line $([char]0x00B7) Uninstaller${RESET}"
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host ""

# ── Remove the script ─────────────────────────────────────────────────────────
Step "Removing status line script"
if (Test-Path $scriptPath) {
    Remove-Item $scriptPath -Force
    Ok "Deleted $scriptPath"
} else {
    Warn "Script not found (already removed?)"
}
Write-Host ""

# ── Remove from settings.json ────────────────────────────────────────────────
Step "Updating Claude Code settings"
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($existing.statusLine) {
            $existing.PSObject.Properties.Remove('statusLine')
            $json = $existing | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText(
                $settingsPath,
                $json,
                (New-Object System.Text.UTF8Encoding $false))
            Ok "Removed statusLine from settings.json"
        } else {
            Warn "No statusLine config found in settings.json"
        }
    } catch {
        Warn "Could not parse settings.json — please remove the `"statusLine`" key manually"
        Info $settingsPath
    }
} else {
    Warn "settings.json not found"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to use the default status bar."
Write-Host ""
