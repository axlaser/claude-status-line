# Claude Code Status Line -- Installer for Windows
# PowerShell 5.1+ required -- checked at runtime because `#Requires` directives aren't honored via `irm | iex`.
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { Write-Host "  PowerShell 5.1+ required (current: $($PSVersionTable.PSVersion))" -ForegroundColor Red; return }

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

# PS 5.1 ConvertTo-Json produces ugly center-aligned indentation; re-indent to standard 2-space.
function Format-Json([string]$Json) {
    $indent = 0
    $lines = [System.Collections.ArrayList]::new()
    foreach ($raw in ($Json -split '\r?\n')) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        if ($line -match '^[\}\]]') { $indent = [Math]::Max(0, $indent - 1) }
        $line = $line -replace '(?<=":)\s{2,}', ' '
        [void]$lines.Add(('  ' * $indent) + $line)
        if ($line -match '[\{\[]\s*$' -and $line -notmatch '[\{\[]\s*[\}\]]') { $indent++ }
    }
    $lines -join "`n"
}

function Copy-WithRetry([string]$Source, [string]$Dest, [int]$Retries = 5) {
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Copy-Item $Source -Destination $Dest -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq $Retries) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

# --- Header / banner ---
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
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host ""

# --- Check for BurntToast ---
Step "Checking for BurntToast"
$hasBT = $null -ne (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)
if ($hasBT) {
    Ok "BurntToast found"
} else {
    Warn "BurntToast not installed (needed for visual notifications)"
    Write-Host ""
    $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Install BurntToast module? (${GREEN}y${RESET}/${RED}n${RESET})"
    if ($answer -match '^[Yy]$') {
        try {
            Install-Module -Name BurntToast -Scope CurrentUser -Force -ErrorAction Stop
            Ok "BurntToast installed"
        } catch {
            Warn "Failed to install BurntToast: $_"
            Info "Visual notifications will be disabled (sound-only)"
        }
    } else {
        Info "Visual notifications will be disabled (sound-only)"
    }
}
Write-Host ""

# --- Install the script ---
# $MyInvocation.MyCommand.Path is $null when run via `irm | iex` -- that's how we detect the piped case.
Step "Installing status line script"
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

$myPath = $MyInvocation.MyCommand.Path
$localScript = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "statusline.ps1" } else { $null }
if ($localScript -and (Test-Path $localScript)) {
    try {
        Copy-WithRetry $localScript $scriptPath
        Ok "Copied from local repo"
    } catch {
        Err "Copy failed (file may be locked by Claude Code): $_"
        Err "Close Claude Code and try again."
        return
    }
} else {
    try {
        Invoke-WebRequest -Uri "$repo/statusline.ps1" -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        return
    }
}
Info "$scriptPath ($(HumanSize (Get-Item $scriptPath).Length))"
Write-Host ""

