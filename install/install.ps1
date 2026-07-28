#Requires -Version 5.1
# Installs the claude-statusline binary into %USERPROFILE%\.claude\bin and
# registers it in settings.json (R6).
#
# BOM-LESS and ASCII-ONLY, deliberately. This file is fetched with `irm <url> |
# iex`, and a BOM survives irm as a stray U+FEFF that breaks iex on the first
# token. ASCII-only keeps it safe to run from a local clone too. See
# .gitattributes -- do not "fix" the missing BOM back.
#
# No `exit` anywhere. `irm | iex` runs this in the user's live session, where
# `exit` closes their terminal. Every abort below uses `return`.

if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    Write-Host "  PowerShell 5.1+ required (current: $($PSVersionTable.PSVersion))" -ForegroundColor Red
    return
}

$repoSlug       = "axlaser/claude-statusline"
$signerWorkflow = "$repoSlug/.github/workflows/release.yml"

$claudeDir    = "$env:USERPROFILE\.claude"
$binDir       = "$claudeDir\bin"
$binPath      = "$binDir\claude-statusline.exe"
$sidecarPath  = "$binDir\claude-statusline.exe.old"
$settingsPath = "$claudeDir\settings.json"
$configPath   = "$claudeDir\notify-config.json"
$iconPath     = "$claudeDir\claude-icon.png"
$stagePrefix  = ".claude-statusline.stage."

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

function Format-Size([long]$bytes) {
    if ($bytes -ge 1048576) { return ("{0:N1} MB" -f ($bytes / 1048576)) }
    if ($bytes -ge 1024)    { return ("{0:N1} KB" -f ($bytes / 1024)) }
    return "$bytes B"
}

