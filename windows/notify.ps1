param([string]$Event)
switch ($Event) {
    'permission' { [System.Media.SystemSounds]::Exclamation.Play() }
    'stop'       { [System.Media.SystemSounds]::Asterisk.Play() }
}
