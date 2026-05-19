#Requires -Version 5.1
param([string]$Event, [string]$Value)
if (-not $Event) { exit 0 }

$stdinData = $null
if ($Event -eq 'permission') {
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

# --- Sound dispatch ---
if ($soundEnabled) {
    switch ($Event) {
        'permission'       { [System.Media.SystemSounds]::Exclamation.Play() }
        'stop'             { [System.Media.SystemSounds]::Asterisk.Play() }
        'compaction_start' { [System.Media.SystemSounds]::Exclamation.Play() }
        'compaction_done'  { [System.Media.SystemSounds]::Asterisk.Play() }
        'rate_limit'       { [System.Media.SystemSounds]::Hand.Play() }
        'context_high'     { [System.Media.SystemSounds]::Hand.Play() }
    }
    Write-Log "sound dispatched"
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
            'stop'             { 'Task complete' }
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
                    New-BurntToastNotification -Text "Claude Code", $msg -AppLogo $iconPath -ErrorAction SilentlyContinue
                } else {
                    New-BurntToastNotification -Text "Claude Code", $msg -ErrorAction SilentlyContinue
                }
                Write-Log "visual dispatched: $msg"
            } catch {
                Write-Log "visual failed: $_"
            }
        }
    }
}

exit 0
