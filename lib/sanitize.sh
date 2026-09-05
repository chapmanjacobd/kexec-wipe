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

# Query the NVMe sanitize log and echo "<state> <progress>", where <state> is
# one of: in-progress, success, failure, none. <progress> is the raw SPROG
# value (0-65535). Returns 1 if the log could not be read.
#
# NOTE: This whole function is intentionally duplicated in initramfs/init.
# This library runs under bash on the host (assembled into wipe.sh), while
# initramfs/init runs under busybox sh in the in-memory environment, so the two
# cannot share code. Keep both copies identical when changing the SPROG/SSTAT
# parsing.
sanitize_log_state() {
    local dev="$1"
    local log sprog sstat status

    log=$(nvme sanitize-log "$dev" -o json 2>/dev/null) || return 1

    # Extract SPROG/SSTAT robustly. nvme-cli versions differ: some emit flat
    # decimal integers, some hex ("0x.."), and 1.x nests sstat as an object with
    # a human-readable "status" string. The awk handles all three forms. Values
    # may be hex; bash arithmetic interprets the "0x" prefix directly.
    read -r sprog sstat <<EOF
$(printf '%s' "$log" | awk '
    BEGIN { sprog=""; sstat=""; instat=0 }
    {
        line=$0
        if (sprog=="" && match(line, /"sprog"[^0-9a-fA-Fx]*((0x[0-9a-fA-F]+)|([0-9]+))/) ) {
            v=substr(line,RSTART,RLENGTH); sub(/^"sprog"[^0-9a-fA-Fx]*/,"",v); sprog=v
        }
        if (match(line, /"sstat"[ \t]*:/)) {
            tail=substr(line,RSTART+RLENGTH)
            if (tail ~ /^[ \t]*\{/) {
                instat=1
            } else if (sstat=="" && match(tail, /^[ \t]*((0x[0-9a-fA-F]+)|([0-9]+))/) ) {
                v=substr(tail,RSTART,RLENGTH); sub(/^[ \t]*/,"",v); sstat=v; instat=0
            }
        }
        if (instat==1 && sstat=="" && match(line, /"status"[^0-9a-fA-Fx]*((0x[0-9a-fA-F]+)|([0-9]+))/) ) {
            v=substr(line,RSTART,RLENGTH); sub(/^"status"[^0-9a-fA-Fx]*/,"",v); sstat=v; instat=0
        }
    }
    END { print sprog, sstat }
')
EOF

    [ -n "$sstat" ] || return 1
    [ -n "$sprog" ] || sprog=0

    # SSTAT status is in bits [2:0]: 0x1 success, 0x2 in progress,
    # 0x3 failure, 0x4 no-deallocate success.
    status=$((sstat & 0x7))
    case "$status" in
        1|4) echo "success $sprog" ;;
        2)   echo "in-progress $sprog" ;;
        3)   echo "failure $sprog" ;;
        *)   echo "none $sprog" ;;   # never sanitized / no status yet
    esac
}

wait_for_sanitize() {
    local dev="$1"
    local timeout="${2:-7200}"
    local elapsed=0
    local interval=5

    info "Waiting for sanitize to complete (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local state progress result
        result=$(sanitize_log_state "$dev") || result="none 0"
        state=${result%% *}
        progress=${result#* }

        case "$state" in
            in-progress)
                local pct=0
                # SPROG is a fraction of 0x10000 (65536); progress is its numerator.
                pct=$(( progress * 100 / 65536 ))
                printf "\r  Sanitizing... %d%% " "$pct"
                ;;
            success)
                echo ""
                success "Sanitize completed successfully ($SANITIZE_METHOD)."
                return 0
                ;;
            failure)
                echo ""
                error "Sanitize completed with failure."
                return 1
                ;;
            none|*)
                # No sanitize reported yet: the command may just have started and
                # the controller has not updated the log. Keep polling.
                if [ "$elapsed" -eq 0 ]; then
                    echo ""
                    warn "No sanitize reported in progress yet."
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

    success "Device $dev has been sanitized ($SANITIZE_METHOD)."
}