# --- Configure settings.json ---
# UTF-8 without BOM -- Claude Code rejects a leading BOM on settings.json.
Step "Configuring Claude Code settings"
$cmd = "powershell -NoProfile -File `"$scriptPath`""
# Windows needs refreshInterval >= 2; lower values cause rendering issues.
$newEntry = [PSCustomObject]@{ type = "command"; command = $cmd; refreshInterval = 2 }

if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Err "settings.json could not be parsed: $_"
        return
    }

    if ($null -eq $existing -or $existing -isnot [PSCustomObject]) {
        Err "settings.json could not be parsed as a JSON object. Please check the file manually."
        return
    }

    $skipStatusLine = $false
    if ($existing.statusLine) {
        Write-Host ""
        $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Existing statusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET})"
        if ($answer -notmatch '^[Yy]$') {
            $skipStatusLine = $true
            Warn "Skipped settings update"
            Info "Continuing with hook and notification setup..."
            Write-Host ""
        }
    }

    if (-not $skipStatusLine) {
        $existing | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $newEntry -Force
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $tmpPath = "$settingsPath.tmp"
            [System.IO.File]::WriteAllText($tmpPath, (Format-Json ($existing | ConvertTo-Json -Depth 10)), $utf8NoBom)
            Move-Item $tmpPath $settingsPath -Force
            Ok "Updated settings.json"
        } catch {
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            Err "Failed to update settings.json (file may be locked): $_"
            return
        }
    }
} else {
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, (Format-Json ([PSCustomObject]@{ statusLine = $newEntry } | ConvertTo-Json -Depth 10)), $utf8NoBom)
        Move-Item $tmpPath $settingsPath -Force
        Ok "Created settings.json"
    } catch {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Err "Failed to create settings.json (file may be locked): $_"
        return
    }
}
Info $settingsPath

# --- Install git-refresh hook script ---
Write-Host ""
Step "Installing git-refresh hook"
$localGitRefresh = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "git-refresh.ps1" } else { $null }
if ($localGitRefresh -and (Test-Path $localGitRefresh)) {
    try {
        Copy-WithRetry $localGitRefresh $gitRefreshPath
        Ok "Copied from local repo"
    } catch {
        Err "Copy failed (file may be locked by Claude Code): $_"
        Err "Close Claude Code and try again."
        return
    }
} else {
    try {
        Invoke-WebRequest -Uri "$repo/git-refresh.ps1" -OutFile $gitRefreshPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        return
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
    return
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

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, (Format-Json ($existing | ConvertTo-Json -Depth 10)), $utf8NoBom)
        Move-Item $tmpPath $settingsPath -Force
        Ok "PostToolUse hook enabled"
    } catch {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Warn "Failed to configure hook: $_"
    }
}

# --- Install notification script ---
Write-Host ""
Step "Installing notification script"
$localNotify = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "notify.ps1" } else { $null }
if ($localNotify -and (Test-Path $localNotify)) {
    try {
        Copy-WithRetry $localNotify $notifyPath
        Ok "Copied from local repo"
    } catch {
        Err "Copy failed (file may be locked by Claude Code): $_"
        Err "Close Claude Code and try again."
        return
    }
} else {
    try {
        Invoke-WebRequest -Uri "$repo/notify.ps1" -OutFile $notifyPath -UseBasicParsing -ErrorAction Stop
        Ok "Downloaded from GitHub"
    } catch {
        Err "Download failed: $_"
        Err "Run the installer from a local clone instead."
        return
    }
}
Info "$notifyPath ($(HumanSize (Get-Item $notifyPath).Length))"

# --- Install notification icon ---
$iconPath = "$claudeDir\claude-icon.png"
$localIcon = if ($myPath) { Join-Path (Split-Path -Parent $myPath) "..\assets\claude-icon.png" } else { $null }
if ($localIcon -and (Test-Path $localIcon)) {
    try { Copy-Item $localIcon -Destination $iconPath -Force -ErrorAction Stop; Ok "Icon installed" } catch {}
} else {
    $iconRepo = $repo -replace '/windows$', ''
    try { Invoke-WebRequest -Uri "$iconRepo/assets/claude-icon.png" -OutFile $iconPath -UseBasicParsing -ErrorAction Stop; Ok "Icon downloaded" } catch {}
}

# --- Create notification config ---
Write-Host ""
Step "Notification configuration"
$notifyConfigPath = "$claudeDir\notify-config.json"
$configWasNew = $false
if (Test-Path $notifyConfigPath) {
    Ok "Config already exists (preserving)"
    Info $notifyConfigPath
} else {
    $configWasNew = $true
    $defaultConfig = @'
{
  "permission":        { "sound": true, "visual": true },
  "stop":              { "sound": true, "visual": true },
  "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
  "context_high":      { "sound": false, "visual": true, "threshold": 70 },
  "compaction_start":  { "sound": true, "visual": true },
  "compaction_done":   { "sound": true, "visual": true }
}
'@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($notifyConfigPath, $defaultConfig, $utf8NoBom)
    Ok "Created default config"
    Info $notifyConfigPath
}

# --- Configure notification hooks ---
Write-Host ""
Step "Sound notifications"
Info "Plays a sound when Claude needs attention."

$hasNotifyHooks = $false
try {
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Err "settings.json could not be parsed: $_"
    return
}
if ($existing.hooks) {
    foreach ($eventName in @('PermissionRequest', 'Stop', 'PreCompact', 'PostCompact')) {
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

$enableSound = ''
$enableVisual = ''

if ($hasNotifyHooks) {
    Ok "Already configured"
} else {
    Write-Host ""
    $enableSound = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Enable sound notifications? (${GREEN}y${RESET}/${RED}n${RESET})"

    Write-Host ""
    Step "Visual notifications"
    Info "Shows native OS popups for Claude events."
    $hasBT = $null -ne (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)
    if ($hasBT) {
        Write-Host ""
        $enableVisual = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Enable visual notifications? (${GREEN}y${RESET}/${RED}n${RESET})"
    } else {
        Warn "BurntToast not found - visual notifications disabled"
        $enableVisual = 'n'
    }

    # Apply choices to config
    if ($configWasNew -and (($enableSound -ne '') -or ($enableVisual -ne ''))) {
        if (Test-Path $notifyConfigPath) {
            try {
                $ncfg = Get-Content $notifyConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($enableSound -ne '') {
                    $sndVal = $enableSound -match '^[Yy]$'
                } else {
                    $sndVal = $false
                    try { $sndVal = [bool]($ncfg.PSObject.Properties | Select-Object -First 1).Value.sound } catch {}
                }
                if ($enableVisual -ne '') {
                    $visVal = $enableVisual -match '^[Yy]$'
                } else {
                    $visVal = $false
                    try { $visVal = [bool]($ncfg.PSObject.Properties | Select-Object -First 1).Value.visual } catch {}
                }
                foreach ($prop in $ncfg.PSObject.Properties) {
                    $prop.Value.sound = $sndVal
                    $prop.Value.visual = $visVal
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($notifyConfigPath, (Format-Json ($ncfg | ConvertTo-Json -Depth 10)), $utf8NoBom)
                Ok "Config updated (sound=$sndVal, visual=$visVal)"
            } catch {
                Warn "Failed to update config: $_"
            }
        }
    }
}

# Register hooks — runs on fresh install (user said Y) or re-install (refreshes missing events)
if ($enableSound -match '^[Yy]$' -or $enableVisual -match '^[Yy]$' -or $hasNotifyHooks) {
    $notifyCmd = "powershell -NoProfile -File `"$notifyPath`""

    if (-not $existing.hooks) {
        $existing | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $hookPairs = @(
        @('PermissionRequest', [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = 'command'; command = "$notifyCmd permission"; async = $true }) }),
        @('Stop',              [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = 'command'; command = "$notifyCmd stop"; async = $true }) }),
        @('PreCompact',        [PSCustomObject]@{ matcher = '*'; hooks = @([PSCustomObject]@{ type = 'command'; command = "$notifyCmd compaction_start"; async = $true }) }),
        @('PostCompact',       [PSCustomObject]@{ matcher = '*'; hooks = @([PSCustomObject]@{ type = 'command'; command = "$notifyCmd compaction_done"; async = $true }) })
    )

    foreach ($pair in $hookPairs) {
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

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, (Format-Json ($existing | ConvertTo-Json -Depth 10)), $utf8NoBom)
        Move-Item $tmpPath $settingsPath -Force
        Ok "Notification hooks enabled (PermissionRequest, Stop, PreCompact, PostCompact)"
    } catch {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Warn "Failed to configure hooks: $_"
    }

    # Verification toast
    if ($enableVisual -match '^[Yy]$') {
        $hasBT = $null -ne (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)
        if ($hasBT) {
            try {
                Import-Module BurntToast -ErrorAction SilentlyContinue
                New-BurntToastNotification -Text "Claude Status Line", "Notifications enabled!" -ErrorAction SilentlyContinue
                Ok "Test notification sent"
            } catch {}
        }
    }
} elseif (-not $hasNotifyHooks) {
    Info "Skipped - run the installer again to enable later"
}

# --- Done ---
Write-Host ""
Write-Host "  ${GRAY}$([string][char]0x2501 * 43)${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate."
Write-Host ""