# Removes the staged download. Called on every path that does not place it
# (R10): a staged file left behind is an unverified binary sitting in the
# install directory.
function Remove-Stage {
    foreach ($p in @($script:stagePath, $script:sumsPath, $script:bundlePath)) {
        if ($p -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

# --- Options ---
$requireAttestation = $false
$allowPrerelease = $false
$pinnedVersion = $env:CLAUDE_STATUSLINE_VERSION
foreach ($a in $args) {
    if ($a -eq '--require-attestation') { $requireAttestation = $true }
    elseif ($a -eq '--pre')             { $allowPrerelease = $true }
    elseif ($a -like '--version=*')     { $pinnedVersion = $a.Substring(10) }
}

Write-Host ""
Write-Host "  ${DIM}claude-statusline installer${RESET}"
Write-Host "  ${GRAY}-----------------------------------------${RESET}"
Write-Host ""

# --- Platform detection (R13) ---
# Before anything is created, removed, or written: an unsupported platform must
# leave an existing installation exactly as it was (AE16).
Step "Detecting platform"
$archRaw = $env:PROCESSOR_ARCHITECTURE
if (-not $archRaw) { $archRaw = "" }
$arch = switch -Wildcard ($archRaw.ToUpper()) {
    "AMD64" { "x86_64"; break }
    "ARM64" { "aarch64"; break }
    default { "" }
}
# A 32-bit PowerShell on 64-bit Windows reports x86 in PROCESSOR_ARCHITECTURE
# and the real value in PROCESSOR_ARCHITEW6432. Without this the installer
# refuses on a machine it fully supports.
if (-not $arch -and $env:PROCESSOR_ARCHITEW6432) {
    $arch = switch -Wildcard ($env:PROCESSOR_ARCHITEW6432.ToUpper()) {
        "AMD64" { "x86_64"; break }
        "ARM64" { "aarch64"; break }
        default { "" }
    }
}
if (-not $arch) {
    Err "Unsupported architecture: $archRaw"
    Info "Published targets: Windows, macOS and Linux on x86_64 and aarch64."
    Info "Nothing was changed."
    return
}
$target = "$arch-pc-windows-msvc"
$asset  = "claude-statusline-$target.exe"
Ok $target
Write-Host ""

# --- Resolve the release (R5) ---
Step "Resolving release"
if ($pinnedVersion) {
    $tag = $pinnedVersion
    Ok "Pinned to $tag"
} elseif ($allowPrerelease) {
    # The releases atom feed lists every release newest-first, prereleases
    # included, over plain unauthenticated HTTPS. That is the whole reason to
    # use it rather than the API: no token, no rate limit that a shared IP can
    # exhaust for everyone behind it.
    #
    # "Newest overall" is the deliberate semantic, not "newest prerelease". A
    # user who asks for --pre wants whatever is furthest ahead; once a stable
    # release overtakes the prereleases, that is the stable one, and silently
    # installing an older prerelease instead would be the surprising answer.
    $tag = $null
    try {
        $atom = (Invoke-WebRequest -Uri "https://github.com/$repoSlug/releases.atom" `
            -UseBasicParsing -ErrorAction Stop).Content
        if ($atom -match 'releases/tag/([^"<]+)') { $tag = $Matches[1] }
    } catch {}
    if (-not $tag) {
        Err "Could not resolve a prerelease"
        Info "Set CLAUDE_STATUSLINE_VERSION=<tag> to pin a version, or check your connection."
        Info "Your existing installation was left untouched."
        return
    }
    Warn "Installing $tag (prerelease channel)"
} else {
    # The /releases/latest redirect resolves the current stable tag without an
    # authenticated API call, and excludes prereleases -- which is what keeps
    # the pipeline-verification tags of R36 from ever being installed.
    $tag = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://github.com/$repoSlug/releases/latest" `
            -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        $tag = ($resp.BaseResponse.ResponseUri.AbsoluteUri -split '/')[-1]
    } catch {
        try { $tag = ($_.Exception.Response.ResponseUri.AbsoluteUri -split '/')[-1] } catch {}
    }
    if (-not $tag -or $tag -eq 'latest') {
        Err "Could not resolve the latest release"
        Info "Set CLAUDE_STATUSLINE_VERSION=<tag> to pin a version, or --pre for the"
        Info "prerelease channel, or check your connection."
        Info "Your existing installation was left untouched."
        return
    }
    Ok $tag
}
$baseUrl = "https://github.com/$repoSlug/releases/download/$tag"
Write-Host ""

# --- Verify the install directory (R9) ---
# Deliberately inverted relative to the runtime guard: at runtime an
# undeterminable owner leaves the guard passing, because failing a read closed
# kills every cache and re-fires alerts. Here the check runs once, at install
# time, and a directory we cannot vouch for is one we must not place an
# executable into.
Step "Checking the install directory"
if (Test-Path $binDir) {
    $item = Get-Item $binDir -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Err "$binDir is a reparse point (junction or symlink)"
        Info "Refusing to install through a link. Remove it and re-run."
        return
    }
} else {
    try {
        New-Item -ItemType Directory -Path $binDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Err "Cannot create $binDir"
        return
    }
    Ok "Created $binDir"
}

$acl = $null
try { $acl = Get-Acl $binDir -ErrorAction Stop } catch {}
if (-not $acl) {
    Err "Cannot read the ACL of $binDir"
    Info "Refusing to install where the directory cannot be vouched for."
    return
}
$me = ([Security.Principal.WindowsIdentity]::GetCurrent()).User
if (-not $me) {
    Err "Cannot determine the current user"
    return
}
if ($acl.Owner) {
    $ownerSid = $null
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier])
    } catch {
        try { $ownerSid = [Security.Principal.SecurityIdentifier]$acl.Owner } catch {}
    }
    if (-not $ownerSid) {
        Err "Cannot resolve the owner of $binDir"
        return
    }
    # Administrators owning a directory in the user's own profile is normal on
    # Windows when the profile was created by an elevated process, so an
    # admin-owned directory is accepted where a third user's would not be.
    $admins = New-Object Security.Principal.SecurityIdentifier(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    if ($ownerSid -ne $me -and $ownerSid -ne $admins) {
        Err "$binDir is owned by $($acl.Owner), not by you"
        return
    }
} else {
    Err "Cannot determine the owner of $binDir"
    return
}

# Write access for Everyone or Users means someone else can replace the binary
# after it is verified, which would make every check above decorative.
$worldSids = @(
    (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::WorldSid, $null)),
    (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null))
)
foreach ($ace in $acl.Access) {
    if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
    $sid = $null
    try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) } catch { continue }
    if ($worldSids -contains $sid) {
        if ($ace.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) {
            Err "$binDir grants write access to $($ace.IdentityReference)"
            Info "Remove that permission and re-run."
            return
        }
    }
}
Ok "Owned by you, no broad write access"
Write-Host ""

