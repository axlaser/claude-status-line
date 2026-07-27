#Requires -Version 5.1
# Compatibility entry point. The real installer is install${action}.ps1; this
# path exists because it is the one the README has always published and a
# documented one-liner URL must keep working (R6).
#
# BOM-LESS and ASCII-ONLY, and no `exit` -- this is fetched with `irm | iex`
# and runs in the user's live session. See install\install.ps1.

$_selfDir = $null
if ($PSCommandPath) { $_selfDir = Split-Path -Parent $PSCommandPath }

$_local = $null
if ($_selfDir) { $_local = Join-Path $_selfDir "..\install${action}.ps1" }

if ($_local -and (Test-Path $_local)) {
    & $_local @args
} else {
    try {
        $_body = (Invoke-WebRequest -UseBasicParsing -ErrorAction Stop `
            -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/install/install.ps1").Content
    } catch {
        Write-Host "  Could not fetch install/install.ps1" -ForegroundColor Red
        return
    }
    Invoke-Expression $_body
}
