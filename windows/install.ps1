#Requires -Version 5.1
# Claude Code Status Line — Installer for Windows

$repo = "https://raw.githubusercontent.com/axlaser/claude-status-line/master/windows"
$claudeDir = "$env:USERPROFILE\.claude"
$scriptPath = "$claudeDir\statusline.ps1"
$settingsPath = "$claudeDir\settings.json"
$notifyPath = "$claudeDir\notify.ps1"
$gitRefreshPath = "$claudeDir\git-refresh.ps1"

# --- Colors / log helpers ---
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
function HumanSize([long]$bytes) {
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

# --- Header / banner ---
# NOTE: file must keep its UTF-8 BOM — without it, `iex` chokes on the here-string below (commit b7dae1f).
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

# --- Install the script ---
# $MyInvocation.MyCommand.Path is $null when run via `irm | iex` — that's how we detect the piped case.
Step "Installing status line script"
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

$myPath = $MyInvocation.MyCommand.Path
$localScript = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "statusline.ps1" } else { $null }
if ($localScript -and (Test-Path $localScript)) {
    Copy-Item $localScript -Destination $scriptPath -Force
    Ok "Copied from local repo"
} else {
    try {
        Invoke-WebRequest -Uri "$repo/statusline.ps1" -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        exit 1
    }
}
Info "$scriptPath ($(HumanSize (Get-Item $scriptPath).Length))"
Write-Host ""

# --- Configure settings.json ---
# UTF-8 without BOM — Claude Code rejects a leading BOM on settings.json.
Step "Configuring Claude Code settings"
$cmd = "powershell -NoProfile -File `"$scriptPath`""
$newEntry = [PSCustomObject]@{ type = "command"; command = $cmd; refreshInterval = 2 }

if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Err "settings.json could not be parsed: $_"
        exit 1
    }

    if ($null -eq $existing -or $existing -isnot [PSCustomObject]) {
        Err "settings.json could not be parsed as a JSON object. Please check the file manually."
        exit 1
    }

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
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $tmpPath = "$settingsPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, ($existing | ConvertTo-Json -Depth 10), $utf8NoBom)
    Move-Item $tmpPath $settingsPath -Force
    Ok "Updated settings.json"
} else {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $tmpPath = "$settingsPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, ([PSCustomObject]@{ statusLine = $newEntry } | ConvertTo-Json -Depth 10), $utf8NoBom)
    Move-Item $tmpPath $settingsPath -Force
    Ok "Created settings.json"
}
Info $settingsPath

# --- Install git-refresh hook script ---
Write-Host ""
Step "Installing git-refresh hook"
$localGitRefresh = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "git-refresh.ps1" } else { $null }
if ($localGitRefresh -and (Test-Path $localGitRefresh)) {
    Copy-Item $localGitRefresh -Destination $gitRefreshPath -Force
    Ok "Copied from local repo"
} else {
    try {
        Invoke-WebRequest -Uri "$repo/git-refresh.ps1" -OutFile $gitRefreshPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        exit 1
    }
}
Info "$gitRefreshPath ($(HumanSize (Get-Item $gitRefreshPath).Length))"

# --- Register PostToolUse hook for git refresh ---
Write-Host ""
Step "Live git status"
Info "Keeps git diff/untracked counts up to date as files change."

try {
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Err "settings.json could not be parsed: $_"
    exit 1
}

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
    Ok "Already configured"
} else {
    $refreshCmd = "powershell -NoProfile -File `"$gitRefreshPath`""
    $hookEntry = [PSCustomObject]@{
        matcher = "Edit|Write|MultiEdit|Bash|NotebookEdit"
        hooks = @(
            [PSCustomObject]@{ type = "command"; command = $refreshCmd; async = $true }
        )
    }

    if (-not $existing.hooks) {
        $existing | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $kept = [System.Collections.ArrayList]::new()
    $eventHooks = $existing.hooks.PostToolUse
    if ($eventHooks) {
        foreach ($entry in $eventHooks) {
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
    }
    [void]$kept.Add($hookEntry)
    $existing.hooks | Add-Member -NotePropertyName 'PostToolUse' -NotePropertyValue @($kept) -Force

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $tmpPath = "$settingsPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, ($existing | ConvertTo-Json -Depth 10), $utf8NoBom)
    Move-Item $tmpPath $settingsPath -Force
    Ok "PostToolUse hook enabled"
}

# --- Install notification script ---
Write-Host ""
Step "Installing notification script"
$localNotify = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "notify.ps1" } else { $null }
if ($localNotify -and (Test-Path $localNotify)) {
    Copy-Item $localNotify -Destination $notifyPath -Force
    Ok "Copied from local repo"
} else {
    try {
        Invoke-WebRequest -Uri "$repo/notify.ps1" -OutFile $notifyPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        exit 1
    }
}
Info "$notifyPath ($(HumanSize (Get-Item $notifyPath).Length))"

# --- Configure notification hooks ---
Write-Host ""
Step "Sound notifications"
Info "Plays a sound when Claude needs permission or finishes responding."

try {
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Err "settings.json could not be parsed: $_"
    exit 1
}

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
    Ok "Already configured"
} else {
    Write-Host ""
    $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Enable sound notifications? (${GREEN}y${RESET}/${RED}n${RESET})"
    if ($answer -match '^[Yy]$') {
        $notifyCmd = "powershell -NoProfile -File `"$notifyPath`""

        $permEntry = [PSCustomObject]@{
            hooks = @(
                [PSCustomObject]@{ type = "command"; command = "$notifyCmd permission"; async = $true }
            )
        }
        $stopEntry = [PSCustomObject]@{
            hooks = @(
                [PSCustomObject]@{ type = "command"; command = "$notifyCmd stop"; async = $true }
            )
        }

        if (-not $existing.hooks) {
            $existing | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }

        foreach ($pair in @(@('PermissionRequest', $permEntry), @('Stop', $stopEntry))) {
            $eventName = $pair[0]
            $newEntry = $pair[1]
            $kept = [System.Collections.ArrayList]::new()
            $eventHooks = $existing.hooks.$eventName
            if ($eventHooks) {
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
            }
            [void]$kept.Add($newEntry)
            $existing.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($kept) -Force
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, ($existing | ConvertTo-Json -Depth 10), $utf8NoBom)
        Move-Item $tmpPath $settingsPath -Force
        Ok "Notifications enabled"
    } else {
        Info "Skipped - run the installer again to enable later"
    }
}

# --- Done ---
Write-Host ""
Write-Host "  ${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate."
Write-Host ""
