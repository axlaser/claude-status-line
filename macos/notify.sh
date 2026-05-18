#!/usr/bin/env bash
case "${1:-}" in
    permission) afplay /System/Library/Sounds/Tink.aiff 2>/dev/null ;;
    stop)       afplay /System/Library/Sounds/Glass.aiff 2>/dev/null ;;
esac
