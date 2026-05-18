#Requires -Version 5.1
param([string]$Event)
switch ($Event) {
    'permission' { [System.Media.SystemSounds]::Exclamation.Play() }
    'stop'       { [System.Media.SystemSounds]::Asterisk.Play() }
}
Start-Sleep -Milliseconds 300
