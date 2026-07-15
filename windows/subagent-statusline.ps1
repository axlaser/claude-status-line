#Requires -Version 5.1
# Tee Claude Code's subagentStatusLine tasks payload to a session-scoped state file.
# Called by Claude Code once per refresh tick with all visible tasks as JSON on stdin.
# Prints nothing to stdout (output would override the default agent-panel rendering).
# Always exits 0 (silent degradation).

$logPath = "$env:USERPROFILE\.claude\statusline-debug.log"

function Write-Log([string]$msg) {
    if (-not $env:STATUSLINE_DEBUG) { return }
    try { Add-Content -LiteralPath $logPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] subagent-statusline: {1}" -f (Get-Date), $msg) -Encoding utf8 } catch {}
}

$raw = $null
if ([Console]::IsInputRedirected) {
    try { $raw = [Console]::In.ReadToEnd() } catch {}
}
if (-not $raw) { exit 0 }

Write-Log "payload: $raw"

try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
if ($null -eq $json) { exit 0 }

$sessionId = $json.session_id
if (-not $sessionId) { exit 0 }
$safeId = $sessionId -replace '[^a-zA-Z0-9_-]', ''
if (-not $safeId) { exit 0 }

# Keep only the per-task fields the statusline reader consumes; drop absent ones
# (model/contextWindowSize are omitted until Claude Code >= v2.1.205 resolves them).
$taskFields = 'id', 'name', 'type', 'description', 'status', 'model', 'contextWindowSize', 'tokenCount', 'startTime'
$outTasks = @()
foreach ($task in @($json.tasks)) {
    if ($null -eq $task) { continue }
    $entry = [ordered]@{}
    foreach ($field in $taskFields) {
        $prop = $task.PSObject.Properties[$field]
        if ($null -ne $prop -and $null -ne $prop.Value) { $entry[$field] = $prop.Value }
    }
    $outTasks += [pscustomobject]$entry
}

$statePath = $null
try { $statePath = Join-Path $env:TEMP "statusline-tasks-$safeId.json" } catch {}
if (-not $statePath) { exit 0 }

# Atomic write: temp file in the same directory, then rename, so a concurrent
# statusline refresh never reads a torn file.
$tmpPath = "$statePath.tmp.$PID"
try {
    $stateJson = [pscustomobject]@{ tasks = @($outTasks) } | ConvertTo-Json -Compress -Depth 5
    [System.IO.File]::WriteAllText($tmpPath, $stateJson)
    Move-Item -LiteralPath $tmpPath -Destination $statePath -Force -ErrorAction Stop
} catch {
    Write-Log "state write failed: $_"
    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
}

exit 0
