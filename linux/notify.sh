#!/usr/bin/env bash
play_sound() {
    local file="/usr/share/sounds/freedesktop/stereo/$1"
    if [ -f "$file" ]; then
        if command -v paplay &>/dev/null; then
            paplay "$file" 2>/dev/null
        elif command -v aplay &>/dev/null; then
            aplay "$file" 2>/dev/null
        else
            printf '\a'
        fi
    else
        printf '\a'
    fi
}

case "${1:-}" in
    permission) play_sound "bell.oga" ;;
    stop)       play_sound "complete.oga" ;;
esac