# --- Sweep leftovers (R10, R12) ---
# Every run clears both what an interrupted download staged and what a previous
# replace renamed aside.
Get-ChildItem -Path $binDir -Filter "$stagePrefix*" -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
if (Test-Path $sidecarPath) {
    # A failed delete here is tolerated on purpose: the old binary may still be
    # running, and it will be swept on the next run instead.
    Remove-Item $sidecarPath -Force -ErrorAction SilentlyContinue
}

# --- Stage the download (R10) ---
Step "Downloading"
# Staged inside the destination directory, never in a shared temp: %TEMP%
# staging would allow a swap between verification and placement, and a
# cross-volume move would not be atomic either.
$script:stagePath  = Join-Path $binDir "$stagePrefix$PID"
$script:sumsPath   = Join-Path $binDir "$stagePrefix$PID.sums"
$script:bundlePath = Join-Path $binDir "$stagePrefix$PID.sigstore.json"

$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile $script:stagePath -UseBasicParsing -ErrorAction Stop
} catch {
    Err "Download failed: $baseUrl/$asset"
    Remove-Stage
    $ProgressPreference = $oldProgress
    return
}
$ProgressPreference = $oldProgress
Ok "$asset ($(Format-Size (Get-Item $script:stagePath).Length))"
Write-Host ""

# --- Verify the checksum (R7) ---
# Verification that cannot be performed counts as verification failure. There
# is no "proceed without checking" path: the checksum is the fail-closed gate
# for the whole transport.
Step "Verifying checksum"
try {
    Invoke-WebRequest -Uri "$baseUrl/checksums.txt" -OutFile $script:sumsPath -UseBasicParsing -ErrorAction Stop
} catch {
    Err "Could not fetch checksums.txt"
    Remove-Stage
    return
}
$expected = $null
foreach ($line in (Get-Content $script:sumsPath)) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $asset) { $expected = $parts[0].Trim(); break }
}
if (-not $expected) {
    Err "checksums.txt has no entry for $asset"
    Remove-Stage
    return
}
$actual = $null
try { $actual = (Get-FileHash -Algorithm SHA256 $script:stagePath -ErrorAction Stop).Hash } catch {}
if (-not $actual) {
    Err "Could not compute a SHA-256 hash"
    Info "Cannot verify the download, so it will not be installed."
    Remove-Stage
    return
}
if ($actual.ToLower() -ne $expected.ToLower()) {
    Err "Checksum mismatch for $asset"
    Info "expected $expected"
    Info "actual   $actual"
    Remove-Stage
    return
}
Ok "SHA-256 matches"
Write-Host ""

