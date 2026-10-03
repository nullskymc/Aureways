#!/bin/zsh
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "${DEVELOPER_DIR:-}" ]; then
    CURRENT_DEV="$(xcode-select -p 2>/dev/null || true)"
    if [ ! -d "$CURRENT_DEV" ] || [[ "$CURRENT_DEV" == *CommandLineTools* ]]; then
        for CANDIDATE in \
            /Applications/Xcode.app \
            /Applications/Xcode-beta.app \
            /Volumes/Data/Applications/Xcode.app \
            /Volumes/Data/Applications/Xcode-beta.app \
            /Volumes/app/Applications/Xcode.app \
            /Volumes/app/Applications/Xcode-beta.app; do
            if [ -d "$CANDIDATE/Contents/Developer" ]; then
                export DEVELOPER_DIR="$CANDIDATE/Contents/Developer"
                break
            fi
        done
    fi
fi

exec make test
