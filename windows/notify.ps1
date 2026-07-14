#Requires -Version 5.1
param([string]$Event, [string]$Value)
if (-not $Event) { exit 0 }

$stdinData = $null
if ($Event -eq 'permission' -and [Console]::IsInputRedirected) {
    try { $stdinData = [Console]::In.ReadToEnd() } catch {}
}

$configPath = "$env:USERPROFILE\.claude\notify-config.json"
$logPath    = "$env:USERPROFILE\.claude\statusline-debug.log"

function Write-Log([string]$msg) {
    if (-not $env:STATUSLINE_DEBUG) { return }
    try { Add-Content -LiteralPath $logPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] notify: {1}" -f (Get-Date), $msg) -Encoding utf8 } catch {}
}

Write-Log "event=$Event value=$Value"

# --- Load config ---
$soundEnabled  = $true
$visualEnabled = $true

if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $evtCfg = $cfg.$Event
        if ($null -ne $evtCfg) {
            if ($evtCfg.sound -eq $false) { $soundEnabled = $false }
            if ($evtCfg.visual -eq $false) { $visualEnabled = $false }
        }
        Write-Log "config loaded: sound=$soundEnabled visual=$visualEnabled"
    } catch {
        Write-Log "config parse error: $_"
    }
} else {
    Write-Log "no config, using defaults"
}

# --- Resolve sound file (played after visual so toast appears instantly) ---
$soundPath = $null
if ($soundEnabled) {
    $soundFile = switch ($Event) {
        'permission'       { 'Windows Exclamation.wav' }
        'stop'             { 'chimes.wav' }
        'compaction_start' { 'Windows Battery Low.wav' }
        'compaction_done'  { 'chimes.wav' }
        'rate_limit'       { 'Windows Battery Critical.wav' }
        'context_high'     { 'Windows Battery Critical.wav' }
    }
    if ($soundFile) {
        $resolved = Join-Path "$env:SystemRoot\Media" $soundFile
        if (Test-Path -LiteralPath $resolved) { $soundPath = $resolved }
    }
}

# --- Visual dispatch (BurntToast) ---
if ($visualEnabled) {
    $hasBT = $null -ne (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)
    if (-not $hasBT) {
        Write-Log "BurntToast not found, skipping visual"
    } else {
        $msg = switch ($Event) {
            'permission'       {
                $permMsg = 'Waiting for permission'
                if ($stdinData) {
                    try {
                        $hookJson = $stdinData | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $toolName = $hookJson.tool_name
                        if ($toolName) {
                            $detail = switch ($toolName) {
                                'Bash'  { $hookJson.tool_input.command }
                                'Edit'  { $hookJson.tool_input.file_path }
                                'Write' { $hookJson.tool_input.file_path }
                                'Read'  { $hookJson.tool_input.file_path }
                                default { $null }
                            }
                            if ($detail) {
                                if ($toolName -in @('Edit','Write','Read')) {
                                    $projRoot = $PWD.Path.TrimEnd('\')
                                    if ($detail.StartsWith($projRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                                        $detail = $detail.Substring($projRoot.Length + 1)
                                    }
                                }
                                if ($detail.Length -gt 80) { $detail = $detail.Substring(0, 80) }
                                $permMsg = "${toolName}: ${detail}"
                            } else {
                                $permMsg = $toolName
                            }
                        }
                    } catch {}
                }
                $permMsg
            }
            'stop'             { 'Finished working' }
            'compaction_start' { 'Compacting context...' }
            'compaction_done'  { 'Context compacted' }
            'rate_limit'       { "Rate limit at ${Value}%" }
            'context_high'     { "Context window at ${Value}%" }
            default            { '' }
        }
        if ($msg) {
            try {
                Import-Module BurntToast -ErrorAction SilentlyContinue
                $iconPath = "$env:USERPROFILE\.claude\claude-icon.png"
                if (Test-Path $iconPath) {
                    New-BurntToastNotification -Text "Claude Code", $msg -AppLogo $iconPath -Silent -ErrorAction SilentlyContinue
                } else {
                    New-BurntToastNotification -Text "Claude Code", $msg -Silent -ErrorAction SilentlyContinue
                }
                Write-Log "visual dispatched: $msg"
            } catch {
                Write-Log "visual failed: $_"
            }
        }
    }
}

# --- Sound dispatch (after visual so toast appears instantly) ---
if ($soundPath) {
    try {
        $player = New-Object System.Media.SoundPlayer $soundPath
        $player.PlaySync()
        Write-Log "sound dispatched"
    } catch {
        Write-Log "sound failed: $_"
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
    }
} elseif ($soundEnabled) {
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
    Write-Log "sound dispatched (fallback)"
}

exit 0
