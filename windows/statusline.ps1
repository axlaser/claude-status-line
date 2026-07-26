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
# PowerShell evaluates call arguments before the callee's guard runs, so any
# Write-Log site whose argument does real work must also be gated on $DBG at
# the call site — the in-function guard alone cannot prevent the evaluation.
$DBG = [bool]$env:STATUSLINE_DEBUG
function Write-Log([string]$msg) {
    if (-not $DBG) { return }
    try { Add-Content -LiteralPath $logPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding utf8 } catch {}
}
if ($DBG) { Write-Log "=== invoked, PSVersion=$($PSVersionTable.PSVersion) PID=$PID ===" }
try {
    $raw  = [Console]::In.ReadToEnd()
    if ($DBG) {
        Write-Log ("stdin bytes={0}" -f $raw.Length)
        Write-Log ("stdin head: " + ($(if ($raw.Length -gt 400) { $raw.Substring(0,400) } else { $raw }) -replace "`r?`n",' '))
    }
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

# @parity:base-id-begin
# Same-model comparison ONLY -- never a storage key and never a resolver-tier input.
# Get-NormalizedModelId is deliberately left narrow: its output is the learned map's
# key AND the string the variant-marker tier matches on, so teaching it to strip
# "[1m]" would rewrite every stored key and make that tier unreachable.
function Get-ModelBaseId([string]$id) {
    $b = Get-NormalizedModelId $id
    $b = $b -replace '\[1m\]$', ''
    $b = $b -replace '-1m$', ''
    return $b.ToLowerInvariant()
}
# @parity:base-id-end

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

function Get-SubagentCtxSize([string]$model) {  # tiered: session -> learned map -> seed table -> 1m marker -> 200K default
    $norm = Get-NormalizedModelId $model
    # Session inheritance leads: a subagent running the session's own model has the
    # session's window, which is live truth for this session -- it outranks a learned
    # entry, which is a historical observation that may have come from elsewhere or
    # been wrong when written. Compared on base ids so "[1m]" and the bare id match;
    # $norm keeps its suffix for the marker tier below. Skipped entirely when the
    # session window is missing or non-positive, so nothing new can fail here.
    if ($model -and $modelId) {
        $sessWin = 0L
        if ([long]::TryParse("$ctxSize", [ref]$sessWin) -and $sessWin -gt 0 -and
            (Get-ModelBaseId $model) -eq (Get-ModelBaseId $modelId)) {
            Write-Log "sa ctx: $norm -> $sessWin (session)"
            return $sessWin
        }
    }
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

function Get-EffortColor([string]$level) {  # reasoning effort level -> ladder color
    # Shared by the model row and every subagent row so the two can never drift.
    # Unknown values (including the integer form agent frontmatter allows) fall
    # through to WHITE rather than being rejected.
# @parity:effort-ladder-begin
    switch ($level) {
        'low'    { $GRAY }
        'medium' { $WHITE }
        'high'   { $CYAN }
        'xhigh'  { $YELLOW }
        'max'    { $RED }
        default  { $WHITE }
    }
# @parity:effort-ladder-end
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

# @parity:temp-guards-begin
# Trust boundary for predictable temp files. %TEMP% is per-user, so a foreign
# owner is unexpected here; we still check owner (SID) and reparse-point for
# parity/defense-in-depth. Reads trust only a regular file we own that is not a
# reparse point (symlink/junction); writes drop a reparse-point/foreign target
# and skip when it survives, never following a planted link. Bounded to the few
# cache/state files touched per refresh, never called per row.
function Test-TrustedFile([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return $false }
    try {
        # FileInfo directly, not Get-Item: keeps the pre-hit path cmdlet-free and
        # needs no module at all — strictly safer than a cmdlet in the auto-loading-off
        # child process (see the Get-Acl note below). Exists is false for a directory,
        # preserving the old PSIsContainer rejection; -Force is moot (FileInfo sees
        # hidden files).
        $item = [System.IO.FileInfo]::new($path)
        if (-not $item.Exists -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
        # Owner is defense-in-depth on a per-user %TEMP%; the reparse-point rejection
        # above is the load-bearing guard. Resolve it off the FileInfo rather than via
        # Get-Acl: that cmdlet is NOT available in the child process Claude Code spawns
        # for the statusline (module auto-loading is off there), so depending on it
        # made this return $false for every file -- silently disabling every read-side
        # cache and re-firing threshold alerts on every refresh. Tolerate an
        # undeterminable owner, matching what Test-WriteOk already does.
        $owner = $null
        try { $owner = $item.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]) } catch {}
        if ($null -eq $owner) { return $true }
        return ($owner -eq [System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    } catch { return $false }
}
function Test-WriteOk([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item) {
            $bad = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if (-not $bad) {
                try {
                    # Off the FileInfo, not Get-Acl -- see Test-TrustedFile above.
                    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                    $bad = ($item.GetAccessControl().GetOwner([System.Security.Principal.SecurityIdentifier]) -ne $me)
                } catch { $bad = $false }
            }
            if ($bad) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return -not ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
    } catch { return $true }
}
# @parity:temp-guards-end

# @parity:sanitize-title-begin
# Shared field sanitizer (subagent render sink, git-branch render, fallback meta
# reads). Defined early so the git block — which runs before Build-SubagentRow —
# can call it.
function Format-SaTitle($s) {  # replace "|" and control chars with spaces, trim -> '' when blank
    if ($null -eq $s) { return '' }
    return ("$s" -replace '[\x00-\x1f\x7f|]', ' ').Trim()
}
# @parity:sanitize-title-end

# @parity:raw-extract-begin
# The output-cache key needs only these three fields, so they are pulled from
# the raw string and ConvertFrom-Json (~90 ms) is deferred past the cache
# check — a hit never parses. The authoritative values are re-extracted from
# the parsed object right after the cache check; the raw ones feed the key's
# file probes plus the oc/feed cache paths, and every other per-session file
# path is re-derived from the parsed session_id after the parse (see the
# recompute below @parity:json-extract-end). A wrong extraction cannot
# false-hit: the raw payload itself is part of the key. Escape-aware: the
# value scan steps over backslash escapes and ConvertFrom-JsonString decodes
# them, so escaped Windows paths stat the real file.
function ConvertFrom-JsonString([string]$s) {
    if (-not $s -or $s.IndexOf('\') -lt 0) { return $s }
    $sb = [System.Text.StringBuilder]::new($s.Length)
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($ch -ne '\' -or $i + 1 -ge $s.Length) { [void]$sb.Append($ch); continue }
        $i++
        switch ($s[$i]) {
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            '/' { [void]$sb.Append('/') }
            'b' { [void]$sb.Append([char]8) }
            'f' { [void]$sb.Append([char]12) }
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            'u' {
                $cp = 0
                if ($i + 4 -lt $s.Length -and [int]::TryParse($s.Substring($i + 1, 4), [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$cp)) {
                    [void]$sb.Append([char]$cp); $i += 4
                } else { [void]$sb.Append('u') }
            }
            default { [void]$sb.Append($s[$i]) }
        }
    }
    return $sb.ToString()
}
function Get-RawJsonField([string]$payload, [string]$name) {
    # Plain IndexOf/char scan, no regex: the three fields sit in the first few
    # hundred bytes of the payload, so this costs ~nothing on every tick. An
    # occurrence of the quoted name that is not followed by a colon (e.g. the
    # name appearing inside another field's string value) is skipped.
    if (-not $payload) { return $null }
    $needle = '"' + $name + '"'
    $pos = 0
    while ($true) {
        $k = $payload.IndexOf($needle, $pos, [System.StringComparison]::Ordinal)
        if ($k -lt 0) { return $null }
        $i = $k + $needle.Length
        while ($i -lt $payload.Length -and [char]::IsWhiteSpace($payload[$i])) { $i++ }
        if ($i -lt $payload.Length -and $payload[$i] -eq ':') {
            $i++
            while ($i -lt $payload.Length -and [char]::IsWhiteSpace($payload[$i])) { $i++ }
            if ($i -lt $payload.Length -and $payload[$i] -eq '"') {
                $i++
                $start = $i
                while ($i -lt $payload.Length) {
                    $ch = $payload[$i]
                    if ($ch -eq '\') { $i += 2; continue }
                    if ($ch -eq '"') { return (ConvertFrom-JsonString $payload.Substring($start, $i - $start)) }
                    $i++
                }
                return $null
            }
        }
        $pos = $k + 1
    }
}
$sessionId = $null; $transcriptPath = $null; $gitCwd = $null
try {
    $sessionId      = Get-RawJsonField $raw 'session_id'
    $transcriptPath = Get-RawJsonField $raw 'transcript_path'
    $gitCwd         = Get-RawJsonField $raw 'current_dir'
} catch {}
if ($DBG) { Write-Log ("raw-extract: sid={0} transcript={1} cwd={2}" -f $sessionId, $transcriptPath, $gitCwd) }
# @parity:raw-extract-end

# --- Output cache: skip re-render when all inputs are unchanged ---
$_ocSafeId = if ($sessionId) { $sessionId -replace '[^a-zA-Z0-9_-]', '' } else { $null }
$_ocPath = if ($_ocSafeId) { [System.IO.Path]::Combine($env:TEMP, "statusline-oc-$_ocSafeId.txt") } else { $null }
$_ocTmt = ''
# Everything up to the cache-hit exit sticks to direct .NET calls — no cmdlets.
# The first cmdlet call in a fresh powershell.exe pays ~80 ms of one-time
# command-discovery/module init, so a single Get-Item or Test-Path here would
# silently re-add the cost the deferred parse removed. File.GetLastWriteTimeUtc
# does not need -Force: hidden files (like .git\index) are visible to it.
# Each probe sits in its own try/catch: .NET Framework's Path.Combine and
# GetDirectoryName throw on Windows-illegal path characters where the old
# Join-Path/Split-Path tolerated them, and a pathological path field must
# degrade to an empty probe value (same as "file not present"), never reach
# the trap's error banner.
try {
    if ($transcriptPath -and [System.IO.File]::Exists($transcriptPath)) {
        $_ocTmt = [System.IO.File]::GetLastWriteTimeUtc($transcriptPath).Ticks
    }
} catch {}
$_ocGmt = ''
try {
    $_ocGitCwd = if ($gitCwd) { $gitCwd } else { [System.IO.Directory]::GetCurrentDirectory() }
    $_ocGidx = [System.IO.Path]::Combine($_ocGitCwd, '.git\index')
    if ([System.IO.File]::Exists($_ocGidx)) {
        $_ocGmt = [System.IO.File]::GetLastWriteTimeUtc($_ocGidx).Ticks
    }
} catch {}
$_ocSmt = ''
try {
    if ($transcriptPath) {
        $_ocSdir = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($transcriptPath), [System.IO.Path]::GetFileNameWithoutExtension($transcriptPath), 'subagents')
        if ([System.IO.Directory]::Exists($_ocSdir)) {
            $_ocSmt = [System.IO.Directory]::GetLastWriteTimeUtc($_ocSdir).Ticks
        }
    }
} catch {}
# Feed content+freshness and the learned-map mtime join the key so subagent
# tier switches and learned window changes invalidate the render cache. The
# handler rewrites the feed file every tick, so keying on its mtime would
# defeat the output cache; mtime feeds only the freshness flag.
$_ocFeed = if ($_ocSafeId) { [System.IO.Path]::Combine($env:TEMP, "statusline-tasks-$_ocSafeId.json") } else { $null }
# @parity:cache FEED_TTL=10
$FEED_TTL = 10
$_ocFfresh = 0
$_ocFjson = ''
if ($_ocFeed -and (Test-TrustedFile $_ocFeed)) {
    try {
        $_ocFeedAge = ([DateTimeOffset]::UtcNow - [DateTimeOffset][System.IO.File]::GetLastWriteTimeUtc($_ocFeed)).TotalSeconds
        if ($_ocFeedAge -le $FEED_TTL) {
            $_ocFfresh = 1
            $_ocFjson = [System.IO.File]::ReadAllText($_ocFeed)
        }
    } catch {}
}
$_ocMwPath = "$env:USERPROFILE\.claude\statusline-model-windows.json"
$_ocMwmt = ''
if ([System.IO.File]::Exists($_ocMwPath)) {
    try { $_ocMwmt = [System.IO.File]::GetLastWriteTimeUtc($_ocMwPath).Ticks } catch {}
}
# @parity:cache OUTPUT_BUCKET=5
$_ocNowBucket = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 5)
$_ocKeyInput = "${raw}|${_ocTmt}|${_ocGmt}|${_ocSmt}|${_ocFfresh}|${_ocFjson}|${_ocMwmt}|${_ocNowBucket}"
$_ocKey = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($_ocKeyInput))).Replace('-','')

if ($_ocPath -and (Test-TrustedFile $_ocPath)) {
    try {
        # Single read + substring instead of ReadAllLines + a Select-Object pipeline;
        # the record is "<key>`n<output>" with no trailing newline (see the write site).
        $ocText = [System.IO.File]::ReadAllText($_ocPath)
        $ocNl = $ocText.IndexOf("`n")
        if ($ocNl -gt 0 -and $ocText.Length -gt ($ocNl + 1) -and $ocText.Substring(0, $ocNl) -eq $_ocKey) {
            Write-Log "output cache HIT"
            [Console]::Write($ocText.Substring($ocNl + 1))
            exit 0
        }
    } catch {
        Write-Log ("output cache read failed, re-rendering: " + $_.Exception.Message)
    }
}

# --- Parse (cache misses only) ---
# Same error message and exit as the old read+parse site: a malformed payload
# renders the bad-JSON notice on every tick — it can never false-hit the cache
# above, because the raw string is part of the key and an error tick writes no
# cache record.
try {
    $json = $raw | ConvertFrom-Json
    Write-Log "json parse: OK"
} catch {
    Write-Log ("READ/PARSE FAILED: " + $_.Exception.Message)
    [Console]::Write("${RED}[statusline: bad JSON]${RESET}")
    exit 0
}

# @parity:json-extract-begin
# Direct property chains: with StrictMode off, a missing member anywhere in the
# chain yields $null — same result as the old Get-Val walker at ~1 ms per 23
# lookups instead of ~19 ms of function-call overhead. Do not enable StrictMode.
# sessionId/transcriptPath/gitCwd are re-assigned here authoritatively.
$sessionId        = $json.session_id
$cwdRaw           = $json.workspace.current_dir
$cwdFallback      = $json.cwd
$modelDisplay     = $json.model.display_name
$ctxSize          = $json.context_window.context_window_size
$usedPct          = $json.context_window.used_percentage
$totalInputTokens = $json.context_window.total_input_tokens
$effortLevel      = $json.effort.level
$gitCwd           = $json.workspace.current_dir
$totalCost        = $json.cost.total_cost_usd
$totalCostLegacy  = $json.total_cost_usd
$durationMs       = $json.cost.total_duration_ms
$durationMsL1     = $json.total_duration_ms
$durationMsL2     = $json.duration_ms
$transcriptPath   = $json.transcript_path
$fivePct          = $json.rate_limits.five_hour.used_percentage
$fiveRes          = $json.rate_limits.five_hour.resets_at
$sevenPct         = $json.rate_limits.seven_day.used_percentage
$sevenRes         = $json.rate_limits.seven_day.resets_at
$agentName        = $json.agent.name
$agentIn          = $json.context_window.current_usage.input_tokens
if ($null -eq $agentIn) { $agentIn = 0 }
$agentOut         = $json.context_window.current_usage.output_tokens
if ($null -eq $agentOut) { $agentOut = 0 }
$modelId          = $json.model.id
# @parity:json-extract-end

# Re-derive the per-session file id from the parsed session_id: it names every
# cache/state file below (transcript cache, task caches, subagent caches, git
# cache, notify latches). $_ocPath and $_ocFeed keep their pre-parse binding so
# the output-cache check above and the write at the bottom stay coherent.
$_ocSafeId = if ($sessionId) { $sessionId -replace '[^a-zA-Z0-9_-]', '' } else { $null }

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
    $effortPart = "$(Get-EffortColor $effortLevel)${effortLevel} effort${RESET}"
}
# --- 4. Git status ---
$gitPart = ''
try {
    if (-not $gitCwd) { $gitCwd = (Get-Location).Path }
    $gitIndex = Join-Path $gitCwd '.git\index'
    if (Test-Path -LiteralPath $gitIndex -ErrorAction SilentlyContinue) {
        $gitIndexMt = (Get-Item -LiteralPath $gitIndex -Force).LastWriteTimeUtc.Ticks
        $safeSessionId = $_ocSafeId
        $gitCachePath = if ($safeSessionId) { Join-Path $env:TEMP "statusline-git-$safeSessionId.txt" } else { $null }
        $gitUseCache = $false
        $branch = $null; $insertions = 0; $deletions = 0; $untracked = 0; $ahead = 0; $behind = 0; $stash = 0

        if ($gitCachePath -and (Test-TrustedFile $gitCachePath)) {
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
            # One porcelain-v2 call covers branch, ahead/behind, stash, and untracked
            # (git >= 2.15 for --show-stash; on older git the call fails and the git
            # segment renders empty via the existing degradation path).
            $branch = $null; $headOid = $null
            $untracked = 0; $ahead = 0; $behind = 0; $stash = 0
            $gitLines = @(& git --no-optional-locks -C $gitCwd status --porcelain=v2 --branch --show-stash 2>$null)
            foreach ($gitLine in $gitLines) {
                if ($null -eq $gitLine) { continue }
                # .StartsWith, never -like '? *' — -like treats '?' as a wildcard.
                if ($gitLine.StartsWith('? ')) { $untracked++ }
                elseif ($gitLine.StartsWith('# branch.head ')) { $branch = $gitLine.Substring(14) }
                elseif ($gitLine.StartsWith('# branch.oid '))  { $headOid = $gitLine.Substring(13) }
                elseif ($gitLine.StartsWith('# branch.ab ')) {
                    $abParts = $gitLine.Substring(12) -split ' '
                    if ($abParts.Count -ge 2) { $ahead = [int]$abParts[0].TrimStart('+'); $behind = [int]$abParts[1].TrimStart('-') }
                }
                elseif ($gitLine.StartsWith('# stash ')) { $stash = [int]$gitLine.Substring(8) }
            }
            if ($branch -eq '(detached)') {
                # Ask git for the abbreviation so the hash length always matches
                # what git would print (it lengthens abbreviations for uniqueness).
                $short = & git --no-optional-locks -C $gitCwd rev-parse --short HEAD 2>$null
                $branch = if ($short) { $short } else { 'HEAD' }
            } elseif ($headOid -eq '(initial)') {
                # Unborn HEAD: the old rev-parse path rendered the literal 'HEAD' on
                # Windows (bash renders no segment) — preserve that divergence.
                $branch = 'HEAD'
            }
            if ($branch) {
                $diffStat = & git --no-optional-locks -C $gitCwd diff --shortstat HEAD 2>$null
                $insertions = 0; $deletions = 0
                if ($diffStat -and $diffStat.Trim() -ne '') {
                    if ($diffStat -match '(\d+) insertion') { $insertions = [int]$Matches[1] }
                    if ($diffStat -match '(\d+) deletion')  { $deletions  = [int]$Matches[1] }
                }
            }
            if ($gitCachePath -and (Test-WriteOk $gitCachePath)) { try { $d = [char]0x1F; [System.IO.File]::WriteAllText($gitCachePath, "$gitIndexMt$d$branch$d$insertions$d$deletions$d$untracked$d$ahead$d$behind$d$stash", (New-Object System.Text.UTF8Encoding $false)) } catch {} }
        }

        # Scrub control/escape bytes from the branch (its cached value is plantable
        # via statusline-git-*), mirroring the subagent render-sink scrub.
        $branch = Format-SaTitle $branch
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
        if ($cachePath -and (Test-TrustedFile $cachePath)) {
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
                if ($cachePath -and (Test-WriteOk $cachePath)) {
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
$sep        = " ${GRAY}$([char]0x00B7)${RESET} "
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
    $ratePart = $parts5d -join " ${GRAY}$([char]0x00B7)${RESET} "
}
# --- 7. Agent / subagent status (--agent startup mode only) ---
$agentPart = ''
if ($agentName) {
    $agentPart = "${BLUE}${BOLD}${agentName}${RESET}"
    $agentCompact = ''
    $sep = " ${GRAY}$([char]0x00B7)${RESET} "
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

function Build-SubagentRow($used, $ctxSize, $model, $disp, $state, $effort) {
    $u = 0L
    if (-not [long]::TryParse("$used", [ref]$u) -or $u -lt 0) { $u = 0L }
    $w = 0L
    if (-not [long]::TryParse("$ctxSize", [ref]$w) -or $w -le 0) { $w = 200000L }
    # Render-sink scrub: strip control/escape bytes from the three untrusted display
    # fields so no source path (feed-live, feed-read-back, transcript-fallback) can
    # emit a terminal escape planted via a cache file. The sink scrubs only the
    # fields it names, so a newly added field inherits nothing automatically.
    $model = Format-SaTitle $model
    $disp = Format-SaTitle $disp
    # Bounded here rather than at ingest so every source path is capped, including
    # a record written by an older version. No real level exceeds 6 characters, so
    # this never truncates a legitimate value.
    $effort = "$(Format-SaTitle $effort)"
    if ($effort.Length -gt 16) {
        # Cut to 16 UTF-16 units, one less if that would split a surrogate pair
        # (same guard as the title cut below).
        $eCut = 16
        if ([char]::IsHighSurrogate($effort[15])) { $eCut = 15 }
        $effort = $effort.Substring(0, $eCut)
    }
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
    # Present only when the feed reported an override; absence is meaningful, so
    # nothing is inferred from the session's own effort here.
    if ($effort) { $row += "${saSep}$(Get-EffortColor $effort)${effort} effort${RESET}" }
    $disp = "$disp"
    if ($disp.Length -gt 40) {
        # Cut to 39 UTF-16 units, one less if that would split a surrogate pair.
        $dispCut = 39
        if ([char]::IsHighSurrogate($disp[38])) { $dispCut = 38 }
        $disp = $disp.Substring(0, $dispCut) + [char]0x2026
    }
    if ($disp)  { $row += "${saSep}${BLUE}${disp}${RESET}" }
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
                # Row title: description -> type -> name, first non-blank after
                # sanitizing "|"/control chars to spaces, so a hostile title
                # can't corrupt the pipe-delimited task cache.
                $ftDisp = Format-SaTitle $t.description
                if (-not $ftDisp) { $ftDisp = Format-SaTitle $t.type }
                if (-not $ftDisp) { $ftDisp = Format-SaTitle $t.name }
                $ftStatus = if ($null -ne $t.status) { "$($t.status)" } else { '' }
                # Scrub control chars / "|" from model before it enters the
                # pipe-delimited cache record (mirrors the title's ingest scrub).
                $ftModel  = Format-SaTitle $t.model
                # Absent unless the task carried an explicit override, and absence
                # is what suppresses the segment — do not default it to anything.
                $ftEffort = Format-SaTitle $t.effort
                # Scrubbed like model/effort: it is no longer the trailing field, so a
                # separator here would shift the split and land in the rendered effort.
                $ftStart  = Format-SaTitle $t.startTime
                if (-not ($ftId -or $ftDisp -or $ftStatus -or $ftModel)) { continue }
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
                    if ($ftCache -and (Test-TrustedFile $ftCache)) {
                        $fcRaw = Get-Content -LiteralPath $ftCache -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($fcRaw) {
                            $fcParts = $fcRaw.TrimEnd() -split '\|'
                            $fcPrev = 0L
                            if ($fcParts.Count -ge 5 -and [long]::TryParse($fcParts[4], [ref]$fcPrev) -and $fcPrev -gt 0) { $ftDone = "$fcPrev" }
                        }
                    }
                    if (-not $ftDone) { $ftDone = "$saNow" }
                }
                if ($ftCache -and (Test-WriteOk $ftCache)) {
                    try { [System.IO.File]::WriteAllText($ftCache, "$ftTok|$ftCtx|$ftModel|$ftDisp|$ftDone|$ftStart|$ftEffort", (New-Object System.Text.UTF8Encoding $false)) } catch {}
                }
                if ($ftState -eq 'done' -and ($saNow - [long]$ftDone) -gt $DONE_LINGER) { continue }
                $feedCandidates += @{ start = $ftStart; id = $ftId; used = $ftTok; ctx = $ftCtx; model = $ftModel; disp = $ftDisp; state = $ftState; effort = $ftEffort }
            }
            # A cached task id missing from a fresh feed is a done signal: stamp
            # done_ts on first observation, linger, then drop the cache entry.
            $taskCachePrefix = "statusline-sa-$_ocSafeId-task-"
            # Directory.GetFiles avoids the Get-ChildItem provider pipeline (~15 ms).
            # The EndsWith guard restores exact '*.txt' semantics — the Win32 search
            # pattern also matches extensions that merely start with 'txt'.
            $cfAll = @()
            try { $cfAll = [System.IO.Directory]::GetFiles($env:TEMP, "$taskCachePrefix*.txt") } catch {}
            foreach ($cf in $cfAll) {
                if (-not $cf.EndsWith('.txt', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $cfName = [System.IO.Path]::GetFileNameWithoutExtension($cf)
                if ($cfName.Length -le $taskCachePrefix.Length) { continue }
                $cfId = $cfName.Substring($taskCachePrefix.Length)
                if ($feedSeen.ContainsKey($cfId)) { continue }
                if (-not (Test-TrustedFile $cf)) { continue }
                $fcRaw = Get-Content -LiteralPath $cf -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not $fcRaw) { continue }
                $fcParts = $fcRaw.TrimEnd() -split '\|'
                if ($fcParts.Count -lt 6) { continue }
                # Lenient on the appended 7th field: a record written before effort
                # existed stays valid and simply renders no segment, which is
                # indistinguishable from the legitimate no-override state.
                $fcEffort = if ($fcParts.Count -ge 7) { $fcParts[6] } else { '' }
                $fcDone = 0L
                if (-not [long]::TryParse($fcParts[4], [ref]$fcDone) -or $fcDone -le 0) {
                    $fcDone = $saNow
                    try { [System.IO.File]::WriteAllText($cf, "$($fcParts[0])|$($fcParts[1])|$($fcParts[2])|$($fcParts[3])|$fcDone|$($fcParts[5])|$fcEffort", (New-Object System.Text.UTF8Encoding $false)) } catch {}
                }
                if (($saNow - $fcDone) -gt $DONE_LINGER) {
                    try { Remove-Item -LiteralPath $cf -Force -ErrorAction SilentlyContinue } catch {}
                    continue
                }
                $feedCandidates += @{ start = "$($fcParts[5])"; id = $cfId; used = $fcParts[0]; ctx = $fcParts[1]; model = $fcParts[2]; disp = $fcParts[3]; state = 'done'; effort = $fcEffort }
            }
            Write-Log "subagents: feed tier, $($feedCandidates.Count) row(s)"
            # Deterministic order: startTime (ISO string sort), tiebreak id.
            foreach ($c in ($feedCandidates | Sort-Object -Property @{ Expression = { "$($_.start)" } }, @{ Expression = { "$($_.id)" } })) {
                $subagentRows += @{ s = 1; label = 'agent'; content = (Build-SubagentRow $c.used $c.ctx $c.model $c.disp $c.state $c.effort) }
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
    if (Test-Path -LiteralPath $subagentsDir -ErrorAction SilentlyContinue) {
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

                if (Test-TrustedFile $saCachePath) {
                    $sc = (Get-Content -LiteralPath $saCachePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).TrimEnd() -split '\|'
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
                            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                            # Title chain: meta description -> agentType -> filename id
                            # (already set); each candidate sanitized before the blank test.
                            $metaDesc = Format-SaTitle $meta.description
                            if ($metaDesc) {
                                $agentDisplay = $metaDesc
                            } else {
                                $metaType = Format-SaTitle $meta.agentType
                                if ($metaType) { $agentDisplay = $metaType }
                            }
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
                if ($saCacheDirty -and (Test-WriteOk $saCachePath)) {
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
$rowSep = " ${GRAY}$([char]0x00B7)${RESET} "
$modelRow = $modelPart
if ($effortPart) { $modelRow = "${modelRow}${rowSep}${effortPart}" }
if ($statusPart) { $modelRow = "${modelRow}${rowSep}${statusPart}" }
$costRow = ''
$costParts = @()
if ($costPart)     { $costParts += $costPart }
if ($msgPart)      { $costParts += $msgPart }
if ($durationPart) { $costParts += $durationPart }
if ($ratePart)     { $costParts += $ratePart }
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
    @{ s=1; label='tokens'; content=$tokensPart     }
) + $subagentRows + @(
    @{ s=1; label='cost'; content=$costRow          }
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

    # Fail closed when the state file exists but cannot be read. An empty or torn
    # read yields $null, and $null -eq $true is false, so the latches would look
    # like "never notified" and re-fire the alert on every refresh for as long as
    # the collision lasts. A missing file legitimately means "never notified".
    $_nsUsable = $true
    if (Test-Path -LiteralPath $_notifyState) {
        # It exists, so the latch must actually be read. Anything that stops us --
        # an untrusted file, a torn read, unparseable JSON -- means we cannot know
        # whether we already alerted, and guessing "no" re-fires every refresh.
        $_nsUsable = $false
        if (Test-TrustedFile $_notifyState) {
            try {
                $_nsData = Get-Content -LiteralPath $_notifyState -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $_nsData -and $null -ne $_nsData.notified_context_high) {
                    $_nsCtx = if ($_nsData.notified_context_high -eq $true) { $true } else { $false }
                    $_nsRate = if ($_nsData.notified_rate_limit -eq $true) { $true } else { $false }
                    $_nsRateResets = if ($_nsData.last_rate_resets_at) { $_nsData.last_rate_resets_at } else { '' }
                    $_nsUsable = $true
                }
            } catch {}
        }
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

    if ($_nsUsable -and $_ctxPct -ge $_ctxThresh -and -not $_nsCtx) {
        if (Test-Path $notifyScript) { Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList "-NoProfile -File `"$notifyScript`" context_high $_ctxPct" }
        $_nsCtx = $true; $_nsChanged = $true
        Write-Log "notify: context_high fired at ${_ctxPct}%"
    } elseif ($_ctxPct -lt $_ctxThresh -and $_nsCtx) {
        $_nsCtx = $false; $_nsChanged = $true
        Write-Log "notify: context_high reset (${_ctxPct}% < ${_ctxThresh}%)"
    }

    # Compared as strings on both sides: the stored value is JSON text, so an
    # untyped comparison can never settle and would rewrite the file every refresh,
    # widening the window a concurrent reader can tear.
    if ("$_rateResetsNow" -ne "$_nsRateResets") {
        $_nsRate = $false; $_nsChanged = $true
        Write-Log "notify: rate_limit reset (resets_at changed)"
    }
    if ($_nsUsable -and $_rateMax -ge $_rateThresh -and -not $_nsRate) {
        if (Test-Path $notifyScript) { Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList "-NoProfile -File `"$notifyScript`" rate_limit $_rateMax" }
        $_nsRate = $true; $_nsChanged = $true
        Write-Log "notify: rate_limit fired at ${_rateMax}%"
    }

    if ($_nsUsable -and $_nsChanged -and (Test-WriteOk $_notifyState)) {
        $nsCtxStr  = if ($_nsCtx)  { 'true' } else { 'false' }
        $nsRateStr = if ($_nsRate) { 'true' } else { 'false' }
        $nsJson = "{`"notified_context_high`":$nsCtxStr,`"notified_rate_limit`":$nsRateStr,`"last_rate_resets_at`":`"$_rateResetsNow`"}"
        # Atomic write: temp file then rename, so a concurrent refresh never observes
        # a truncated latch file. WriteAllText truncates in place, which left the file
        # momentarily empty on every refresh (mirrors subagent-statusline.ps1).
        $nsTmp = "$_notifyState.tmp.$PID"
        try {
            [System.IO.File]::WriteAllText($nsTmp, $nsJson, (New-Object System.Text.UTF8Encoding $false))
            Move-Item -LiteralPath $nsTmp -Destination $_notifyState -Force -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $nsTmp) { Remove-Item -LiteralPath $nsTmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

if ($DBG) { Write-Log ("about to write: lines={0} chars={1}" -f $output.Count, $finalOutput.Length) }
if ($_ocPath -and (Test-WriteOk $_ocPath)) {
    try {
        [System.IO.File]::WriteAllText($_ocPath, "$_ocKey`n$finalOutput", (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}
[Console]::Write($finalOutput)
Write-Log "stdout write: OK (via Console.Write)"
exit 0