# --- Verify the attestation (R8) ---
# Opportunistic but fail-closed when it runs: a negative result stops the
# install with or without --require-attestation; only the inability to verify is
# tolerated, and only without the flag.
Step "Verifying build provenance"
$attested = $false
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $gotBundle = $false
    try {
        Invoke-WebRequest -Uri "$baseUrl/$asset.sigstore.json" -OutFile $script:bundlePath `
            -UseBasicParsing -ErrorAction Stop
        $gotBundle = $true
    } catch {}
    if ($gotBundle) {
        # Verified against the downloaded bundle rather than the attestation
        # API: the API serves its bundle Snappy-compressed and needs an
        # authenticated gh, which is why the bundle ships as a release asset.
        & gh attestation verify $script:stagePath --bundle $script:bundlePath `
            --repo $repoSlug --signer-workflow $signerWorkflow 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $attested = $true
            Ok "Provenance verified (built by $signerWorkflow)"
        } else {
            Err "Attestation verification FAILED for $asset"
            Info "The download matched its checksum but does not carry a valid"
            Info "provenance attestation from this repository's release workflow."
            Info "Refusing to install."
            Remove-Stage
            return
        }
    } else {
        Warn "No attestation bundle published for this release"
    }
} else {
    Warn "gh CLI not found - provenance not verified"
}

