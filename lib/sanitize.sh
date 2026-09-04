#!/bin/bash
# NVMe sanitize operations with crypto-erase fallback to block-erase

SANITIZE_METHOD=""

try_crypto_erase() {
    local dev="$1"
    info "Attempting crypto-erase on $dev..."

    if nvme sanitize "$dev" -a start-crypto-erase -f 2>/dev/null; then
        SANITIZE_METHOD="crypto-erase"
        return 0
    fi

    warn "Crypto-erase failed or not supported."
    return 1
}

try_block_erase() {
    local dev="$1"
    info "Attempting block-erase on $dev..."

    if nvme sanitize "$dev" -a start-block-erase -f 2>/dev/null; then
        SANITIZE_METHOD="block-erase"
        return 0
    fi

    error "Block-erase also failed."
    return 1
}

try_overwrite() {
    local dev="$1"
    info "Attempting overwrite on $dev (this may take a while)..."

    if nvme sanitize "$dev" -a start-overwrite -f 2>/dev/null; then
        SANITIZE_METHOD="overwrite"
        return 0
    fi

    error "Overwrite also failed."
    return 1
}

wait_for_sanitize() {
    local dev="$1"
    local timeout="${2:-7200}"
    local elapsed=0
    local interval=5

    info "Waiting for sanitize to complete (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status=$(nvme sanitize -H "$dev" -o xml 2>/dev/null) || true

        local san_stat
        san_stat=$(echo "$status" | sed -n 's/.*<stat>\(.*\)<\/stat>.*/\1/p' | head -1) || true

        local progress
        progress=$(echo "$status" | sed -n 's/.*<sprog>\(.*\)<\/sprog>.*/\1/p' | head -1) || true

        # sprog is in 0.01% increments (0-10000)
        local pct="0"
        if [ -n "$progress" ]; then
            pct=$((progress / 100))
        fi

        case "$san_stat" in
            0x01)
                printf "\r  Sanitizing... %d%% " "$pct"
                ;;
            0x02)
                echo ""
                success "Sanitize completed successfully ($SANITIZE_METHOD)."
                return 0
                ;;
            0x03)
                echo ""
                error "Sanitize completed with failure."
                return 1
                ;;
            0x04)
                if [ "$elapsed" -eq 0 ]; then
                    echo ""
                    warn "No sanitize in progress. Checking previous result..."
                    local prev_stat
                    prev_stat=$(echo "$status" | sed -n 's/.*<ssrc>\(.*\)<\/ssrc>.*/\1/p' | head -1) || true
                    if [ "$prev_stat" = "0x02" ]; then
                        success "Previous sanitize completed successfully."
                        return 0
                    fi
                fi
                ;;
            *)
                if [ "$elapsed" -gt 0 ]; then
                    printf "\r  Sanitizing... %d%% " "$pct"
                fi
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
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

    success "Drive $dev has been sanitized ($SANITIZE_METHOD)."
}
