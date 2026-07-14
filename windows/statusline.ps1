#Requires -Version 5.1
# Claude Code statusLine for Windows PowerShell.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# @parity:constant CACHE_VERSION=1
$CacheVersion = "1"

# @parity:colors-begin
$ESC  = [char]27
function Ansi($code) { "$ESC[$($code)m" }
$RESET   = Ansi 0
$DIM     = Ansi 2
$BOLD    = Ansi 1
$CYAN    = Ansi 36
$MAGENTA = Ansi 35
$YELLOW  = Ansi 33
$GREEN   = Ansi 32
$RED     = Ansi 31
$BLUE    = Ansi 34
$WHITE   = Ansi 37
$GRAY    = Ansi 90
$BAR_EMPTY = Ansi '38;5;242'
# @parity:colors-end
# --- Read stdin + debug log ---
# Always exit 0 — any non-zero exit makes Claude Code hide the status line entirely.
$logPath = "$env:USERPROFILE\.claude\statusline-debug.log"
function Write-Log([string]$msg) {
    if (-not $env:STATUSLINE_DEBUG) { return }
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
    $_dbgHint = if ($env:STATUSLINE_DEBUG) { "see statusline-debug.log" } else { "set STATUSLINE_DEBUG=1 for details" }
    [Console]::Write("${RED}[statusline: error - $_dbgHint]${RESET}")
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
function Format-Tokens($n) {  # 1234567 -> "1.2M"; "0" for empty
    if ($null -eq $n) { return $null }
    $v = [double]$n
    if ($v -ge 1000000) {
        $w = [int][Math]::Truncate($v / 1000000)
        $f = [int][Math]::Truncate(($v % 1000000) / 100000)
        return "$w.${f}M"
    }
    if ($v -ge 1000) {
        $w = [int][Math]::Truncate($v / 1000)
        $f = [int][Math]::Truncate(($v % 1000) / 100)
        return "$w.${f}K"
    }
    return "$([int]$v)"
}

function Get-NormalizedModelId([string]$id) {  # strip trailing -YYYYMMDD date suffix
    if (-not $id) { return '' }
    return ($id -replace '-\d{8}$', '')
}

function Get-PrettyModelName([string]$id) {  # claude-sonnet-5 -> "Sonnet 5"; unknown -> cleaned id
    $clean = (Get-NormalizedModelId $id) -replace '^claude-', ''
    if ($clean -match '^(fable|opus|sonnet|haiku)-(\d+(?:-\d+)*)') {
        $fam = $Matches[1]
        $ver = $Matches[2] -replace '-', '.'
        return ($fam.Substring(0,1).ToUpper() + $fam.Substring(1) + ' ' + $ver)
    }
    return $clean
}

# @parity:seed-table-begin
# Known model->window seeds; keys are normalized ids (date suffix stripped,
# claude- prefix tolerated). Unlisted ids fall through to the resolver tiers.
$ModelWindowSeeds = @{
    'fable-5'    = 1000000
    'opus-4-8'   = 1000000
    'opus-4-7'   = 1000000
    'opus-4-6'   = 1000000
    'sonnet-5'   = 1000000
    'sonnet-4-6' = 1000000
    'haiku-4-5'  = 200000
    'sonnet-4-5' = 200000
    'opus-4-5'   = 200000
}
# @parity:seed-table-end

function Get-SubagentCtxSize([string]$model) {  # tiered: learned map -> seed table -> 1m marker -> 200K default
    $norm = Get-NormalizedModelId $model
    if ($ModelWindowsMap) {
        $prop = $ModelWindowsMap.PSObject.Properties[$norm]
        if ($prop) {
            $learned = 0L
            if ([long]::TryParse("$($prop.Value)", [ref]$learned) -and $learned -gt 0) {
                Write-Log "sa ctx: $norm -> $learned (learned)"
                return $learned
            }
        }
    }
    $seedKey = $norm -replace '^claude-', ''
    if ($ModelWindowSeeds.ContainsKey($seedKey)) {
        Write-Log "sa ctx: $norm -> $($ModelWindowSeeds[$seedKey]) (seed)"
        return $ModelWindowSeeds[$seedKey]
    }
    if ($norm -match '\[1m\]' -or $norm -match '-1m') {
        Write-Log "sa ctx: $norm -> 1000000 (marker)"
        return 1000000
    }
    Write-Log "sa ctx: $norm -> 200000 (default)"
    return 200000
}

function Get-PctColor([int]$pct) {  # context percentage -> threshold color
    # @parity:threshold CONTEXT_CRIT=85
    # @parity:threshold CONTEXT_WARN=60
    if ($pct -ge 85) { return $RED } elseif ($pct -ge 60) { return $YELLOW } else { return $GREEN }
}

function Build-Bar([int]$pct, [string]$color) {  # filled/empty bar over barWidth cells
    if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }
    $filled = [int][Math]::Truncate(($barWidth * $pct + 50) / 100)
    if ($filled -lt 0) { $filled = 0 } elseif ($filled -gt $barWidth) { $filled = $barWidth }
    $empty = $barWidth - $filled
    $filledChars = if ($filled -gt 0) { [string]([char]0x2588) * $filled } else { '' }
    $emptyChars  = if ($empty -gt 0)  { [string]([char]0x2591) * $empty }  else { '' }
    return "${color}${filledChars}${RESET}${BAR_EMPTY}${emptyChars}${RESET}"
}

