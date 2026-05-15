#Requires -Version 5.1
# Claude Code statusLine for Windows PowerShell.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# --- ANSI helpers ---
$ESC  = [char]27
function ansi($code) { "$ESC[$($code)m" }
$RESET   = ansi 0
$DIM     = ansi 2
$BOLD    = ansi 1
$CYAN    = ansi 36
$MAGENTA = ansi 35
$YELLOW  = ansi 33
$GREEN   = ansi 32
$RED     = ansi 31
$BLUE    = ansi 34
$WHITE   = ansi 37
$GRAY    = ansi 90
$SEP = "${GRAY}$([char]0x2502)${RESET}"
# --- Read stdin + debug log ---
# Always exit 0 — any non-zero exit makes Claude Code hide the status line entirely.
$logPath = "$env:USERPROFILE\.claude\statusline-debug.log"
function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $logPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding utf8 } catch {}
}
Write-Log "=== invoked, PSVersion=$($PSVersionTable.PSVersion) PID=$PID ==="
try {
    $raw  = [Console]::In.ReadToEnd()
    Write-Log ("stdin bytes={0}" -f ($raw | Measure-Object -Character).Characters)
    Write-Log ("stdin head: " + ($(if ($raw.Length -gt 400) { $raw.Substring(0,400) } else { $raw }) -replace "`r?`n",' '))
    $json = $raw | ConvertFrom-Json
    Write-Log "json parse: OK"
} catch {
    Write-Log ("READ/PARSE FAILED: " + $_.Exception.Message)
    [Console]::Write("${RED}[statusline: bad JSON]${RESET}")
    exit 0
}
# Catch-all: degrade gracefully on any unhandled error below.
trap {
    Write-Log ("UNHANDLED: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage)
    [Console]::Write("${RED}[statusline: error - see statusline-debug.log]${RESET}")
    exit 0
}
# --- Helpers ---
function Get-Val($obj, [string[]]$path, $default = $null) {  # dotted-path lookup with default
    $cur = $obj
    foreach ($p in $path) {
        if ($null -eq $cur) { return $default }
        $cur = $cur.$p
    }
    if ($null -eq $cur) { return $default }
    return $cur
}
function Format-Tokens($n) {  # 1234567 -> "1.2M"
    if ($null -eq $n) { return $null }
    $v = [double]$n
    if ($v -ge 1000000) { return ('{0:F1}M' -f ($v / 1000000)) }
    if ($v -ge 1000)    { return ('{0:F1}K' -f ($v / 1000))    }
    return "$([int]$v)"
}
# --- 1. CWD ---
$sessionId = Get-Val $json @('session_id')
$cwd = Get-Val $json @('workspace','current_dir')
if (-not $cwd) { $cwd = Get-Val $json @('cwd') }
if (-not $cwd) { $cwd = (Get-Location).Path }
$userHome = $env:USERPROFILE
if ($cwd -and $userHome -and $cwd.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cwd = '~' + $cwd.Substring($userHome.Length).Replace('\','/')
} else {
    # Outside $HOME: collapse to ".../parent/leaf" so the row doesn't blow up.
    $parts = ($cwd -replace '\\','/').Split('/') | Where-Object { $_ -ne '' }
    if ($parts.Count -gt 2) {
        $cwd = '.../' + ($parts[-2]) + '/' + ($parts[-1])
    }
}
$cwdPart = "${CYAN}${cwd}${RESET}"
# --- 2. Model + Context window % ---
$modelDisplay = Get-Val $json @('model','display_name')
$modelId      = Get-Val $json @('model','id')
# Strip "Claude " prefix; cap at 24 chars so "Opus 4.7 (1M context)" still fits.
$modelShort = $modelDisplay
if ($modelShort) {
    $modelShort = $modelShort -replace '^Claude\s+',''
    if ($modelShort.Length -gt 24) { $modelShort = $modelShort.Substring(0,24) }
} else {
    $modelShort = 'unknown'
}
$ctxSize     = Get-Val $json @('context_window','context_window_size')
$usedPct     = Get-Val $json @('context_window','used_percentage')
$ctxLabel = ''
if ($ctxSize) {
    $ctxK = [int]($ctxSize / 1000)
    $ctxLabel = if ($ctxK -ge 1000) { "$([int]($ctxK/1000))M" } else { "${ctxK}K" }
}
$pctInt   = $null
$pctColor = $WHITE
if ($null -ne $usedPct) {
    $pctInt   = [int][Math]::Round($usedPct)
    $pctColor = if ($pctInt -ge 85) { $RED } elseif ($pctInt -ge 60) { $YELLOW } else { $GREEN }
}
$modelPart = "${MAGENTA}${modelShort}${RESET}"
# --- 2b. Context bar ---
# Always rendered. Missing usedPct -> 0%; missing ctxSize -> bar without tokens label.
$barWidth   = 30
$rawPct     = if ($null -ne $usedPct) { [double]$usedPct } else { 0 }
$pctClamped = [Math]::Max(0.0, [Math]::Min(100.0, $rawPct))
$barPctInt  = if ($null -ne $pctInt)  { $pctInt }   else { 0 }
$barColor   = if ($null -ne $pctInt)  { $pctColor } else { $GREEN }
$filled     = [int][Math]::Round($barWidth * $pctClamped / 100)
if ($filled -lt 0) { $filled = 0 }
if ($filled -gt $barWidth) { $filled = $barWidth }
$emptyCount = $barWidth - $filled
$filledChars = if ($filled -gt 0)     { [string]([char]0x2588) * $filled }     else { '' }
$emptyChars  = if ($emptyCount -gt 0) { [string]([char]0x2591) * $emptyCount } else { '' }
$bar = "${barColor}${filledChars}${RESET}${GRAY}${emptyChars}${RESET}"
$tokenSuffix = ''
if ($ctxSize) {
    # Prefer total_input_tokens (full precision); used_percentage is integer-rounded, so on a
    # 1M window "25%" maps to exactly 250000 and the display jumps in 10K steps.
    $totalInputTokens = Get-Val $json @('context_window','total_input_tokens')
    $usedTokens = if ($null -ne $totalInputTokens) { [long]$totalInputTokens } else { [int]([double]$ctxSize * $pctClamped / 100) }
    $usedLbl = if ($usedTokens -ge 1000000) {
        '{0:F1}M' -f ($usedTokens / 1000000.0)
    } elseif ($usedTokens -ge 1000) {
        '{0:F1}K' -f ($usedTokens / 1000.0)
    } else {
        "$usedTokens"
    }
    $tokenSuffix = " ${GRAY}$([char]0x00B7)${RESET} ${WHITE}${usedLbl}${RESET}${GRAY}/${ctxLabel}${RESET}"
}
$ctxBarPart = "${bar} ${barColor}${barPctInt}%${RESET}${tokenSuffix}"
# --- 3. Reasoning effort ---
$effortLevel = Get-Val $json @('effort','level')
$effortPart  = ''
if ($effortLevel) {
    $effortColor = switch ($effortLevel) {
        'low'    { $GRAY }
        'medium' { $WHITE }
        'high'   { $CYAN }
        'xhigh'  { $YELLOW }
        'max'    { $RED }
        default  { $WHITE }
    }
    $effortPart = "${effortColor}${effortLevel} effort${RESET}"
}
# --- 4. Git status ---
# --no-optional-locks: don't touch index.lock so we never block a concurrent git op.
$gitPart = ''
try {
    $gitCwd = Get-Val $json @('workspace','current_dir')
    if (-not $gitCwd) { $gitCwd = (Get-Location).Path }
    $gitDir = Join-Path $gitCwd '.git'
    if (Test-Path -LiteralPath $gitDir) {
        $branch = & git --no-optional-locks -C $gitCwd rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -and $LASTEXITCODE -eq 0) {
            $diffStat = & git --no-optional-locks -C $gitCwd diff --shortstat HEAD 2>$null
            $insertions = 0
            $deletions  = 0
            if ($diffStat -and $diffStat.Trim() -ne '') {
                if ($diffStat -match '(\d+) insertion') { $insertions = [int]$Matches[1] }
                if ($diffStat -match '(\d+) deletion')  { $deletions  = [int]$Matches[1] }
            }
            $porcelain = & git --no-optional-locks -C $gitCwd status --porcelain 2>$null
            $untracked = @($porcelain | Where-Object { $_ -match '^\?\?' }).Count
        } else {
            $branch = $null
        }
    } else {
        $branch = $null
    }
    if ($branch) {
        $isDirty = ($insertions -gt 0 -or $deletions -gt 0 -or $untracked -gt 0)
        $branchColor = if ($isDirty) { $YELLOW } else { $GREEN }
        $gitPart = "${branchColor}${branch}${RESET}"
        $statParts = @()
        if ($insertions -gt 0) { $statParts += "${GREEN}+${insertions}${RESET}" }
        if ($deletions  -gt 0) { $statParts += "${RED}-${deletions}${RESET}" }
        if ($untracked  -gt 0) { $statParts += "${GRAY}~${untracked}${RESET}" }
        if ($statParts.Count -gt 0) {
            $gitPart += ' ' + ($statParts -join ' ')
        }
    }
} catch {
    $gitPart = ''
}
# --- 5. Cost + Duration ---
# Fallbacks to legacy top-level keys — Claude Code JSON schema has shifted between versions.
$costPart = ''
$durationPart = ''
$totalCost = Get-Val $json @('cost','total_cost_usd')
if ($null -eq $totalCost) { $totalCost = Get-Val $json @('total_cost_usd') }
if ($null -ne $totalCost) {
    $costFmt  = '${0:F4}' -f [double]$totalCost
    $costColor = if ([double]$totalCost -gt 0.50) { $YELLOW } else { $GREEN }
    $costPart = "${costColor}${costFmt}${RESET}"
}
$durationMs = Get-Val $json @('cost','total_duration_ms')
if ($null -eq $durationMs) { $durationMs = Get-Val $json @('total_duration_ms') }
if ($null -eq $durationMs) { $durationMs = Get-Val $json @('duration_ms') }
if ($null -ne $durationMs) {
    $secs = [int]([double]$durationMs / 1000)
    $dStr = if ($secs -ge 3600) {
        '{0}h{1:D2}m' -f [int]($secs/3600), [int](($secs%3600)/60)
    } elseif ($secs -ge 60) {
        '{0}m{1:D2}s' -f [int]($secs/60), ($secs%60)
    } else {
        '{0}s' -f $secs
    }
    $durationPart = "${WHITE}${dStr}${RESET}"
}
# --- 5b/5c. Transcript: message count, idle/working, cumulative tokens ---
$msgCount = $null
$claudeIsIdle = $true   # default to idle when no transcript
$sessionInTokens         = [long]0
$sessionCacheWriteTokens = [long]0
$sessionCacheReadTokens  = [long]0
$sessionOutTokens        = [long]0
$hasSessionTokens = $false
$workingStartOutTokens = [long](-1)
$deltaIn         = [long]0
$deltaCacheWrite = [long]0
$deltaCacheRead  = [long]0
$deltaOut        = [long]0
$transcriptPath = Get-Val $json @('transcript_path')
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath -ErrorAction SilentlyContinue)) {
    try {
        # Per-session cache keyed on transcript mtime — only re-parse when it changes.
        $cachePath    = if ($sessionId) { Join-Path $env:TEMP ("statusline-cache-" + $sessionId + ".txt") } else { $null }
        $transcriptMt = (Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc.Ticks
        $useCache     = $false
        # Read prev values even on cache-miss so workingStartOutTokens survives invalidations.
        $prevWorkingStart = [long](-1)
        $prevIn         = [long]0
        $prevOut        = [long]0
        $prevCacheWrite = [long]0
        $prevCacheRead  = [long]0
        if ($cachePath -and (Test-Path -LiteralPath $cachePath)) {
            $cacheLine = Get-Content -LiteralPath $cachePath -Raw -ErrorAction SilentlyContinue
            if ($cacheLine) {
                $parts = $cacheLine.Trim().Split('|')
                if ($parts.Length -ge 7) {
                    $prevWorkingStart = [long]$parts[6]
                }
                if ($parts.Length -ge 9) {
                    $prevIn         = [long]$parts[3]
                    $prevOut        = [long]$parts[4]
                    $prevCacheWrite = [long]$parts[7]
                    $prevCacheRead  = [long]$parts[8]
                }
                # Require 13-field schema with deltas; else force re-parse.
                if (($parts.Length -ge 13) -and $parts[0] -eq "$transcriptMt") {
                    $msgCount                = [int]$parts[1]
                    $claudeIsIdle            = [bool]::Parse($parts[2])
                    $sessionInTokens         = [long]$parts[3]
                    $sessionOutTokens        = [long]$parts[4]
                    $hasSessionTokens        = [bool]::Parse($parts[5])
                    $workingStartOutTokens   = $prevWorkingStart
                    $sessionCacheWriteTokens = [long]$parts[7]
                    $sessionCacheReadTokens  = [long]$parts[8]
                    $deltaIn                 = [long]$parts[9]
                    $deltaOut                = [long]$parts[10]
                    $deltaCacheWrite         = [long]$parts[11]
                    $deltaCacheRead          = [long]$parts[12]
                    $useCache = $true
                }
            }
        }
        if (-not $useCache) {
            $rawTranscript = Get-Content -LiteralPath $transcriptPath -Raw -ErrorAction SilentlyContinue
            if ($rawTranscript) {
                $lines = $rawTranscript -split "(`r`n|`n)" | Where-Object { $_.Trim() -ne '' }
                # Real user messages = user-type lines that are NOT synthetic. Filter with
                # AND per-line; summing independent counters over-subtracts when markers
                # like `<command-name>` co-occur with `"toolUseResult"` on the same line.
                $msgCount = ($lines | Where-Object {
                    $_ -match '"type"\s*:\s*"user"' -and
                    $_ -notmatch '"toolUseResult"' -and
                    $_ -notmatch '"isMeta"\s*:\s*true' -and
                    $_ -notmatch '<command-name>' -and
                    $_ -notmatch '<local-command-stdout>'
                }).Count
                # Idle vs working: latest REAL message decides. Skip synthetic user entries
                # (tool results, isMeta, slash-command invocations/output) — otherwise running
                # /effort leaves no following assistant end_turn and we stay stuck on "working".
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    $ln = $lines[$i]
                    if ($ln -match '"toolUseResult"') { continue }
                    if ($ln -match '"isMeta"\s*:\s*true') { continue }
                    if ($ln -match '<command-name>') { continue }
                    if ($ln -match '<local-command-') { continue }
                    if ($ln -match '"type"\s*:\s*"assistant"') {
                        $claudeIsIdle = ($ln -match '"stop_reason"\s*:\s*"end_turn"')
                        break
                    }
                    if ($ln -match '"type"\s*:\s*"user"') {
                        $claudeIsIdle = $false
                        break
                    }
                }
                # Cumulative tokens by usage bucket across every assistant turn.
                foreach ($ln in $lines) {
                    if ($ln -notmatch '"type"\s*:\s*"assistant"') { continue }
                    $hasSessionTokens = $true
                    if ($ln -match '"input_tokens"\s*:\s*(\d+)')                { $sessionInTokens         += [long]$Matches[1] }
                    if ($ln -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $sessionCacheWriteTokens += [long]$Matches[1] }
                    if ($ln -match '"cache_read_input_tokens"\s*:\s*(\d+)')    { $sessionCacheReadTokens  += [long]$Matches[1] }
                    if ($ln -match '"output_tokens"\s*:\s*(\d+)')              { $sessionOutTokens        += [long]$Matches[1] }
                }
                # workingStartOutTokens: -1 when idle; otherwise preserve any prior baseline or set it now.
                $deltaIn         = [Math]::Max(0, $sessionInTokens - $prevIn)
                $deltaCacheWrite = [Math]::Max(0, $sessionCacheWriteTokens - $prevCacheWrite)
                $deltaCacheRead  = [Math]::Max(0, $sessionCacheReadTokens - $prevCacheRead)
                $deltaOut        = [Math]::Max(0, $sessionOutTokens - $prevOut)
                if ($claudeIsIdle) {
                    $workingStartOutTokens = [long](-1)
                } elseif ($prevWorkingStart -ge 0) {
                    $workingStartOutTokens = $prevWorkingStart
                } else {
                    $workingStartOutTokens = $sessionOutTokens
                }
                if ($cachePath) {
                    try {
                        # 13 fields: mtime|msgCount|idle|in|out|hasTokens|workingStart|cacheW|cacheR|dIn|dOut|dCacheW|dCacheR
                        [System.IO.File]::WriteAllText(
                            $cachePath,
                            ("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}" -f $transcriptMt, $msgCount, $claudeIsIdle, $sessionInTokens, $sessionOutTokens, $hasSessionTokens, $workingStartOutTokens, $sessionCacheWriteTokens, $sessionCacheReadTokens, $deltaIn, $deltaOut, $deltaCacheWrite, $deltaCacheRead),
                            (New-Object System.Text.UTF8Encoding $false))
                    } catch {}
                }
            }
        }
    } catch {
        Write-Log ("transcript block FAILED: " + $_.Exception.Message)
        $msgCount = $null
    }
}
# Tokens row — session cumulative, broken out by usage bucket (in / cache up / cache down / out).
function Format-Bucket($label, $value, $delta, $idleColor, $activeColor, $arrow) {
    $lbl = Format-Tokens $value
    $dLbl = Format-Tokens $delta
    if (-not $dLbl) { $dLbl = '0' }
    $arrowPart = ''
    if ($arrow) { $arrowPart = "${GRAY}${arrow}${RESET}" }
    if ($delta -gt 0) {
        return "${activeColor}${BOLD}${label}${RESET}${arrowPart} ${activeColor}${lbl}${RESET} ${GREEN}(+${dLbl})${RESET}"
    } else {
        return "${DIM}${label}${RESET}${arrowPart} ${idleColor}${lbl}${RESET} ${DIM}(+${dLbl})${RESET}"
    }
}
# Always render — zero values get the dim "(+0)" idle styling.
$sep        = "  ${GRAY}$([char]0x00B7)${RESET}  "
$tokensPart = (Format-Bucket "in" $sessionInTokens $deltaIn $CYAN $CYAN) `
    + $sep + (Format-Bucket "cache" $sessionCacheWriteTokens $deltaCacheWrite $GRAY $YELLOW "$([char]0x2191)") `
    + $sep + (Format-Bucket "cache" $sessionCacheReadTokens $deltaCacheRead $GRAY $CYAN "$([char]0x2193)") `
    + $sep + (Format-Bucket "out" $sessionOutTokens $deltaOut $MAGENTA $MAGENTA)
# Status dot — shown on model row.
if ($claudeIsIdle) {
    $statusDot   = "${GREEN}$([char]0x25CF)${RESET}"
    $statusLabel = "${WHITE}ready${RESET}"
    $statusPart  = "${statusDot}  ${statusLabel}"
} else {
    $statusDot   = "${YELLOW}$([char]0x25CB)${RESET}"
    $statusLabel = "${YELLOW}working${RESET}"
    $statusPart  = "${statusDot}  ${statusLabel}"
    if ($workingStartOutTokens -ge 0 -and $sessionOutTokens -gt $workingStartOutTokens) {
        $delta = $sessionOutTokens - $workingStartOutTokens
        $deltaLabel = Format-Tokens $delta
        $statusPart += "  ${GRAY}$([char]0x00B7)${RESET}  ${CYAN}+${deltaLabel}${RESET} ${DIM}tokens${RESET}"
    }
}
# Message count — shown on cost row.
$msgPart = ''
if ($null -ne $msgCount -and $msgCount -gt 0) {
    $msgLabel = if ($msgCount -eq 1) { 'message' } else { 'messages' }
    $msgPart = "${WHITE}${msgCount}${RESET} ${DIM}${msgLabel}${RESET}"
}
# --- 6. Rate limits (5h + 7d) — Claude.ai subscribers only ---
# Usage + burn-rate vs linear pace + time to reset. Arrow hidden within +/-1% of pace.
function Format-Duration([int]$secs) {
    if ($secs -le 0) { return $null }
    # Floor explicitly: [int]'s banker's rounding can overflow units (2h59.98m -> "3h60m").
    if ($secs -lt 3600)  { return ("{0}m" -f [int][Math]::Floor($secs / 60.0)) }
    if ($secs -lt 86400) {
        $h = [int][Math]::Floor($secs / 3600.0)
        $m = [int][Math]::Floor(($secs - $h * 3600) / 60.0)
        if ($m -eq 0) { return "${h}h" } else { return "${h}h${m}m" }
    }
    $d = [int][Math]::Floor($secs / 86400.0)
    $h = [int][Math]::Floor(($secs - $d * 86400) / 3600.0)
    if ($h -eq 0) { return "${d}d" } else { return "${d}d${h}h" }
}
function Format-Window([string]$label, $pctVal, $resetsAt, [int]$windowSecs) {
    if ($null -eq $pctVal) { return $null }
    $pct = [int][Math]::Round([double]$pctVal)
    $pctColor = if ($pct -ge 80) { $RED } elseif ($pct -ge 50) { $YELLOW } else { $GREEN }
    $burnPart = ''
    $resetPart = ''
    if ($null -ne $resetsAt) {
        $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remaining = [int]$resetsAt - $now
        if ($remaining -gt 0 -and $remaining -le $windowSecs) {
            # Compare actual pct against linear-pace expectation; +delta = over pace, -delta = under.
            $expectedPct = ($windowSecs - $remaining) * 100.0 / $windowSecs
            $delta = $pct - $expectedPct
            if ([Math]::Abs($delta) -ge 1) {
                $burnInt = [int][Math]::Round([Math]::Abs($delta))
                if ($delta -gt 0) {
                    $burnPart = " ${RED}$([char]0x21E1)${burnInt}%${RESET}"
                } else {
                    $burnPart = " ${GREEN}$([char]0x21E3)${burnInt}%${RESET}"
                }
            }
            $rLbl = Format-Duration $remaining
            if ($rLbl) { $resetPart = " ${GRAY}(${rLbl})${RESET}" }
        }
    }
    return "${DIM}${label}${RESET} ${pctColor}${pct}%${RESET}${burnPart}${resetPart}"
}
$ratePart = ''
$fivePct  = Get-Val $json @('rate_limits','five_hour','used_percentage')
$fiveRes  = Get-Val $json @('rate_limits','five_hour','resets_at')
$sevenPct = Get-Val $json @('rate_limits','seven_day','used_percentage')
$sevenRes = Get-Val $json @('rate_limits','seven_day','resets_at')
if ($null -ne $fivePct -or $null -ne $sevenPct) {
    $parts5d = @()
    $part5 = Format-Window '5h' $fivePct $fiveRes 18000
    $part7 = Format-Window '7d' $sevenPct $sevenRes 604800
    if ($part5) { $parts5d += $part5 }
    if ($part7) { $parts5d += $part7 }
    $ratePart = $parts5d -join "  ${GRAY}$([char]0x00B7)${RESET}  "
}
# --- 7. Agent / subagent status (--agent startup mode only) ---
$agentPart = ''
$agentName = Get-Val $json @('agent','name')
if ($agentName) {
    $agentPart = "${BLUE}${BOLD}${agentName}${RESET}"
    $agentCompact = ''
    if ($null -ne $pctInt) {
        $sep = "  ${GRAY}$([char]0x00B7)${RESET}  "
        $agentCompact += "${sep}${pctColor}${pctInt}%${RESET}"
    }
    $agentIn  = Get-Val $json @('context_window','current_usage','input_tokens') 0
    $agentOut = Get-Val $json @('context_window','current_usage','output_tokens') 0
    $inFmt  = Format-Tokens $agentIn
    $outFmt = Format-Tokens $agentOut
    if (-not $inFmt)  { $inFmt  = '0' }
    if (-not $outFmt) { $outFmt = '0' }
    $sep2 = "  ${GRAY}$([char]0x00B7)${RESET}  "
    $agentCompact += "${sep2}${DIM}in${RESET} ${WHITE}${inFmt}${RESET}  ${DIM}out${RESET} ${WHITE}${outFmt}${RESET}"
    $agentPart += "  ${agentCompact}"
}
# --- 7b. Subagent context ---
# One row per ACTIVE subagent (last assistant stop_reason != "end_turn").
# Transcripts: <project>/<sessionId>/subagents/agent-*.jsonl + sibling .meta.json.
$subagentRows = @()
if ($sessionId -and $transcriptPath) {
    $projectDir   = Split-Path -Parent $transcriptPath
    $sessionBase  = [System.IO.Path]::GetFileNameWithoutExtension($transcriptPath)
    $subagentsDir = Join-Path $projectDir (Join-Path $sessionBase 'subagents')
    if (Test-Path -LiteralPath $subagentsDir) {
        $saFiles = Get-ChildItem -LiteralPath $subagentsDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime
        foreach ($sa in $saFiles) {
            try {
                # Scan from end for the last assistant entry.
                $saLines    = [System.IO.File]::ReadAllLines($sa.FullName)
                $lastAssist = $null
                for ($i = $saLines.Length - 1; $i -ge 0; $i--) {
                    if ($saLines[$i] -match '"type"\s*:\s*"assistant"') { $lastAssist = $saLines[$i]; break }
                }
                if (-not $lastAssist) { continue }
                if ($lastAssist -match '"stop_reason"\s*:\s*"end_turn"') { continue }  # skip completed turns
                $inTok = 0; $cwTok = 0; $crTok = 0
                if ($lastAssist -match '"input_tokens"\s*:\s*(\d+)')                { $inTok = [long]$Matches[1] }
                if ($lastAssist -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $cwTok = [long]$Matches[1] }
                if ($lastAssist -match '"cache_read_input_tokens"\s*:\s*(\d+)')    { $crTok = [long]$Matches[1] }
                $saUsed = $inTok + $cwTok + $crTok
                # 200K default; 1M for Opus 4.x [1m] variants.
                $saModel = ''
                if ($lastAssist -match '"model"\s*:\s*"([^"]+)"') { $saModel = $Matches[1] }
                $saCtxSize = 200000
                if ($saModel -match '\[1m\]' -or $saModel -match '-1m\b') { $saCtxSize = 1000000 }
                $agentDisplay = $sa.BaseName -replace '^agent-',''
                $metaPath = Join-Path $sa.Directory.FullName "$($sa.BaseName).meta.json"
                if (Test-Path -LiteralPath $metaPath) {
                    try {
                        $meta = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($meta.agentType) { $agentDisplay = $meta.agentType }
                    } catch {}
                }
                # Bar + label — mirrors the main context row.
                $saPctRaw  = [Math]::Max(0.0, [Math]::Min(100.0, ($saUsed / [double]$saCtxSize) * 100))
                $saPctInt  = [int][Math]::Round($saPctRaw)
                $saColor   = if ($saPctInt -ge 85) { $RED } elseif ($saPctInt -ge 60) { $YELLOW } else { $GREEN }
                $saFilled  = [int][Math]::Round($barWidth * $saPctRaw / 100)
                if ($saFilled -lt 0) { $saFilled = 0 } elseif ($saFilled -gt $barWidth) { $saFilled = $barWidth }
                $saEmpty   = $barWidth - $saFilled
                $saFilledChars = if ($saFilled -gt 0) { [string]([char]0x2588) * $saFilled } else { '' }
                $saEmptyChars  = if ($saEmpty  -gt 0) { [string]([char]0x2591) * $saEmpty  } else { '' }
                $saBar     = "${saColor}${saFilledChars}${RESET}${GRAY}${saEmptyChars}${RESET}"
                $saUsedLbl = if ($saUsed -ge 1000000) { '{0:F1}M' -f ($saUsed / 1000000.0) }
                             elseif ($saUsed -ge 1000) { '{0:F1}K' -f ($saUsed / 1000.0) }
                             else { "$saUsed" }
                $saCtxLbl  = if ($saCtxSize -ge 1000000) { '{0:F0}M' -f ($saCtxSize / 1000000.0) }
                             else { '{0:F0}K' -f ($saCtxSize / 1000.0) }
                $saSep     = "  ${GRAY}$([char]0x00B7)${RESET}  "
                $saWorking = "${YELLOW}$([char]0x25CB) working${RESET}"
                $saContent = "${saBar} ${saColor}${saPctInt}%${RESET}${saSep}${WHITE}${saUsedLbl}${RESET}${GRAY}/${saCtxLbl}${RESET}${saSep}${BLUE}${agentDisplay}${RESET}${saSep}${saWorking}"
                $subagentRows += @{ s = 1; label = 'agent'; content = $saContent }
            } catch {}
        }
    }
}
# --- Assemble box ---
# Heavy frame + heavy section divider; light dashes for inter-row rule within a section.
$BoxTL  = [char]0x250F
$BoxTR  = [char]0x2513
$BoxBL  = [char]0x2517
$BoxBR  = [char]0x251B
$BoxH   = [char]0x2501
$BoxV   = [char]0x2503
$BoxT_L  = [char]0x2523
$BoxT_R  = [char]0x252B
$BoxSecH = [char]0x2501
$BoxRowH = [char]0x2500
# Visible width — strip ANSI escapes so color codes don't count.
$ansiPattern = "$ESC\[[0-9;]*[a-zA-Z]"
function Get-Vis([string]$s) {
    if (-not $s) { return 0 }
    return ($s -replace $ansiPattern, '').Length
}
$LABEL_W = 7  # longest label: "context"
# Rows with empty content are dropped — box auto-hides sections with no data.
$rowSep = "  ${GRAY}$([char]0x00B7)${RESET}  "
$modelRow = $modelPart
if ($effortPart) { $modelRow = "${modelRow}${rowSep}${effortPart}" }
if ($statusPart) { $modelRow = "${modelRow}${rowSep}${statusPart}" }
$costRow = ''
$costParts = @()
if ($costPart)     { $costParts += $costPart }
if ($msgPart)      { $costParts += $msgPart }
if ($durationPart) { $costParts += $durationPart }
$costRow = $costParts -join $rowSep
$pathRow = $cwdPart
$pathLabel = 'project'
if ($gitPart) {
    $pathRow = "${cwdPart}${rowSep}${DIM}on${RESET} ${gitPart}"
    $pathLabel = 'repo'
}
$rowSpec = @(
    @{ s=0; label=$pathLabel; content=$pathRow      }
    @{ s=0; label='agent';  content=$agentPart      }
    @{ s=1; label='model';  content=$modelRow       }
    @{ s=1; label='context'; content=$ctxBarPart    }
) + $subagentRows + @(
    @{ s=1; label='tokens'; content=$tokensPart     }
    @{ s=1; label='cost'; content=$costRow          }
    @{ s=1; label='limits'; content=$ratePart       }
)
$rows = @()
foreach ($spec in $rowSpec) {
    if (-not $spec.content) { continue }
    $lbl = $spec.label.PadRight($LABEL_W)
    $inner = " ${DIM}${lbl}${RESET} ${GRAY}$([char]0x2502)${RESET}  $($spec.content) "
    $rows += @{ s = $spec.s; inner = $inner }
}
# Box inner width: max visible width across rows, clamped to a minimum.
$maxInner = 30
foreach ($r in $rows) {
    $vl = Get-Vis $r.inner
    if ($vl -gt $maxInner) { $maxInner = $vl }
}
$heavyHoriz = [string]$BoxH * $maxInner
$topRule    = "${GRAY}${BoxTL}${heavyHoriz}${BoxTR}${RESET}"
$secDivRule = "${GRAY}${BoxT_L}${heavyHoriz}${BoxT_R}${RESET}"
$botRule    = "${GRAY}${BoxBL}${heavyHoriz}${BoxBR}${RESET}"
# Inter-row divider with a cross junction so the inner vertical reads continuously.
$leftDashCount  = $LABEL_W + 1
$rightDashCount = $maxInner - $LABEL_W - 4
if ($rightDashCount -lt 1) { $rightDashCount = 1 }
$leftDashes  = [string]$BoxRowH * $leftDashCount
$rightDashes = [string]$BoxRowH * $rightDashCount
$crossChar   = [char]0x253C
$rowDivRule  = "${GRAY}${BoxV}${RESET} ${GRAY}${leftDashes}${RESET}${GRAY}${crossChar}${RESET}${GRAY}${rightDashes}${RESET} ${GRAY}${BoxV}${RESET}"
$output = @($topRule)
$prevSec = -1
$first = $true
foreach ($r in $rows) {
    if (-not $first) {
        if ($r.s -ne $prevSec) { $output += $secDivRule } else { $output += $rowDivRule }
    }
    $first = $false
    $prevSec = $r.s
    $padCount = $maxInner - (Get-Vis $r.inner)
    if ($padCount -lt 0) { $padCount = 0 }
    $padded = $r.inner + (' ' * $padCount)
    $output += "${GRAY}${BoxV}${RESET}${padded}${GRAY}${BoxV}${RESET}"
}
$output += $botRule
$finalOutput = $output -join "`n"
Write-Log ("about to write: lines={0} chars={1}" -f $output.Count, $finalOutput.Length)
Write-Host $finalOutput -NoNewline
Write-Log "stdout write: OK (via Write-Host)"