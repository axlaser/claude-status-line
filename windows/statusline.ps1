#Requires -Version 5.1
# Claude Code statusLine script for Windows PowerShell
# Receives JSON on stdin from Claude Code, emits a single UTF-8 line.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# ── ANSI helpers ────────────────────────────────────────────────────────────
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
# ── Read stdin ───────────────────────────────────────────────────────────────
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
# Wrap remainder so any error surfaces in the log
trap {
    Write-Log ("UNHANDLED: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage)
    [Console]::Write("${RED}[statusline: error - see statusline-debug.log]${RESET}")
    exit 0
}
# ── Helper: safe property access ─────────────────────────────────────────────
function Get-Val($obj, [string[]]$path, $default = $null) {
    $cur = $obj
    foreach ($p in $path) {
        if ($null -eq $cur) { return $default }
        $cur = $cur.$p
    }
    if ($null -eq $cur) { return $default }
    return $cur
}
# ── Helper: human-readable token count (e.g. 1234567 → "1.2M") ───────────────
function Format-Tokens($n) {
    if ($null -eq $n) { return $null }
    $v = [double]$n
    if ($v -ge 1000000) { return ('{0:F1}M' -f ($v / 1000000)) }
    if ($v -ge 1000)    { return ('{0:F1}K' -f ($v / 1000))    }
    return "$([int]$v)"
}
# ═══════════════════════════════════════════════════════════════════════════════
# 1. CWD — shortened relative to $HOME
# ═══════════════════════════════════════════════════════════════════════════════
$sessionId = Get-Val $json @('session_id')
$cwd = Get-Val $json @('workspace','current_dir')
if (-not $cwd) { $cwd = Get-Val $json @('cwd') }
if (-not $cwd) { $cwd = (Get-Location).Path }
$userHome = $env:USERPROFILE
if ($cwd -and $userHome -and $cwd.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase)) {
    $cwd = '~' + $cwd.Substring($userHome.Length).Replace('\','/')
} else {
    # Just show the last 2 path components to stay short
    $parts = ($cwd -replace '\\','/').Split('/') | Where-Object { $_ -ne '' }
    if ($parts.Count -gt 2) {
        $cwd = '.../' + ($parts[-2]) + '/' + ($parts[-1])
    }
}
$cwdPart = "${CYAN}${cwd}${RESET}"
# ═══════════════════════════════════════════════════════════════════════════════
# 2. Model + Context window %
# ═══════════════════════════════════════════════════════════════════════════════
$modelDisplay = Get-Val $json @('model','display_name')
$modelId      = Get-Val $json @('model','id')
# Shorten model display name for status line brevity
$modelShort = $modelDisplay
if ($modelShort) {
    # e.g. "Claude Opus 4.7" → "Opus 4.7"   "Claude Sonnet 4.5" → "Sonnet 4.5"
    $modelShort = $modelShort -replace '^Claude\s+',''
    # Truncate anything past 24 chars (fits "Opus 4.7 (1M context)" cleanly)
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
# ═══════════════════════════════════════════════════════════════════════════════
# 2b. Context bar (line 2) — colored progress bar for context-window usage
# ═══════════════════════════════════════════════════════════════════════════════
$ctxBarPart = ''
if ($null -ne $pctInt) {
    $barWidth   = 30
    $pctClamped = [Math]::Max(0, [Math]::Min(100, [double]$usedPct))
    $filled     = [int][Math]::Round($barWidth * $pctClamped / 100)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $barWidth) { $filled = $barWidth }
    $emptyCount = $barWidth - $filled
    $filledChars = if ($filled -gt 0)     { [string]([char]0x2588) * $filled }     else { '' }
    $emptyChars  = if ($emptyCount -gt 0) { [string]([char]0x2591) * $emptyCount } else { '' }
    $bar = "${pctColor}${filledChars}${RESET}${GRAY}${emptyChars}${RESET}"
    $tokenSuffix = ''
    if ($ctxSize) {
        $usedTokens = [int]([double]$ctxSize * $pctClamped / 100)
        $usedLbl = if ($usedTokens -ge 1000000) {
            '{0:F1}M' -f ($usedTokens / 1000000.0)
        } elseif ($usedTokens -ge 1000) {
            '{0:F0}K' -f ($usedTokens / 1000.0)
        } else {
            "$usedTokens"
        }
        $tokenSuffix = " ${GRAY}$([char]0x00B7)${RESET} ${WHITE}${usedLbl}${RESET}${GRAY}/${ctxLabel}${RESET}"
    }
    $ctxBarPart = "${bar} ${pctColor}${pctInt}%${RESET}${tokenSuffix}"
}
# ═══════════════════════════════════════════════════════════════════════════════
# 3. Reasoning effort level
# ═══════════════════════════════════════════════════════════════════════════════
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
# ═══════════════════════════════════════════════════════════════════════════════
# 4. Git status — branch + diff stats (+insertions / -deletions) + untracked count
# ═══════════════════════════════════════════════════════════════════════════════
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
# ═══════════════════════════════════════════════════════════════════════════════
# 5. Cost + Duration
# ═══════════════════════════════════════════════════════════════════════════════
$costPart = ''
$durationPart = ''
# Cost — field may not exist in current schema; read defensively
$totalCost = Get-Val $json @('cost','total_cost_usd')
if ($null -eq $totalCost) { $totalCost = Get-Val $json @('total_cost_usd') }
if ($null -ne $totalCost) {
    $costFmt  = '${0:F4}' -f [double]$totalCost
    $costColor = if ([double]$totalCost -gt 0.50) { $YELLOW } else { $GREEN }
    $costPart = "${costColor}${costFmt}${RESET}"
}
# Duration — per Claude Code docs, lives at cost.total_duration_ms.
# Also fall back to legacy top-level locations for safety.
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
# ═══════════════════════════════════════════════════════════════════════════════
# 5b/5c. Transcript-derived data: message count, idle/working state, cumulative tokens
# ═══════════════════════════════════════════════════════════════════════════════
$msgCount = $null
$claudeIsIdle = $true   # default to idle when there's no transcript to read
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
        # Cache transcript-derived data by transcript mtime. Cache is per-session
        # (keyed on session_id) so concurrent sessions don't read each other's state.
        # mtime-based invalidation means we only re-parse when the transcript actually
        # changes — no time-based staleness for the idle/working signal.
        $cachePath    = if ($sessionId) { Join-Path $env:TEMP ("statusline-cache-" + $sessionId + ".txt") } else { $null }
        $transcriptMt = (Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc.Ticks
        $useCache     = $false
        # Always read the previous cached `workingStartOutTokens` (if any) — even on
        # cache-miss — so we can preserve it across cache invalidations within a
        # single working period.
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
                # Require the 13-field schema with deltas, else force re-parse.
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
                # Real user messages = all `"type":"user"` rows MINUS synthetic ones:
                #   - tool results (carry `toolUseResult`)
                #   - slash-command caveats (carry `"isMeta":true`)
                #   - slash-command invocations (content has `<command-name>`)
                $totalUser    = ([regex]::Matches($rawTranscript, '"type"\s*:\s*"user"')).Count
                $toolResults  = ([regex]::Matches($rawTranscript, '"toolUseResult"')).Count
                $metaUsers    = ([regex]::Matches($rawTranscript, '"isMeta"\s*:\s*true')).Count
                $slashUsers   = ([regex]::Matches($rawTranscript, '<command-name>')).Count
                $msgCount     = [Math]::Max(0, $totalUser - $toolResults - $metaUsers - $slashUsers)
                $lines = $rawTranscript -split "(`r`n|`n)" | Where-Object { $_.Trim() -ne '' }
                # Idle vs working: latest REAL message decides.
                # Skip synthetic entries that don't represent the user waiting:
                #   - tool results (`toolUseResult` field, type:"user")
                #   - slash-command caveats (`"isMeta":true`, type:"user")
                #   - slash-command invocations (content has `<command-name>`, type:"user")
                # Without these skips, running e.g. `/effort` leaves the latest line as a
                # synthetic user entry with no following assistant `end_turn`, and the
                # detector stays stuck on "working".
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    $ln = $lines[$i]
                    if ($ln -match '"toolUseResult"') { continue }       # tool-result entry
                    if ($ln -match '"isMeta"\s*:\s*true') { continue }   # meta/caveat entry
                    if ($ln -match '<command-name>') { continue }        # slash-command invocation
                    if ($ln -match '"type"\s*:\s*"assistant"') {
                        $claudeIsIdle = ($ln -match '"stop_reason"\s*:\s*"end_turn"')
                        break
                    }
                    if ($ln -match '"type"\s*:\s*"user"') {
                        $claudeIsIdle = $false
                        break
                    }
                }
                # Cumulative tokens: sum each `usage` bucket separately across every assistant turn.
                #   in       = input_tokens                  (fresh, uncached new content)
                #   cache↑   = cache_creation_input_tokens   (tokens written to prompt cache)
                #   cache↓   = cache_read_input_tokens       (tokens read back from prompt cache)
                #   out      = output_tokens                 (model-generated output)
                foreach ($ln in $lines) {
                    if ($ln -notmatch '"type"\s*:\s*"assistant"') { continue }
                    $hasSessionTokens = $true
                    if ($ln -match '"input_tokens"\s*:\s*(\d+)')                { $sessionInTokens         += [long]$Matches[1] }
                    if ($ln -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $sessionCacheWriteTokens += [long]$Matches[1] }
                    if ($ln -match '"cache_read_input_tokens"\s*:\s*(\d+)')    { $sessionCacheReadTokens  += [long]$Matches[1] }
                    if ($ln -match '"output_tokens"\s*:\s*(\d+)')              { $sessionOutTokens        += [long]$Matches[1] }
                }
                # Decide workingStartOutTokens for this period:
                # - idle  → -1 (clear any previous start, reset on next working transition)
                # - working & previously had a start → preserve it (continuing the same working period)
                # - working & no previous start → record current sessionOutTokens as the baseline
                # Compute deltas from previous cached values
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
                        # Schema (13 fields): mtime | msgCount | claudeIsIdle | in | out | hasTokens | workingStart | cacheWrite | cacheRead | deltaIn | deltaOut | deltaCacheWrite | deltaCacheRead
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
# Tokens row — session cumulative, broken out by usage bucket so cost-relevant numbers
# stand out. Most volume on a long session is `cache↓` (cache reads, 10% list price);
# `in` is fresh input (full price), `cache↑` is writes to cache (1.25x list price),
# `out` is output (5x list price). Seeing them split lets you spot anomalies.
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
$tokensPart = ''
if ($hasSessionTokens) {
    $sep     = "  ${GRAY}$([char]0x00B7)${RESET}  "
    $tokensPart = (Format-Bucket "in" $sessionInTokens $deltaIn $CYAN $CYAN) `
        + $sep + (Format-Bucket "cache" $sessionCacheWriteTokens $deltaCacheWrite $GRAY $YELLOW "$([char]0x2191)") `
        + $sep + (Format-Bucket "cache" $sessionCacheReadTokens $deltaCacheRead $GRAY $CYAN "$([char]0x2193)") `
        + $sep + (Format-Bucket "out" $sessionOutTokens $deltaOut $MAGENTA $MAGENTA)
}
# Status (idle/working) — shown on model row
if ($claudeIsIdle) {
    $statusDot   = "${GREEN}$([char]0x25CF)${RESET}"   # ●
    $statusLabel = "${WHITE}ready${RESET}"
    $statusPart  = "${statusDot}  ${statusLabel}"
} else {
    $statusDot   = "${YELLOW}$([char]0x25CB)${RESET}"  # ○
    $statusLabel = "${YELLOW}working${RESET}"
    $statusPart  = "${statusDot}  ${statusLabel}"
    if ($workingStartOutTokens -ge 0 -and $sessionOutTokens -gt $workingStartOutTokens) {
        $delta = $sessionOutTokens - $workingStartOutTokens
        $deltaLabel = Format-Tokens $delta
        $statusPart += "  ${GRAY}$([char]0x00B7)${RESET}  ${CYAN}+${deltaLabel}${RESET} ${DIM}tokens${RESET}"
    }
}
# Message count — shown on cost row
$msgPart = ''
if ($null -ne $msgCount -and $msgCount -gt 0) {
    $msgLabel = if ($msgCount -eq 1) { 'message' } else { 'messages' }
    $msgPart = "${WHITE}${msgCount}${RESET} ${DIM}${msgLabel}${RESET}"
}
# ═══════════════════════════════════════════════════════════════════════════════
# 6. Rate limits (5h + 7d) — present only for Claude.ai subscribers.
# Shows usage + burn-rate vs. expected pace + time until reset:
#   "5h 15% ⇣5% (3h)" — 15% used, 5% UNDER the linear-pace expectation (good headroom), resets in 3h
#   "7d 60% ⇡8% (4d)" — 60% used, 8% AHEAD of pace (slow down), resets in 4d
# Burn arrow is hidden when within ±1% of expected pace (avoid jitter at session start).
# ═══════════════════════════════════════════════════════════════════════════════
function Format-Duration([int]$secs) {
    if ($secs -le 0) { return $null }
    # [int] in PowerShell uses banker's rounding which can overflow units (e.g. 2h59.98m → "3h60m").
    # Use Math::Floor explicitly, then subtract before computing the next unit so there's no
    # double-rounding between hour and minute (or day and hour) buckets.
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
            # Elapsed share of the window (0..1). Compare actual % vs. expected linear pace.
            $expectedPct = ($windowSecs - $remaining) * 100.0 / $windowSecs
            $delta = $pct - $expectedPct
            if ([Math]::Abs($delta) -ge 1) {
                $burnInt = [int][Math]::Round([Math]::Abs($delta))
                if ($delta -gt 0) {
                    # Over pace: burning hot, red, up-arrow
                    $burnPart = " ${RED}$([char]0x21E1)${burnInt}%${RESET}"
                } else {
                    # Under pace: headroom, green, down-arrow
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
    $part5 = Format-Window '5h' $fivePct $fiveRes 18000      # 5 * 3600
    $part7 = Format-Window '7d' $sevenPct $sevenRes 604800   # 7 * 86400
    if ($part5) { $parts5d += $part5 }
    if ($part7) { $parts5d += $part7 }
    $ratePart = $parts5d -join "  ${GRAY}$([char]0x00B7)${RESET}  "
}
# ═══════════════════════════════════════════════════════════════════════════════
# 7. Agent / subagent status (--agent startup mode only)
# ═══════════════════════════════════════════════════════════════════════════════
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
# ═══════════════════════════════════════════════════════════════════════════════
# Assemble — full box with labeled rows grouped into sections
# ═══════════════════════════════════════════════════════════════════════════════
# Box-drawing chars — heavy weight throughout the outer frame and section divider.
# Inter-row dividers within a section use the same heavy verticals but a heavy
# DASHED horizontal, giving a "medium" feel: visibly heavier than the light
# dashed alternative, but the dashing keeps it subordinate to the solid section
# break.
# Outer frame — heavy angular
$BoxTL  = [char]0x250F   # ┏  heavy top-left corner
$BoxTR  = [char]0x2513   # ┓  heavy top-right corner
$BoxBL  = [char]0x2517   # ┗  heavy bottom-left corner
$BoxBR  = [char]0x251B   # ┛  heavy bottom-right corner
$BoxH   = [char]0x2501   # ━  heavy horizontal
$BoxV   = [char]0x2503   # ┃  heavy vertical
# Section divider — heavy solid T-junctions
$BoxT_L  = [char]0x2523  # ┣
$BoxT_R  = [char]0x252B  # ┫
$BoxSecH = [char]0x2501  # ━  same heavy horizontal as outer border
# Inter-row divider — "floating" inside the box: the box verticals continue
# unbroken through divider rows, with a light solid horizontal inset by spaces
# so the line doesn't touch either edge.
$BoxRowH = [char]0x2500  # ─  light solid horizontal
# Visible-width helper (strip ANSI escapes)
$ansiPattern = "$ESC\[[0-9;]*[a-zA-Z]"
function Get-Vis([string]$s) {
    if (-not $s) { return 0 }
    return ($s -replace $ansiPattern, '').Length
}
$LABEL_W = 7  # width of label name column (longest is "context" = 7 chars)
# Row spec: each entry is { section, label, content }; rows with empty content are skipped.
# Compose merged rows. The separator matches the rest of the script's middle-dot style.
$rowSep = "  ${GRAY}$([char]0x00B7)${RESET}  "
# model · effort · status
$modelRow = $modelPart
if ($effortPart) { $modelRow = "${modelRow}${rowSep}${effortPart}" }
if ($statusPart) { $modelRow = "${modelRow}${rowSep}${statusPart}" }
# cost · messages · duration
$costRow = ''
$costParts = @()
if ($costPart)     { $costParts += $costPart }
if ($msgPart)      { $costParts += $msgPart }
if ($durationPart) { $costParts += $durationPart }
$costRow = $costParts -join $rowSep
# Merge path + git into one row
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
    @{ s=1; label='tokens'; content=$tokensPart     }
    @{ s=1; label='cost'; content=$costRow          }
    @{ s=1; label='limits'; content=$ratePart       }
)
# Materialize each row's inner text and remember its section
# Format: " <label_padded> : <content> "  — colons line up in a fixed column
$rows = @()
foreach ($spec in $rowSpec) {
    if (-not $spec.content) { continue }
    $lbl = $spec.label.PadRight($LABEL_W)
    # Use a light vertical instead of ":" so the separators stack into a continuous
    # thin column running down the box (visually floating, since they only appear
    # on content rows — divider rows don't have one).
    $inner = " ${DIM}${lbl}${RESET} ${GRAY}$([char]0x2502)${RESET}  $($spec.content) "
    $rows += @{ s = $spec.s; inner = $inner }
}
# Box inner width = max visible width across rows (clamped to a sensible minimum)
$maxInner = 30
foreach ($r in $rows) {
    $vl = Get-Vis $r.inner
    if ($vl -gt $maxInner) { $maxInner = $vl }
}
# Build horizontal rules sized to inner width
$heavyHoriz = [string]$BoxH * $maxInner             # ━━━━━ heavy (outer + section divider)
$topRule    = "${GRAY}${BoxTL}${heavyHoriz}${BoxTR}${RESET}"
$secDivRule = "${GRAY}${BoxT_L}${heavyHoriz}${BoxT_R}${RESET}"
$botRule    = "${GRAY}${BoxBL}${heavyHoriz}${BoxBR}${RESET}"
# Inter-row divider — horizontal rule across BOTH the label column AND the
# content column, with a ┼ junction where it crosses the inner │ separator
# (so the inner vertical reads as continuous through divider rows). Still
# "floating": 1-space lead/trail keeps the rule from touching the box edges.
#   Layout: " ─────── ┼ ─────────────────── "
#           1 + (LABEL_W+1) dashes + ┼ + (maxInner - LABEL_W - 4) dashes + 1
$leftDashCount  = $LABEL_W + 1
$rightDashCount = $maxInner - $LABEL_W - 4
if ($rightDashCount -lt 1) { $rightDashCount = 1 }
$leftDashes  = [string]$BoxRowH * $leftDashCount
$rightDashes = [string]$BoxRowH * $rightDashCount
$crossChar   = [char]0x253C  # ┼ — light cross, joins horizontal rule with inner │
$rowDivRule  = "${GRAY}${BoxV}${RESET} ${GRAY}${leftDashes}${RESET}${GRAY}${crossChar}${RESET}${GRAY}${rightDashes}${RESET} ${GRAY}${BoxV}${RESET}"
# Emit lines: top border, then rows with appropriate dividers:
#   - heavy section divider when moving to a new section
#   - light dashed inter-row divider between rows within the same section
# Then bottom border.
$output = @($topRule)
$prevSec = -1
$first = $true
foreach ($r in $rows) {
    if (-not $first) {
        if ($r.s -ne $prevSec) {
            $output += $secDivRule   # heavy: section boundary
        } else {
            $output += $rowDivRule   # light dashed: between rows in same section
        }
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