if (-not $attested) {
    if ($requireAttestation) {
        Err "--require-attestation was given but provenance could not be verified"
        Remove-Stage
        return
    }
    Info "Verify manually later with:"
    Info "  gh attestation verify `"$binPath`" --repo $repoSlug --signer-workflow $signerWorkflow"
}
Write-Host ""

# --- Place the binary (R12) ---
# Windows will not let a running executable be deleted or overwritten, but it
# will let it be renamed. Renaming aside first is what makes an upgrade work
# while Claude Code is open.
Step "Installing"
if (Test-Path $binPath) {
    try {
        Move-Item -Path $binPath -Destination $sidecarPath -Force -ErrorAction Stop
    } catch {
        Err "Could not move the existing binary aside"
        Info "Close Claude Code and re-run."
        Remove-Stage
        return
    }
}
try {
    Move-Item -Path $script:stagePath -Destination $binPath -Force -ErrorAction Stop
    $script:stagePath = $null
} catch {
    Err "Could not place the binary at $binPath"
    # Put the previous installation back rather than leaving nothing behind.
    if (Test-Path $sidecarPath) { Move-Item -Path $sidecarPath -Destination $binPath -Force -ErrorAction SilentlyContinue }
    Remove-Stage
    return
}
Remove-Item $script:sumsPath, $script:bundlePath -Force -ErrorAction SilentlyContinue
Ok $binPath
Info (Format-Size (Get-Item $binPath).Length)
Write-Host ""

# --- Self-check (R11, AE8) ---
# A binary can pass its checksum, launch, and still render wrongly -- a bad
# build, a corrupt fixture, an architecture that runs but misbehaves. The
# silent-degradation contract guarantees that failure would reach the user as an
# absent status line and nothing else, so this is the only place it can be
# caught. Everything destructive below is gated on it, and the sidecar stays
# where it is until it passes.
Step "Verifying the binary renders"
& $binPath self-check 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Err "The installed binary failed its self-check"
    Info "It downloaded and verified but does not render correctly, so it was"
    Info "not activated. Your previous installation is untouched."
    Remove-Item $binPath -Force -ErrorAction SilentlyContinue
    if (Test-Path $sidecarPath) { Move-Item -Path $sidecarPath -Destination $binPath -Force -ErrorAction SilentlyContinue }
    Remove-Stage
    return
}
# Tolerated failure by design: the old binary may still be running, and the next
# run sweeps whatever is left.
if (Test-Path $sidecarPath) { Remove-Item $sidecarPath -Force -ErrorAction SilentlyContinue }
Ok "Renders correctly"
Write-Host ""

# --- Migrate from a script installation (R16, F2) ---
# Only now, with a binary that has proved it renders. notify-config.json is
# deliberately not in this list: it is the user's configuration, its schema is
# unchanged, and the binary reads it as-is (R44).
$legacyScripts = @('statusline.ps1', 'notify.ps1', 'git-refresh.ps1', 'subagent-statusline.ps1')
$legacyFound = @($legacyScripts | Where-Object { Test-Path (Join-Path $claudeDir $_) })
if ($legacyFound.Count -gt 0) {
    Step "Removing the superseded scripts"
    foreach ($name in $legacyFound) {
        $path = Join-Path $claudeDir $name
        try {
            Remove-Item $path -Force -ErrorAction Stop
            Ok $name
        } catch {
            Warn "Could not remove $path"
        }
    }
    Info "Your notification settings were kept."
    Write-Host ""
}

# --- Configure settings.json (R14) ---
# The bare path is passed deliberately. R14 requires the stored command to be
# quoted, but quoting it here does not survive: PowerShell consumes the
# surrounding quotes of a pre-quoted argument as delimiters, so the binary would
# receive a bare path anyway and write an unquoted command. The binary adds the
# quotes on its own side, where no shell can eat them.
Step "Configuring Claude Code settings"
$applyFlags = @()

& $binPath settings has-foreign --binary $binPath statusline | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Existing statusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET})"
    if ($answer -match '^[Yy]$') { $applyFlags += '--statusline' }
    else { Warn "Skipped statusLine update"; Info "Continuing with hook and notification setup..." }
    Write-Host ""
} else {
    $applyFlags += '--statusline'
}

& $binPath settings has-foreign --binary $binPath subagent | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Existing subagentStatusLine config found. Overwrite? (${GREEN}y${RESET}/${RED}n${RESET})"
    if ($answer -match '^[Yy]$') { $applyFlags += '--subagent' } else { Warn "Skipped subagentStatusLine update" }
    Write-Host ""
} else {
    $applyFlags += '--subagent'
}

# Live git status. Always on: not a notification, no prompt today, and it costs
# nothing when idle.
$applyFlags += '--git-refresh'

# --- Notification configuration (R15, R44) ---
Write-Host ""
Step "Notification configuration"
if (Test-Path $configPath) {
    Ok "Config already exists (preserving)"
    Info $configPath
} else {
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
    [System.IO.File]::WriteAllText($configPath, $defaultConfig, (New-Object System.Text.UTF8Encoding $false))
    Ok "Created default config"
    Info $configPath
}

Write-Host ""
Step "Notifications"
Info "Plays a sound and shows a popup when Claude needs attention."
# The legacy check is what carries the choice across an upgrade (R16): someone
# who enabled notifications under the scripts has hooks pointing at notify.ps1,
# which `has` does not recognise, and re-prompting them would turn a silent
# upgrade into a question they already answered.
& $binPath settings has --binary $binPath notify | Out-Null
$notifyConfigured = ($LASTEXITCODE -eq 0)
if (-not $notifyConfigured) {
    & $binPath settings has-legacy --binary $binPath notify | Out-Null
    $notifyConfigured = ($LASTEXITCODE -eq 0)
}
if ($notifyConfigured) {
    Ok "Already configured"
    $applyFlags += '--notify'
} else {
    Write-Host ""
    $answer = Read-Host "  ${YELLOW}${BOLD} ?${RESET} Enable notifications? (${GREEN}y${RESET}/${RED}n${RESET})"
    if ($answer -match '^[Yy]$') { $applyFlags += '--notify' }
    else { Info "Skipped - run the installer again to enable later" }
}

# --- Notification icon ---
if (-not (Test-Path $iconPath)) {
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repoSlug/master/assets/claude-icon.png" `
            -OutFile $iconPath -UseBasicParsing -ErrorAction Stop
        Ok "Icon installed"
    } catch {}
}

# --- Apply ---
Write-Host ""
$applyOutput = & $binPath settings apply --binary $binPath @applyFlags 2>&1
if ($LASTEXITCODE -ne 0) {
    Err "Failed to update settings.json"
    if ($applyOutput) { Info ($applyOutput -join ' ') }
    Info "The binary is installed at $binPath but Claude Code is not pointing at it yet."
    return
}
Ok "Updated $settingsPath"

Write-Host ""
Write-Host "  ${GRAY}-----------------------------------------${RESET}"
Write-Host "  ${GREEN}${BOLD}Done!${RESET} Restart Claude Code to activate."
Write-Host ""
