#Requires -Version 5.1
# Refresh statusline git cache after file-modifying tool uses.
# Called by Claude Code PostToolUse hook with event JSON on stdin.
try {
    $event = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch { exit 0 }

$toolName = $event.tool_name
switch ($toolName) {
    { $_ -in 'Edit','Write','MultiEdit','Bash','NotebookEdit' } { break }
    default { exit 0 }
}

$sessionId = $event.session_id
if (-not $sessionId) { exit 0 }
$safeId = $sessionId -replace '[^a-zA-Z0-9_-]', ''
Remove-Item (Join-Path $env:TEMP "statusline-git-$safeId.txt") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP "statusline-oc-$safeId.txt") -Force -ErrorAction SilentlyContinue
