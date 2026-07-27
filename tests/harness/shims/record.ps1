# Recording stand-in installed at the isolated HOME's .claude\notify.ps1.
#
# On Windows the status line's notification spawn is the observable, and it is
# addressed by path rather than through PATH -- the script runs
# "$env:USERPROFILE\.claude\notify.ps1". Because the harness owns USERPROFILE
# during a capture, replacing that file records the spawn field-by-field,
# which the powershell.cmd PATH shim cannot do without re-parsing quotes.
#
# Records one line per invocation into $env:STATUSLINE_CAPTURE_FILE:
#
#     notify.ps1<TAB><arg><TAB><arg>...
#
# Arguments are backslash-escaped so a newline or tab inside one cannot forge a
# record boundary, matching shims/record.sh byte for byte in its output shape.

param([Parameter(ValueFromRemainingArguments = $true)] $Rest)

function Format-Arg($value) {
    $s = [string]$value
    $s = $s -replace '\\', '\\'
    $s = $s -replace "`n", '\n'
    $s = $s -replace "`r", '\r'
    $s = $s -replace "`t", '\t'
    return $s
}

$fields = @('notify.ps1')
if ($null -ne $Rest) {
    foreach ($arg in @($Rest)) { $fields += (Format-Arg $arg) }
}
$line = [string]::Join("`t", $fields)

$capture = $env:STATUSLINE_CAPTURE_FILE
if ($capture) {
    # A shared read/append handle rather than Add-Content: the status line
    # backgrounds this spawn, so two recorders can be live at once and a
    # cmdlet that opens the file exclusively would drop one of them.
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $stream = [System.IO.File]::Open(
                $capture,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.WriteLine($line)
            $writer.Flush()
            $writer.Dispose()
            break
        } catch {
            Start-Sleep -Milliseconds 20
        }
    }
}
