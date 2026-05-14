#Requires -Version 5.1
# Claude Code Status Line — Installer for Windows

$repo = "https://raw.githubusercontent.com/axlaser/claude-status-line/master/windows"
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
function Err([string]$msg)   { Write-Host "  ${RED}${BOLD} x${RESET} $msg" }
function Info([string]$msg)  { Write-Host "  ${DIM}   $msg${RESET}" }

# ── Header ────────────────────────────────────────────────────────────────────
Write-Host ""
$banner = @"
 @@@@@@@  @@@        @@@@@@   @@@  @@@  @@@@@@@   @@@@@@@@
@@@@@@@@  @@@       @@@@@@@@  @@@  @@@  @@@@@@@@  @@@@@@@@
!@@       @@!       @@!  @@@  @@!  @@@  @@!  @@@  @@!
!@!       !@!       !@!  @!@  !@!  @!@  !@!  @!@  !@!
!@!       @!!       @!@!@!@!  @!@  !@!  @!@  !@!  @!!!:!
!!!       !!!       !!!@!!!!  !@!  !!!  !@!  !!!  !!!!!:
:!!       !!:       !!:  !!!  !!:  !!!  !!:  !!!  !!:
:!:        :!:      :!:  !:!  :!:  !:!  :!:  !:!  :!:
 ::: :::   :: ::::  ::   :::  ::::: ::   :::: ::   :: ::::
 :: :: :  : :: : :   :   : :   : :  :   :: :  :   : :: ::

 @@@@@@   @@@@@@@   @@@@@@   @@@@@@@  @@@  @@@   @@@@@@
@@@@@@@   @@@@@@@  @@@@@@@@  @@@@@@@  @@@  @@@  @@@@@@@
!@@         @@!    @@!  @@@    @@!    @@!  @@@  !@@
!@!         !@!    !@!  @!@    !@!    !@!  @!@  !@!
!!@@!!      @!!    @!@!@!@!    @!!    @!@  !@!  !!@@!!
 !!@!!!     !!!    !!!@!!!!    !!!    !@!  !!!   !!@!!!
     !:!    !!:    !!:  !!!    !!:    !!:  !!!       !:!
    !:!     :!:    :!:  !:!    :!:    :!:  !:!      !:!
:::: ::      ::    ::   :::     ::    ::::: ::  :::: ::
 :: : :       :      :   : :     :      : :  :   :: : :

@@@       @@@  @@@  @@@  @@@@@@@@
@@@       @@@  @@@@ @@@  @@@@@@@@
@@!       @@!  @@!@!@@@  @@!
!@!       !@!  !@!!@!@!  !@!
@!!       !!@  @!@ !!@!  @!!!:!
!!!       !!!  !@!  !!!  !!!!!:
!!:       !!:  !!:  !!!  !!:
 :!:      :!:  :!:  !:!  :!:
 :: ::::   ::   ::   ::   :: ::::
: :: : :  :    ::    :   : :: ::
"@
Write-Host $banner
Write-Host ""
Write-Host "  ${DIM}Windows Installer${RESET}"
Write-Host "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
Write-Host ""

# ── Install the script ────────────────────────────────────────────────────────
Step "Installing status line script"
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localScript = Join-Path $scriptDir "statusline.ps1"
if (Test-Path $localScript) {
    Copy-Item $localScript -Destination $scriptPath -Force
    Ok "Copied from local repo"
} else {
    Invoke-WebRequest -Uri "$repo/statusline.ps1" -OutFile $scriptPath
    Ok "Downloaded from GitHub"
}
Info $scriptPath
Write-Host ""

# ── Configure settings.json ──────────────────────────────────────────────────
Step "Configuring Claude Code settings"
$cmd = "powershell -NoProfile -File $scriptPath"
$newEntry = [PSCustomObject]@{ type = "command"; command = $cmd; refreshInterval = 2 }

if (Test-Path $settingsPath) {
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json

    if ($existing.statusLine) {
        Write-Host ""
        $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Existing statusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET})"
        if ($answer -notmatch '^[Yy]$') {
            Warn "Skipped settings update"
            Info "Script was installed but not configured"
            Write-Host ""
            exit 0
        }
    }

    $existing | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $newEntry -Force
    $existing | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
    Ok "Updated settings.json"
} else {
    [PSCustomObject]@{ statusLine = $newEntry } | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
    Ok "Created settings.json"
}
Info $settingsPath

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate."
Write-Host ""
