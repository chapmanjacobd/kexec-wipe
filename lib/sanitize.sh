#!/bin/bash
# NVMe sanitize operations with crypto-erase, block-erase, and overwrite

SANITIZE_METHOD=""

try_crypto_erase() {
    local dev="$1"
    info "Attempting crypto-erase on $dev..."

    if nvme sanitize "$dev" -a start-crypto-erase 2>/dev/null; then
        SANITIZE_METHOD="crypto-erase"
        return 0
    fi

    warn "Crypto-erase failed or not supported."
    return 1
}

try_block_erase() {
    local dev="$1"
    info "Attempting block-erase on $dev..."

    if nvme sanitize "$dev" -a start-block-erase 2>/dev/null; then
        SANITIZE_METHOD="block-erase"
        return 0
    fi

    error "Block-erase also failed."
    return 1
}

try_overwrite() {
    local dev="$1"
    info "Attempting overwrite on $dev (this may take a while)..."

    if nvme sanitize "$dev" -a start-overwrite 2>/dev/null; then
        SANITIZE_METHOD="overwrite"
        return 0
    fi

    error "Overwrite also failed."
    return 1
}

# Query the NVMe sanitize log and echo the sanitize state: one of "success",
# "in-progress", "failure", or "none". Returns 1 if the log could not be read.
#
# The drive's own sanitize-log output is forwarded to the terminal verbatim and
# only the stable human-readable "(SSTAT)" line is parsed for the state.
# nvme-cli's JSON layout is not stable across versions (1.x nests sstat as an
# object whose status is a human-readable string, 2.x emits flat integers), so
# JSON is not parsed.
#
# NOTE: This whole function is intentionally duplicated in initramfs/init.
# This library runs under bash on the host (assembled into wipe.sh), while
# initramfs/init runs under busybox ash in the in-memory environment, so the two
# cannot share code. Keep both copies identical when changing the SSTAT parsing.
sanitize_log_state() {
    local dev="$1"
    local out sstat status

    out=$(nvme sanitize-log "$dev" 2>&1) || return 1
    printf '%s\n' "$out" >&2

    sstat=$(printf '%s\n' "$out" | sed -n 's/.*(SSTAT)[[:space:]]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
    [ -n "$sstat" ] || return 1

    # SSTAT status is in bits [2:0]: 0x1 success, 0x2 in progress,
    # 0x3 failure, 0x4 no-deallocate success. Values may be hex ("0x..");
    # bash arithmetic interprets the "0x" prefix directly.
    status=$((sstat & 0x7))
    case "$status" in
        1|4) echo "success" ;;
        2)   echo "in-progress" ;;
        3)   echo "failure" ;;
        *)   echo "none" ;;   # never sanitized / no status yet
    esac
}

wait_for_sanitize() {
    local dev="$1"
    local timeout="${2:-7200}"
    local elapsed=0
    local interval=5

    info "Waiting for sanitize to complete (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local state
        state=$(sanitize_log_state "$dev") || state="none"

        case "$state" in
            success)
                success "Sanitize completed successfully ($SANITIZE_METHOD)."
                return 0
                ;;
            failure)
                error "Sanitize completed with failure."
                return 1
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    error "Sanitize timed out after ${timeout}s."
    return 1
}

do_sanitize() {
    local dev="$1"
    local method="${2:-auto}"

    case "$method" in
        crypto)
            try_crypto_erase "$dev" || fatal "Crypto-erase failed."
            ;;
        block)
            try_block_erase "$dev" || fatal "Block-erase failed."
            ;;
        overwrite)
            try_overwrite "$dev" || fatal "Overwrite failed."
            ;;
        auto|"")
            try_crypto_erase "$dev" || try_block_erase "$dev" || fatal "All sanitize methods failed."
            ;;
        *)
            fatal "Unknown sanitize method: $method (use: crypto, block, overwrite, auto)"
            ;;
    esac

    if ! wait_for_sanitize "$dev" 7200; then
        fatal "Sanitize operation did not complete successfully."
    fi

    success "Device $dev has been sanitized ($SANITIZE_METHOD)."
}
