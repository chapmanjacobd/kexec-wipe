#!/bin/bash
# Common utilities for kexec-wipe

set -euo pipefail

WIPE_TMPDIR=""
CLEANUP_DONE=0

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
fatal()   { error "$*"; exit 1; }

confirm() {
    local msg="$1"
    echo -e "${BOLD}${YELLOW}WARNING: ${msg}${RESET}"
    echo ""
    read -rp "Type YES to continue: " answer
    if [ "$answer" != "YES" ]; then
        info "Aborted by user."
        exit 1
    fi
}

make_tmpdir() {
    WIPE_TMPDIR=$(mktemp -d /tmp/kexec-wipe.XXXXXX)
}

cleanup() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    if [ -n "$WIPE_TMPDIR" ] && [ -d "$WIPE_TMPDIR" ]; then
        rm -rf "$WIPE_TMPDIR"
    fi
}

trap cleanup EXIT

bytes_to_human() {
    local bytes=$1
    local human
    human=$(awk "BEGIN { b=$bytes; if (b>=1099511627776) printf \"%.2f TB\", b/1099511627776; else if (b>=1073741824) printf \"%.2f GB\", b/1073741824; else if (b>=1048576) printf \"%.2f MB\", b/1048576; else printf \"%d B\", b }")
    echo "$human"
}