# @parity:json-extract-begin
$sessionId        = Get-Val $json @('session_id')
$cwdRaw           = Get-Val $json @('workspace','current_dir')
$cwdFallback      = Get-Val $json @('cwd')
$modelDisplay     = Get-Val $json @('model','display_name')
$ctxSize          = Get-Val $json @('context_window','context_window_size')
$usedPct          = Get-Val $json @('context_window','used_percentage')
$totalInputTokens = Get-Val $json @('context_window','total_input_tokens')
$effortLevel      = Get-Val $json @('effort','level')
$gitCwd           = Get-Val $json @('workspace','current_dir')
$totalCost        = Get-Val $json @('cost','total_cost_usd')
$totalCostLegacy  = Get-Val $json @('total_cost_usd')
$durationMs       = Get-Val $json @('cost','total_duration_ms')
$durationMsL1     = Get-Val $json @('total_duration_ms')
$durationMsL2     = Get-Val $json @('duration_ms')
$transcriptPath   = Get-Val $json @('transcript_path')
$fivePct          = Get-Val $json @('rate_limits','five_hour','used_percentage')
$fiveRes          = Get-Val $json @('rate_limits','five_hour','resets_at')
$sevenPct         = Get-Val $json @('rate_limits','seven_day','used_percentage')
$sevenRes         = Get-Val $json @('rate_limits','seven_day','resets_at')
$agentName        = Get-Val $json @('agent','name')
$agentIn          = Get-Val $json @('context_window','current_usage','input_tokens') 0
$agentOut         = Get-Val $json @('context_window','current_usage','output_tokens') 0
$modelId          = Get-Val $json @('model','id')
# @parity:json-extract-end

# --- Output cache: skip re-render when all inputs are unchanged ---
$_ocSafeId = if ($sessionId) { $sessionId -replace '[^a-zA-Z0-9_-]', '' } else { $null }
$_ocPath = if ($_ocSafeId) { Join-Path $env:TEMP "statusline-oc-$_ocSafeId.txt" } else { $null }
$_ocTmt = ''
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath -ErrorAction SilentlyContinue)) {
    $_ocTmt = (Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc.Ticks
}
$_ocGmt = ''
$_ocGitCwd = if ($gitCwd) { $gitCwd } else { (Get-Location).Path }
$_ocGidx = Join-Path $_ocGitCwd '.git\index'
if (Test-Path -LiteralPath $_ocGidx -ErrorAction SilentlyContinue) {
    $_ocGmt = (Get-Item -LiteralPath $_ocGidx -Force).LastWriteTimeUtc.Ticks
}
$_ocSmt = ''
if ($transcriptPath) {
    $_ocSdir = Join-Path (Split-Path -Parent $transcriptPath) (Join-Path ([System.IO.Path]::GetFileNameWithoutExtension($transcriptPath)) 'subagents')
    if (Test-Path -LiteralPath $_ocSdir -ErrorAction SilentlyContinue) {
        $_ocSmt = (Get-Item -LiteralPath $_ocSdir -Force).LastWriteTimeUtc.Ticks
    }
}
# Feed content+freshness and the learned-map mtime join the key so subagent
# tier switches and learned window changes invalidate the render cache. The
# handler rewrites the feed file every tick, so keying on its mtime would
# defeat the output cache; mtime feeds only the freshness flag.
$_ocFeed = if ($_ocSafeId) { Join-Path $env:TEMP "statusline-tasks-$_ocSafeId.json" } else { $null }
# @parity:cache FEED_TTL=10
$FEED_TTL = 10
$_ocFfresh = 0
$_ocFjson = ''
if ($_ocFeed -and (Test-Path -LiteralPath $_ocFeed -ErrorAction SilentlyContinue)) {
    try {
        $_ocFeedAge = ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item -LiteralPath $_ocFeed -Force).LastWriteTimeUtc).TotalSeconds
        if ($_ocFeedAge -le $FEED_TTL) {
            $_ocFfresh = 1
            $_ocFjson = [System.IO.File]::ReadAllText($_ocFeed)
        }
    } catch {}
}
$_ocMwPath = "$env:USERPROFILE\.claude\statusline-model-windows.json"
$_ocMwmt = ''
if (Test-Path -LiteralPath $_ocMwPath -ErrorAction SilentlyContinue) {
    $_ocMwmt = (Get-Item -LiteralPath $_ocMwPath -Force).LastWriteTimeUtc.Ticks
}
# @parity:cache OUTPUT_BUCKET=5
$_ocNowBucket = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 5)
$_ocKeyInput = "${raw}|${_ocTmt}|${_ocGmt}|${_ocSmt}|${_ocFfresh}|${_ocFjson}|${_ocMwmt}|${_ocNowBucket}"
$_ocKey = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($_ocKeyInput))).Replace('-','')

if ($_ocPath -and (Test-Path -LiteralPath $_ocPath -ErrorAction SilentlyContinue)) {
    try {
        $ocLines = [System.IO.File]::ReadAllLines($_ocPath)
        if ($ocLines.Count -ge 2 -and $ocLines[0] -eq $_ocKey) {
            Write-Log "output cache HIT"
            $cachedOutput = ($ocLines | Select-Object -Skip 1) -join "`n"
            Write-Host $cachedOutput -NoNewline
            exit 0
        }
    } catch {
        Write-Log ("output cache read failed, re-rendering: " + $_.Exception.Message)
    }
}

# --- 1. CWD ---
$cwd = $cwdRaw
if (-not $cwd) { $cwd = $cwdFallback }
if (-not $cwd) { $cwd = (Get-Location).Path }
$userHome = $env:USERPROFILE
if ($cwd -and $userHome -and ($cwd -eq $userHome -or $cwd.StartsWith("$userHome\", [System.StringComparison]::OrdinalIgnoreCase) -or $cwd.StartsWith("$userHome/", [System.StringComparison]::OrdinalIgnoreCase))) {
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
# Strip "Claude " prefix; cap at 24 chars so "Opus 4.7 (1M context)" still fits.
$modelShort = $modelDisplay
if ($modelShort) {
    $modelShort = $modelShort -replace '^Claude\s+',''
    if ($modelShort.Length -gt 24) { $modelShort = $modelShort.Substring(0,24) }
} else {
    $modelShort = 'unknown'
}
$ctxLabel = ''
if ($ctxSize) {
    $ctxK = [int]($ctxSize / 1000)
    $ctxLabel = if ($ctxK -ge 1000) { "$([int]($ctxK/1000))M" } else { "${ctxK}K" }
}
$pctInt   = $null
$pctColor = $WHITE
if ($null -ne $usedPct) {
    $pctInt   = [int][Math]::Round($usedPct)
    $pctColor = Get-PctColor $pctInt
}
$modelPart = "${MAGENTA}${modelShort}${RESET}"
# --- 2b. Context bar ---
# Always rendered. Missing usedPct -> 0%; missing ctxSize -> bar without tokens label.
$barWidth   = 30
$rawPct     = if ($null -ne $usedPct) { [double]$usedPct } else { 0 }
$pctClamped = [Math]::Max(0.0, [Math]::Min(100.0, $rawPct))
$barPctInt  = if ($null -ne $pctInt)  { $pctInt }   else { 0 }
$barColor   = if ($null -ne $pctInt)  { $pctColor } else { $GREEN }
$barPctTrunc = [int][Math]::Truncate($pctClamped)
$bar = Build-Bar $barPctTrunc $barColor
$tokenSuffix = ''
if ($ctxSize) {
    # Prefer total_input_tokens (full precision); used_percentage is integer-rounded, so on a
    # 1M window "25%" maps to exactly 250000 and the display jumps in 10K steps.
    $usedTokens = if ($null -ne $totalInputTokens) { [long]$totalInputTokens } else { [long][Math]::Truncate([double]$ctxSize * $barPctTrunc / 100) }
    $usedLbl = Format-Tokens $usedTokens
    if (-not $usedLbl) { $usedLbl = '0' }
    $tokenSuffix = " ${GRAY}$([char]0x00B7)${RESET} ${WHITE}${usedLbl}${RESET}${GRAY}/${ctxLabel}${RESET}"
}
$ctxBarPart = "${bar} ${barColor}${barPctInt}%${RESET}${tokenSuffix}"
# --- 2c. Learned model->window map ---
# Persist the main session's model->window pair so subagent rows can resolve
# real denominators later. Multi-writer file: atomic temp+Move-Item, skip when
# the entry already matches (no mtime churn). All failures are silent.
$ModelWindowsMap = $null
if (Test-Path -LiteralPath $_ocMwPath -ErrorAction SilentlyContinue) {
    try {
        $mwParsed = Get-Content -LiteralPath $_ocMwPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($mwParsed -is [PSCustomObject]) { $ModelWindowsMap = $mwParsed }
    } catch { Write-Log ("model-windows read failed: " + $_.Exception.Message) }
}
$mwWin = 0L
if ($modelId -and $null -ne $ctxSize -and [long]::TryParse("$ctxSize", [ref]$mwWin) -and $mwWin -gt 0) {
    $mwTmp = $null
    try {
        $mwKey = Get-NormalizedModelId $modelId
        $mwCur = $null
        if ($ModelWindowsMap) {
            $mwProp = $ModelWindowsMap.PSObject.Properties[$mwKey]
            if ($mwProp) {
                $mwCurParsed = 0L
                if ([long]::TryParse("$($mwProp.Value)", [ref]$mwCurParsed)) { $mwCur = $mwCurParsed }
            }
        }
        if ($mwKey -and $mwCur -ne $mwWin) {
            if (-not $ModelWindowsMap) { $ModelWindowsMap = New-Object PSObject }
            $ModelWindowsMap | Add-Member -NotePropertyName $mwKey -NotePropertyValue $mwWin -Force
            $mwDir = Split-Path -Parent $_ocMwPath
            if (-not (Test-Path -LiteralPath $mwDir)) { New-Item -ItemType Directory -Path $mwDir -Force -ErrorAction Stop | Out-Null }
            $mwTmp = Join-Path $mwDir ('statusline-model-windows.json.' + [System.IO.Path]::GetRandomFileName())
            [System.IO.File]::WriteAllText($mwTmp, ($ModelWindowsMap | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
            Move-Item -LiteralPath $mwTmp -Destination $_ocMwPath -Force
            $mwTmp = $null
            Write-Log "model-windows: learned $mwKey=$mwWin"
        }
    } catch {
        Write-Log ("model-windows write failed: " + $_.Exception.Message)
        if ($mwTmp) { try { Remove-Item -LiteralPath $mwTmp -Force -ErrorAction SilentlyContinue } catch {} }
    }
}
# --- 3. Reasoning effort ---
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
$gitPart = ''
try {
    if (-not $gitCwd) { $gitCwd = (Get-Location).Path }
    $gitIndex = Join-Path $gitCwd '.git\index'
    if (Test-Path -LiteralPath $gitIndex) {
        $gitIndexMt = (Get-Item -LiteralPath $gitIndex -Force).LastWriteTimeUtc.Ticks
        $safeSessionId = if ($sessionId) { $sessionId -replace '[^a-zA-Z0-9_-]', '' } else { $null }
        $gitCachePath = if ($safeSessionId) { Join-Path $env:TEMP "statusline-git-$safeSessionId.txt" } else { $null }
        $gitUseCache = $false
        $branch = $null; $insertions = 0; $deletions = 0; $untracked = 0; $ahead = 0; $behind = 0; $stash = 0

        if ($gitCachePath -and (Test-Path -LiteralPath $gitCachePath)) {
            $gc = (Get-Content -LiteralPath $gitCachePath -Raw -ErrorAction SilentlyContinue) -split ([char]0x1F)
            if ($gc.Count -ge 5 -and $gc[0] -eq "$gitIndexMt") {
                $cacheAge = ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item -LiteralPath $gitCachePath -Force).LastWriteTimeUtc).TotalSeconds
                # @parity:cache GIT_TTL=5
                if ($cacheAge -lt 5) {
                    $branch = $gc[1]; $insertions = [int]$gc[2]; $deletions = [int]$gc[3]; $untracked = [int]$gc[4]
                    $ahead  = if ($gc.Count -ge 8) { [int]$gc[5] } else { 0 }
                    $behind = if ($gc.Count -ge 8) { [int]$gc[6] } else { 0 }
                    $stash  = if ($gc.Count -ge 8) { [int]$gc[7] } else { 0 }
                    $gitUseCache = $true
                }
            }
        }

        if (-not $gitUseCache) {
            $branch = $null
            $isWorkTree = & git --no-optional-locks -C $gitCwd rev-parse --is-inside-work-tree 2>$null
            if ($isWorkTree -eq 'true') {
                $branch = & git --no-optional-locks -C $gitCwd rev-parse --abbrev-ref HEAD 2>$null
                if ($branch -eq 'HEAD') {
                    $short = & git --no-optional-locks -C $gitCwd rev-parse --short HEAD 2>$null
                    if ($short) { $branch = $short }
                }
            }
            if ($branch) {
                $diffStat = & git --no-optional-locks -C $gitCwd diff --shortstat HEAD 2>$null
                $insertions = 0; $deletions = 0
                if ($diffStat -and $diffStat.Trim() -ne '') {
                    if ($diffStat -match '(\d+) insertion') { $insertions = [int]$Matches[1] }
                    if ($diffStat -match '(\d+) deletion')  { $deletions  = [int]$Matches[1] }
                }
                $porcelain = & git --no-optional-locks -C $gitCwd status --porcelain 2>$null
                $untracked = @($porcelain | Where-Object { $_ -match '^\?\?' }).Count
                $abRaw = & git --no-optional-locks -C $gitCwd rev-list --left-right --count "HEAD...@{upstream}" 2>$null
                if ($abRaw -and $abRaw.Trim() -ne '') {
                    $abParts = $abRaw.Trim() -split '\s+'
                    if ($abParts.Count -ge 2) { $ahead = [int]$abParts[0]; $behind = [int]$abParts[1] }
                }
                $stash = @(& git --no-optional-locks -C $gitCwd stash list 2>$null).Count
            } else { $branch = $null }
            if ($gitCachePath) { try { $d = [char]0x1F; [System.IO.File]::WriteAllText($gitCachePath, "$gitIndexMt$d$branch$d$insertions$d$deletions$d$untracked$d$ahead$d$behind$d$stash", (New-Object System.Text.UTF8Encoding $false)) } catch {} }
        }

        if ($branch) {
            $isDirty = ($insertions -gt 0 -or $deletions -gt 0 -or $untracked -gt 0)
            $branchColor = if ($isDirty) { $YELLOW } else { $GREEN }
            $gitPart = "${branchColor}${branch}${RESET}"
            $statParts = @()
            if ($ahead      -gt 0) { $statParts += "${CYAN}$([char]0x2191)${ahead}${RESET}" }
            if ($behind     -gt 0) { $statParts += "${MAGENTA}$([char]0x2193)${behind}${RESET}" }
            if ($insertions -gt 0) { $statParts += "${GREEN}+${insertions}${RESET}" }
            if ($deletions  -gt 0) { $statParts += "${RED}-${deletions}${RESET}" }
            if ($untracked  -gt 0) { $statParts += "${GRAY}~${untracked}${RESET}" }
            if ($stash      -gt 0) { $statParts += "${DIM}$([char]0x229F)${stash}${RESET}" }
            if ($statParts.Count -gt 0) { $gitPart += ' ' + ($statParts -join ' ') }
        }
    }
} catch { $gitPart = '' }
# --- 5. Cost + Duration ---
# Fallbacks to legacy top-level keys — Claude Code JSON schema has shifted between versions.
$costPart = ''
$durationPart = ''
if ($null -eq $totalCost) { $totalCost = $totalCostLegacy }
if ($null -ne $totalCost) {
    $costFmt  = '${0:F4}' -f [double]$totalCost
    # @parity:threshold COST_WARN=0.50
    $costColor = if ([double]$totalCost -gt 0.50) { $YELLOW } else { $GREEN }
    $costPart = "${costColor}${costFmt}${RESET}"
}
if ($null -eq $durationMs) { $durationMs = $durationMsL1 }
if ($null -eq $durationMs) { $durationMs = $durationMsL2 }
if ($null -ne $durationMs) {
    $secs = [int][Math]::Floor([double]$durationMs / 1000)
    $dStr = if ($secs -ge 3600) {
        '{0}h{1:D2}m' -f [int][Math]::Floor($secs / 3600.0), [int][Math]::Floor(($secs % 3600) / 60.0)
    } elseif ($secs -ge 60) {
        '{0}m{1:D2}s' -f [int][Math]::Floor($secs / 60.0), ($secs % 60)
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
$workingStartOutTokens = [long](-1)
$deltaIn         = [long]0
$deltaCacheWrite = [long]0
$deltaCacheRead  = [long]0
$deltaOut        = [long]0
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath -ErrorAction SilentlyContinue)) {
    try {
        # Per-session cache keyed on transcript mtime — only re-parse when it changes.
        $cachePath    = if ($_ocSafeId) { Join-Path $env:TEMP ("statusline-cache-" + $_ocSafeId + ".txt") } else { $null }
        $transcriptMt = (Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc.Ticks
        $transcriptSz = (Get-Item -LiteralPath $transcriptPath).Length
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
                if ($parts[0] -eq $CacheVersion -and $parts.Length -ge 8) {
                    $prevWorkingStart = [long]$parts[7]
                }
                if ($parts[0] -eq $CacheVersion -and $parts.Length -ge 10) {
                    $prevIn         = [long]$parts[5]
                    $prevOut        = [long]$parts[6]
                    $prevCacheWrite = [long]$parts[8]
                    $prevCacheRead  = [long]$parts[9]
                }
                if (($parts.Length -ge 14) -and $parts[0] -eq $CacheVersion -and $parts[1] -eq "$transcriptMt" -and $parts[2] -eq "$transcriptSz") {
                    $msgCount                = [int]$parts[3]
                    $claudeIsIdle            = [bool]::Parse($parts[4])
                    $sessionInTokens         = [long]$parts[5]
                    $sessionOutTokens        = [long]$parts[6]
                    $workingStartOutTokens   = $prevWorkingStart
                    $sessionCacheWriteTokens = [long]$parts[8]
                    $sessionCacheReadTokens  = [long]$parts[9]
                    $deltaIn                 = [long]$parts[10]
                    $deltaOut                = [long]$parts[11]
                    $deltaCacheWrite         = [long]$parts[12]
                    $deltaCacheRead          = [long]$parts[13]
                    $useCache = $true
                }
            }
        }
        if (-not $useCache) {
            if ($transcriptSz -gt 0) {
                # Single streaming pass (parity with the one-pass awk on macOS/Linux):
                # counts real user messages, sums token buckets, and tracks the LAST
                # non-synthetic user/assistant line for the idle-vs-working verdict --
                # without materializing the whole transcript in memory.
                $msgCount = 0
                foreach ($ln in [System.IO.File]::ReadLines($transcriptPath)) {
                    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                    if ($ln -match '"type"\s*:\s*"assistant"') {
                        # Cumulative tokens by usage bucket across every assistant turn.
                        if ($ln -match '"input_tokens"\s*:\s*(\d+)')                { $sessionInTokens         += [long]$Matches[1] }
                        if ($ln -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $sessionCacheWriteTokens += [long]$Matches[1] }
                        if ($ln -match '"cache_read_input_tokens"\s*:\s*(\d+)')    { $sessionCacheReadTokens  += [long]$Matches[1] }
                        if ($ln -match '"output_tokens"\s*:\s*(\d+)')              { $sessionOutTokens        += [long]$Matches[1] }
                        # Idle vs working: latest REAL entry decides; synthetic lines don't vote.
                        if ($ln -notmatch '"isMeta"\s*:\s*true' -and $ln -notmatch '<command-name>' -and
                            $ln -notmatch '<local-command-' -and $ln -notmatch '"toolUseResult"') {
                            $claudeIsIdle = ($ln -match '"stop_reason"\s*:\s*"end_turn"')
                        }
                    } elseif ($ln -match '"type"\s*:\s*"user"') {
                        # Real user messages = user-type lines that are NOT synthetic. Filter with
                        # AND per-line; summing independent counters over-subtracts when markers
                        # like `<command-name>` co-occur with `"toolUseResult"` on the same line.
                        if ($ln -notmatch '"toolUseResult"' -and $ln -notmatch '"isMeta"\s*:\s*true' -and
                            $ln -notmatch '<command-name>' -and $ln -notmatch '<local-command-stdout>') {
                            $msgCount++
                        }
                        if ($ln -notmatch '"isMeta"\s*:\s*true' -and $ln -notmatch '<command-name>' -and
                            $ln -notmatch '<local-command-' -and $ln -notmatch '"toolUseResult"') {
                            $claudeIsIdle = if ($ln -match 'Request interrupted by user') { $true } else { $false }
                        }
                    }
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
                        [System.IO.File]::WriteAllText(
                            $cachePath,
                            ("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}" -f $CacheVersion, $transcriptMt, $transcriptSz, $msgCount, $claudeIsIdle, $sessionInTokens, $sessionOutTokens, $workingStartOutTokens, $sessionCacheWriteTokens, $sessionCacheReadTokens, $deltaIn, $deltaOut, $deltaCacheWrite, $deltaCacheRead),
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
    # TryParse guards mirror the bash regex checks: a non-numeric value from
    # JSON schema drift must skip the fragment, not throw into the trap.
    $pctD = 0.0
    if (-not [double]::TryParse("$pctVal", [ref]$pctD)) { return $null }
    $pct = [int][Math]::Round($pctD)
    $pctColor = if ($pct -ge 80) { $RED } elseif ($pct -ge 50) { $YELLOW } else { $GREEN }
    $burnPart = ''
    $resetPart = ''
    $resetsD = 0.0
    if ($null -ne $resetsAt -and [double]::TryParse("$resetsAt", [ref]$resetsD)) {
        $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remaining = [long][Math]::Truncate($resetsD) - $now
        if ($remaining -gt 0 -and $remaining -le $windowSecs) {
            # Compare actual pct against linear-pace expectation; +delta = over pace, -delta = under.
            $expectedPct = [int][Math]::Truncate(($windowSecs - $remaining) * 100 / $windowSecs)
            $delta = $pct - $expectedPct
            if ([Math]::Abs($delta) -ge 1) {
                $burnInt = [int][Math]::Truncate([Math]::Abs($delta))
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
if ($agentName) {
    $agentPart = "${BLUE}${BOLD}${agentName}${RESET}"
    $agentCompact = ''
    $sep = "  ${GRAY}$([char]0x00B7)${RESET}  "
    if ($null -ne $pctInt) {
        $agentCompact = "${pctColor}${pctInt}%${RESET}${sep}"
    }
    $inFmt  = Format-Tokens $agentIn
    $outFmt = Format-Tokens $agentOut
    if (-not $inFmt)  { $inFmt  = '0' }
    if (-not $outFmt) { $outFmt = '0' }
    $agentCompact += "${DIM}in${RESET} ${WHITE}${inFmt}${RESET}  ${DIM}out${RESET} ${WHITE}${outFmt}${RESET}"
    $agentPart += "${sep}${agentCompact}"
}
# --- 7b. Subagent context ---
# One row per Task-tool subagent. Rows come from ONE tier per refresh: the
# tasks-feed state file when fresh (age within FEED_TTL), else per-agent
# transcript parsing. Tiers are never merged. A done signal (feed: non-active
# status or task gone; fallback: terminal stop_reason) stamps done_ts into the
# per-agent session cache; the row lingers green for DONE_LINGER seconds.
# FEED_TTL is defined with the output-cache key inputs above.
# @parity:threshold DONE_LINGER=30
$DONE_LINGER = 30
# Feed statuses that mean "done" — single place to adjust.
# Deny-list polarity: an unknown status means "working" (fail open to visible),
# matching the fallback tier's terminal-stop-reason check; a completed task
# that leaves the feed is still caught by the disappeared-task done signal.
$SaTerminalStatuses = @('completed', 'complete', 'done', 'finished', 'failed', 'cancelled', 'canceled', 'killed', 'stopped', 'error')
# Transcript stop reasons that mean "done" — single place to adjust.
$SaTerminalStopReasons = @('end_turn', 'max_tokens', 'refusal', 'model_context_window_exceeded', 'stop_sequence')

function Build-SubagentRow($used, $ctxSize, $model, $type, $state) {
    $u = 0L
    if (-not [long]::TryParse("$used", [ref]$u) -or $u -lt 0) { $u = 0L }
    $w = 0L
    if (-not [long]::TryParse("$ctxSize", [ref]$w) -or $w -le 0) { $w = 200000L }
    # Bar/pct clamp at 100%; the token label keeps the raw used value.
    $saPctInt = [int][Math]::Truncate(($u * 100.0) / $w)
    if ($saPctInt -lt 0) { $saPctInt = 0 }
    if ($saPctInt -gt 100) { $saPctInt = 100 }
    $saColor = Get-PctColor $saPctInt
    $saBar = Build-Bar $saPctInt $saColor
    $saUsedLbl = Format-Tokens $u
    if (-not $saUsedLbl) { $saUsedLbl = '0' }
    $saCtxK = [math]::Floor($w / 1000)
    $saCtxLbl = if ($saCtxK -ge 1000) { "$([math]::Floor($saCtxK / 1000))M" } else { "${saCtxK}K" }
    # Compact single-space separators — same segment style as the context bar.
    $saSep = " ${GRAY}$([char]0x00B7)${RESET} "
    $row = "${saBar} ${saColor}${saPctInt}%${RESET}${saSep}${WHITE}${saUsedLbl}${RESET}${GRAY}/${saCtxLbl}${RESET}"
    if ($model) { $row += "${saSep}${MAGENTA}$(Get-PrettyModelName $model)${RESET}" }
    if ($type)  { $row += "${saSep}${BLUE}${type}${RESET}" }
    if ($state -eq 'done') { $row += "${saSep}${GREEN}$([char]0x2713) done${RESET}" }
    else                   { $row += "${saSep}${YELLOW}$([char]0x25CB) working${RESET}" }
    return $row
}

$subagentRows = @()
$saNow = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$feedTier = $false
if ($_ocFfresh -eq 1 -and $_ocFjson) {
    # Parse the same content the output-cache key hashed, so the render always
    # matches its key even if the handler rewrote the file mid-refresh.
    try {
        $feedJson = $_ocFjson | ConvertFrom-Json -ErrorAction Stop
        if ($feedJson -is [PSCustomObject] -and ($null -eq $feedJson.tasks -or $feedJson.tasks -is [array])) {
            $feedTier = $true
            $feedTasks = if ($null -ne $feedJson.tasks) { @($feedJson.tasks) } else { @() }
            $feedSeen = @{}
            $feedCandidates = @()
            foreach ($t in $feedTasks) {
                if ($null -eq $t -or $t -isnot [PSCustomObject]) { continue }
                $ftId     = if ($null -ne $t.id) { "$($t.id)" } else { '' }
                $ftType   = if ($t.type) { "$($t.type)" } elseif ($t.name) { "$($t.name)" } else { '' }
                $ftStatus = if ($null -ne $t.status) { "$($t.status)" } else { '' }
                $ftModel  = if ($null -ne $t.model) { "$($t.model)" } else { '' }
                $ftStart  = if ($null -ne $t.startTime) { "$($t.startTime)" } else { '' }
                if (-not ($ftId -or $ftType -or $ftStatus -or $ftModel)) { continue }
                $ftIdSafe = $ftId -replace '[^a-zA-Z0-9_-]', ''
                if ($ftIdSafe) { $feedSeen[$ftIdSafe] = $true }
                $ftTok = 0L
                if (-not [long]::TryParse("$($t.tokenCount)", [ref]$ftTok) -or $ftTok -lt 0) { $ftTok = 0L }
                # Task window when present, else the tiered resolver (absent model -> 200K).
                $ftCtx = 0L
                if (-not [long]::TryParse("$($t.contextWindowSize)", [ref]$ftCtx) -or $ftCtx -le 0) {
                    $ftCtx = Get-SubagentCtxSize $ftModel
                }
                $ftCache = if ($ftIdSafe) { Join-Path $env:TEMP "statusline-sa-$_ocSafeId-task-$ftIdSafe.txt" } else { $null }
                $ftDone = ''
                if ($SaTerminalStatuses -notcontains $ftStatus.ToLowerInvariant()) {
                    $ftState = 'working'
                } else {
                    $ftState = 'done'
                    if ($ftCache -and (Test-Path -LiteralPath $ftCache -ErrorAction SilentlyContinue)) {
                        $fcRaw = Get-Content -LiteralPath $ftCache -Raw -ErrorAction SilentlyContinue
                        if ($fcRaw) {
                            $fcParts = $fcRaw.TrimEnd() -split '\|'
                            $fcPrev = 0L
                            if ($fcParts.Count -ge 5 -and [long]::TryParse($fcParts[4], [ref]$fcPrev) -and $fcPrev -gt 0) { $ftDone = "$fcPrev" }
                        }
                    }
                    if (-not $ftDone) { $ftDone = "$saNow" }
                }
                if ($ftCache) {
                    try { [System.IO.File]::WriteAllText($ftCache, "$ftTok|$ftCtx|$ftModel|$ftType|$ftDone|$ftStart", (New-Object System.Text.UTF8Encoding $false)) } catch {}
                }
                if ($ftState -eq 'done' -and ($saNow - [long]$ftDone) -gt $DONE_LINGER) { continue }
                $feedCandidates += @{ start = $ftStart; id = $ftId; used = $ftTok; ctx = $ftCtx; model = $ftModel; type = $ftType; state = $ftState }
            }
            # A cached task id missing from a fresh feed is a done signal: stamp
            # done_ts on first observation, linger, then drop the cache entry.
            $taskCachePrefix = "statusline-sa-$_ocSafeId-task-"
            foreach ($cf in @(Get-ChildItem -Path (Join-Path $env:TEMP "$taskCachePrefix*.txt") -ErrorAction SilentlyContinue)) {
                if ($cf.BaseName.Length -le $taskCachePrefix.Length) { continue }
                $cfId = $cf.BaseName.Substring($taskCachePrefix.Length)
                if ($feedSeen.ContainsKey($cfId)) { continue }
                $fcRaw = Get-Content -LiteralPath $cf.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $fcRaw) { continue }
                $fcParts = $fcRaw.TrimEnd() -split '\|'
                if ($fcParts.Count -lt 6) { continue }
                $fcDone = 0L
                if (-not [long]::TryParse($fcParts[4], [ref]$fcDone) -or $fcDone -le 0) {
                    $fcDone = $saNow
                    try { [System.IO.File]::WriteAllText($cf.FullName, "$($fcParts[0])|$($fcParts[1])|$($fcParts[2])|$($fcParts[3])|$fcDone|$($fcParts[5])", (New-Object System.Text.UTF8Encoding $false)) } catch {}
                }
                if (($saNow - $fcDone) -gt $DONE_LINGER) {
                    try { Remove-Item -LiteralPath $cf.FullName -Force -ErrorAction SilentlyContinue } catch {}
                    continue
                }
                $feedCandidates += @{ start = "$($fcParts[5])"; id = $cfId; used = $fcParts[0]; ctx = $fcParts[1]; model = $fcParts[2]; type = $fcParts[3]; state = 'done' }
            }
            Write-Log "subagents: feed tier, $($feedCandidates.Count) row(s)"
            # Deterministic order: startTime (ISO string sort), tiebreak id.
            foreach ($c in ($feedCandidates | Sort-Object -Property @{ Expression = { "$($_.start)" } }, @{ Expression = { "$($_.id)" } })) {
                $subagentRows += @{ s = 1; label = 'agent'; content = (Build-SubagentRow $c.used $c.ctx $c.model $c.type $c.state) }
            }
        }
    } catch {
        Write-Log ("feed tier FAILED, falling back: " + $_.Exception.Message)
        $feedTier = $false
        $subagentRows = @()
    }
}

# Fallback tier: per-agent transcripts under
# <project>/<sessionId>/subagents/agent-*.jsonl (+ sibling .meta.json).
if (-not $feedTier -and $sessionId -and $transcriptPath) {
    $projectDir   = Split-Path -Parent $transcriptPath
    $sessionBase  = [System.IO.Path]::GetFileNameWithoutExtension($transcriptPath)
    $subagentsDir = Join-Path $projectDir (Join-Path $sessionBase 'subagents')
    if (Test-Path -LiteralPath $subagentsDir) {
        Write-Log "subagents: fallback tier (feed absent/stale)"
        $saFiles = Get-ChildItem -LiteralPath $subagentsDir -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue |
                   Sort-Object Name
        foreach ($sa in $saFiles) {
            try {
                $saAge = $saNow - ([DateTimeOffset]$sa.LastWriteTimeUtc).ToUnixTimeSeconds()
                if ($saAge -gt 180) { continue }

                $saMt = $sa.LastWriteTimeUtc.Ticks
                $saCachePath = Join-Path $env:TEMP "statusline-sa-$_ocSafeId-$($sa.BaseName).txt"
                $saUseCache = $false
                $saCacheDirty = $false
                $saDone = ''
                $saPrevDone = ''

                if (Test-Path -LiteralPath $saCachePath) {
                    $sc = (Get-Content -LiteralPath $saCachePath -Raw -ErrorAction SilentlyContinue).TrimEnd() -split '\|'
                    if ($sc.Count -ge 8) {
                        $scDone = 0L
                        if ([long]::TryParse($sc[7], [ref]$scDone) -and $scDone -gt 0) { $saPrevDone = "$scDone" }
                    }
                    if ($sc.Count -ge 7 -and $sc[0] -eq "$saMt") {
                        $saSr = $sc[1]; $inTok = [long]$sc[2]; $cwTok = [long]$sc[3]; $crTok = [long]$sc[4]
                        $saModel = $sc[5]; $agentDisplay = $sc[6]; $saDone = $saPrevDone
                        $saUseCache = $true
                    }
                }

                if (-not $saUseCache) {
                    # No assistant message yet -> zeros and no model id; the row
                    # renders without the model segment for this refresh.
                    $saSr = ''; $inTok = 0L; $cwTok = 0L; $crTok = 0L; $saModel = ''
                    # Scan from end for the last assistant entry.
                    $saLines    = [System.IO.File]::ReadAllLines($sa.FullName)
                    $lastAssist = $null
                    for ($i = $saLines.Length - 1; $i -ge 0; $i--) {
                        if ($saLines[$i] -match '"type"\s*:\s*"assistant"') { $lastAssist = $saLines[$i]; break }
                    }
                    if ($lastAssist) {
                        if ($lastAssist -match '"stop_reason"\s*:\s*"([^"]*)"') { $saSr = $Matches[1] }
                        if ($lastAssist -match '"input_tokens"\s*:\s*(\d+)')                { $inTok = [long]$Matches[1] }
                        if ($lastAssist -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $cwTok = [long]$Matches[1] }
                        if ($lastAssist -match '"cache_read_input_tokens"\s*:\s*(\d+)')    { $crTok = [long]$Matches[1] }
                        if ($lastAssist -match '"model"\s*:\s*"([^"]+)"') { $saModel = $Matches[1] }
                    }
                    $agentDisplay = $sa.BaseName -replace '^agent-',''
                    $metaPath = Join-Path $sa.Directory.FullName "$($sa.BaseName).meta.json"
                    if (Test-Path -LiteralPath $metaPath) {
                        try {
                            $meta = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($meta.agentType) { $agentDisplay = $meta.agentType }
                        } catch {}
                    }
                    $saDone = $saPrevDone
                    $saCacheDirty = $true
                }

                # Any terminal stop reason is a done signal; tool_use/pause_turn
                # (and no assistant message yet) mean working.
                $saState = if ($SaTerminalStopReasons -contains $saSr) { 'done' } else { 'working' }
                if ($saState -eq 'done') {
                    if (-not $saDone) { $saDone = "$saNow"; $saCacheDirty = $true }
                } else {
                    if ($saDone) { $saCacheDirty = $true }
                    $saDone = ''
                }
                if ($saCacheDirty) {
                    try { [System.IO.File]::WriteAllText($saCachePath, "$saMt|$saSr|$inTok|$cwTok|$crTok|$saModel|$agentDisplay|$saDone", (New-Object System.Text.UTF8Encoding $false)) } catch {}
                }
                if ($saState -eq 'done' -and ($saNow - [long]$saDone) -gt $DONE_LINGER) { continue }

                $saUsed = $inTok + $cwTok + $crTok
                $saCtxSize = Get-SubagentCtxSize $saModel
                $subagentRows += @{ s = 1; label = 'agent'; content = (Build-SubagentRow $saUsed $saCtxSize $saModel $agentDisplay $saState) }
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
$BoxRowH = [char]0x2500
# Visible width — strip ANSI escapes so color codes don't count.
$ansiPattern = "$ESC\[[0-9;]*[a-zA-Z]"
function Get-Vis([string]$s) {  # visible terminal cells: ANSI stripped; CJK/emoji count as 2
    if (-not $s) { return 0 }
    $t = $s -replace $ansiPattern, ''
    $isAscii = $true
    foreach ($c in $t.ToCharArray()) { if ([int]$c -gt 127) { $isAscii = $false; break } }
    if ($isAscii) { return $t.Length }
    $w = 0
    $i = 0
    while ($i -lt $t.Length) {
        $cp = [int]$t[$i]
        if ([char]::IsHighSurrogate($t[$i]) -and ($i + 1) -lt $t.Length -and [char]::IsLowSurrogate($t[$i + 1])) {
            $cp = [char]::ConvertToUtf32($t[$i], $t[$i + 1])
            $i += 2
        } else {
            $i++
        }
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or $cp -ge 0x1F000) { $w += 2 } else { $w++ }
    }
    return $w
}
# @parity:constant LABEL_W=7
$LABEL_W = 7  # longest label: "project"
# Rows with empty content are dropped — box auto-hides sections with no data.
$rowSep = "  ${GRAY}$([char]0x00B7)${RESET}  "
$modelRow = $modelPart
if ($effortPart) { $modelRow = "${modelRow}${rowSep}${effortPart}" }
if ($statusPart) { $modelRow = "${modelRow}${rowSep}${statusPart}" }
if ($ctxBarPart) { $modelRow = "${modelRow}${rowSep}${ctxBarPart}" }
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
    @{ s=1; label='tokens'; content=$tokensPart     }
) + $subagentRows + @(
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

# --- Threshold notifications ---
if ($_ocSafeId) {
    $_notifyState = Join-Path $env:TEMP "statusline-notify-$_ocSafeId.json"
    $_nsCtx = $false; $_nsRate = $false; $_nsRateResets = ''

    if (Test-Path -LiteralPath $_notifyState -ErrorAction SilentlyContinue) {
        try {
            $_nsData = Get-Content -LiteralPath $_notifyState -Raw -Encoding UTF8 | ConvertFrom-Json
            $_nsCtx = if ($_nsData.notified_context_high -eq $true) { $true } else { $false }
            $_nsRate = if ($_nsData.notified_rate_limit -eq $true) { $true } else { $false }
            $_nsRateResets = if ($_nsData.last_rate_resets_at) { $_nsData.last_rate_resets_at } else { '' }
        } catch {}
    }

    $_ctxThresh = 70; $_rateThresh = 80
    $ncPath = "$env:USERPROFILE\.claude\notify-config.json"
    if (Test-Path $ncPath) {
        try {
            $_nc = Get-Content $ncPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $_nc.context_high.threshold) { $_ctxThresh = [int]$_nc.context_high.threshold }
            if ($null -ne $_nc.rate_limit.threshold)   { $_rateThresh = [int]$_nc.rate_limit.threshold }
        } catch {}
    }

    $_ctxPct = if ($null -ne $pctInt) { $pctInt } else { 0 }
    $_rateMax = 0
    if ($null -ne $fivePct)  { $_fp = [int][Math]::Floor([double]$fivePct);  if ($_fp -gt $_rateMax) { $_rateMax = $_fp } }
    if ($null -ne $sevenPct) { $_sp = [int][Math]::Floor([double]$sevenPct); if ($_sp -gt $_rateMax) { $_rateMax = $_sp } }

    $_rateResetsNow = if ($null -ne $fiveRes) { $fiveRes } else { '' }
    if ($null -ne $sevenPct -and $null -ne $fivePct) {
        $_sp2 = [int][Math]::Floor([double]$sevenPct); $_fp2 = [int][Math]::Floor([double]$fivePct)
        if ($_sp2 -gt $_fp2) { $_rateResetsNow = if ($null -ne $sevenRes) { $sevenRes } else { '' } }
    }
    if ($null -eq $fivePct -and $null -ne $sevenPct) { $_rateResetsNow = if ($null -ne $sevenRes) { $sevenRes } else { '' } }

    $_nsChanged = $false
    $notifyScript = "$env:USERPROFILE\.claude\notify.ps1"

    if ($_ctxPct -ge $_ctxThresh -and -not $_nsCtx) {
        if (Test-Path $notifyScript) { Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList "-NoProfile -File `"$notifyScript`" context_high $_ctxPct" }
        $_nsCtx = $true; $_nsChanged = $true
        Write-Log "notify: context_high fired at ${_ctxPct}%"
    } elseif ($_ctxPct -lt $_ctxThresh -and $_nsCtx) {
        $_nsCtx = $false; $_nsChanged = $true
        Write-Log "notify: context_high reset (${_ctxPct}% < ${_ctxThresh}%)"
    }

    if ($_rateResetsNow -ne $_nsRateResets) {
        $_nsRate = $false; $_nsChanged = $true
        Write-Log "notify: rate_limit reset (resets_at changed)"
    }
    if ($_rateMax -ge $_rateThresh -and -not $_nsRate) {
        if (Test-Path $notifyScript) { Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList "-NoProfile -File `"$notifyScript`" rate_limit $_rateMax" }
        $_nsRate = $true; $_nsChanged = $true
        Write-Log "notify: rate_limit fired at ${_rateMax}%"
    }

    if ($_nsChanged) {
        $nsCtxStr  = if ($_nsCtx)  { 'true' } else { 'false' }
        $nsRateStr = if ($_nsRate) { 'true' } else { 'false' }
        $nsJson = "{`"notified_context_high`":$nsCtxStr,`"notified_rate_limit`":$nsRateStr,`"last_rate_resets_at`":`"$_rateResetsNow`"}"
        try { [System.IO.File]::WriteAllText($_notifyState, $nsJson, (New-Object System.Text.UTF8Encoding $false)) } catch {}
    }
}

Write-Log ("about to write: lines={0} chars={1}" -f $output.Count, $finalOutput.Length)
if ($_ocPath) {
    try {
        [System.IO.File]::WriteAllText($_ocPath, "$_ocKey`n$finalOutput", (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}
Write-Host $finalOutput -NoNewline
Write-Log "stdout write: OK (via Write-Host)"
exit 0
