#!/bin/bash
#
# kexec-wipe - Securely wipe NVMe drives
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/xk/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
#
# This file is assembled by build.sh from lib/*.sh modules.
# For development, edit the files in lib/ and run ./build.sh.
#
set -euo pipefail

WIPE_VERSION="0.1.0"

# --- begin lib/common.sh ---
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
# --- end lib/common.sh ---

# --- begin lib/sanity.sh ---
#!/bin/bash
# Sanity checks and device validation for kexec-wipe

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fatal "This script must be run as root."
    fi
}

validate_device() {
    local dev="$1"

    if [ ! -b "$dev" ]; then
        fatal "Device '$dev' does not exist or is not a block device."
    fi

    local devname
    devname=$(basename "$dev")
    if [[ ! "$devname" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        fatal "Device '$dev' is not an NVMe namespace (expected pattern nvmeXnY)."
    fi
}

get_nvme_ctrl() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")
    echo "${devname%%n[0-9]*}"
}

get_device_info() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    local model="" serial="" size_bytes=""

    model=$(nvme id-ctrl "$dev" -o xml 2>/dev/null | sed -n 's/.*<mn>\(.*\)<\/mn>.*/\1/p' | head -1) || true
    serial=$(nvme id-ctrl "$dev" -o xml 2>/dev/null | sed -n 's/.*<sn>\(.*\)<\/sn>.*/\1/p' | head -1) || true
    size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null) || true

    # Fallbacks via sysfs
    [ -z "$model" ] && model=$(cat "/sys/block/$devname/device/model" 2>/dev/null | xargs) || true
    [ -z "$serial" ] && serial=$(cat "/sys/block/$devname/device/serial" 2>/dev/null | xargs) || true

    local size_human=""
    if [ -n "$size_bytes" ]; then
        size_human=$(bytes_to_human "$size_bytes")
    fi

    echo "Model:    ${model:-unknown}"
    echo "Serial:   ${serial:-unknown}"
    echo "Size:     ${size_human:-unknown}"
    echo "Path:     $dev"
}

is_root_device() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    # Get the device name of the root filesystem (strip partition number)
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || return 1
    root_dev=$(basename "$root_dev")
    root_dev="${root_dev%%[0-9]*}"

    [ "$root_dev" = "$devname" ]
}
# --- end lib/sanity.sh ---

# --- begin lib/unmount.sh ---
#!/bin/bash
# Unmount and detach all consumers of a block device

unmount_device() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    info "Unmounting partitions on $dev..."

    # Unmount deepest paths first (longest mount point first)
    local mounts
    mounts=$(findmnt -rno TARGET "/dev/$devname" 2>/dev/null \
        | awk '{ print length, $0 }' | sort -rn | awk '{ $1=""; print }' | xargs) || true

    if [ -n "$mounts" ]; then
        for tgt in $mounts; do
            [ -z "$tgt" ] && continue
            info "  Unmounting $tgt"
            umount -f "$tgt" 2>/dev/null || umount -l "$tgt" 2>/dev/null || true
        done
    fi

    # Also check the device itself
    if mount | grep -q "^$dev "; then
        info "  Unmounting $dev"
        umount -f "$dev" 2>/dev/null || umount -l "$dev" 2>/dev/null || true
    fi
}

deactivate_swap() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    info "Deactivating swap on $dev..."
    swapoff "/dev/$devname"* 2>/dev/null || true
}

remove_lvm() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    if ! command -v vgchange &>/dev/null; then
        return
    fi

    info "Checking for LVM volumes on $dev..."

    local pvs_output
    pvs_output=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | grep "/$devname" || true)

    if [ -n "$pvs_output" ]; then
        while IFS= read -r line; do
            local vg_name
            vg_name=$(echo "$line" | awk '{print $2}')
            [ -z "$vg_name" ] && continue
            info "  Deactivating VG: $vg_name"
            vgchange -an "$vg_name" 2>/dev/null || true
        done <<< "$pvs_output"
    fi
}

remove_raid() {
    local dev="$1"

    if ! command -v mdadm &>/dev/null; then
        return
    fi

    info "Checking for MD RAID on $dev..."

    local md_paths
    md_paths=$(cat /proc/mdstat 2>/dev/null | grep "$(basename "$dev")" | awk '{print $1}' || true) || true

    if [ -n "$md_paths" ]; then
        for md in $md_paths; do
            info "  Stopping MD array: /dev/$md"
            mdstop "/dev/$md" 2>/dev/null || true
        done
    fi
}

detach_device() {
    local dev="$1"

    info "Detaching device $dev from all consumers..."

    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    deactivate_swap "$dev"
    remove_lvm "$dev"
    remove_raid "$dev"
    unmount_device "$dev"
}
# --- end lib/unmount.sh ---

# --- begin lib/sanitize.sh ---
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
# --- end lib/sanitize.sh ---

# --- begin lib/kexec.sh ---
#!/bin/bash
# kexec-based approach for sanitizing the root device

INITRAMFS_VERSION="v0.1.0"
INITRAMFS_BASE_URL="https://github.com/xk/kexec-wipe/releases/download"
INITRAMFS_FILE="kexec-wipe-initramfs-${INITRAMFS_VERSION}.cpio.gz"

check_kexec() {
    if ! command -v kexec &>/dev/null; then
        fatal "kexec is required for root disk sanitization but was not found.
Install it with your package manager (e.g., 'apt install kexec-tools' or 'dnf install kexec-tools')."
    fi
}

download_initramfs() {
    local dest="$1"
    local url="${INITRAMFS_BASE_URL}/${INITRAMFS_VERSION}/${INITRAMFS_FILE}"

    info "Downloading initramfs from ${url}..."

    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest" || fatal "Failed to download initramfs."
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest" || fatal "Failed to download initramfs."
    else
        fatal "Neither curl nor wget is available to download the initramfs."
    fi

    if [ ! -s "$dest" ]; then
        fatal "Downloaded initramfs is empty."
    fi

    success "Initramfs downloaded ($(bytes_to_human "$(stat -c%s "$dest")"))."
}

find_kernel() {
    local kver
    kver=$(uname -r)

    local candidates=(
        "/boot/vmlinuz-${kver}"
        "/boot/kernel-${kver}"
        "/boot/bzImage-${kver}"
        "/boot/vmlinux-${kver}"
        "/vmlinuz-${kver}"
    )

    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    fatal "Could not find kernel image for ${kver}. Searched: ${candidates[*]}"
}

do_kexec_wipe() {
    local dev="$1"
    local method="${2:-auto}"

    check_kexec

    make_tmpdir
    local initramfs_path="${WIPE_TMPDIR}/${INITRAMFS_FILE}"

    download_initramfs "$initramfs_path"

    local kernel
    kernel=$(find_kernel)
    info "Using kernel: $kernel"

    local cmdline="root=/dev/ram rw quiet panic=10"
    cmdline="${cmdline} kexec_wipe_dev=${dev}"
    cmdline="${cmdline} kexec_wipe_method=${method}"

    info "Loading kernel into memory..."
    info "  Kernel:    $kernel"
    info "  Initramfs: $initramfs_path"
    info "  Target:    $dev"

    kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" \
        || fatal "Failed to load kernel into memory via kexec."

    success "Kernel loaded. System will now kexec into minimal environment."
    warn "THE SYSTEM WILL REBOOT MOMENTARILY. Any unsaved work will be lost."
    echo ""

    sleep 3

    sync
    kexec -e || fatal "kexec -e failed. System may need manual reboot."
}
# --- end lib/kexec.sh ---

#!/bin/bash

usage() {
    cat <<EOF
kexec-wipe - Securely wipe NVMe drives

Usage:
  curl -sL https://raw.githubusercontent.com/xk/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
  sudo ./wipe.sh /dev/nvme0n1 [OPTIONS]

Arguments:
  /dev/nvmeXnY          Target NVMe device to sanitize

Options:
  --method=METHOD       Sanitize method (default: auto)
                        auto       - Try crypto-erase, fallback to block-erase
                        crypto     - Crypto-erase only (fastest for SED drives)
                        block      - Block-erase only
                        overwrite  - Overwrite (slowest, most thorough)
  --dry-run             Show what would be done without making changes
  --help                Show this help message

Examples:
  sudo bash wipe.sh /dev/nvme0n1
  sudo bash wipe.sh /dev/nvme0n1 --method=block
  sudo bash wipe.sh /dev/nvme0n1 --dry-run

How it works:
  Non-root disk: unmounts partitions, runs nvme sanitize directly.
  Root disk: kexec's into a minimal in-memory environment to sanitize
  without any mounted filesystems, then reboots.
EOF
}

parse_args() {
    TARGET_DEVICE=""
    METHOD="auto"
    DRY_RUN=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --method=*)
                METHOD="${1#--method=}"
                case "$METHOD" in
                    auto|crypto|block|overwrite) ;;
                    *) fatal "Invalid method: $METHOD (use: auto, crypto, block, overwrite)" ;;
                esac
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            /*)
                TARGET_DEVICE="$1"
                ;;
            *)
                fatal "Unknown argument: $1"
                ;;
        esac
        shift
    done

    if [ -z "$TARGET_DEVICE" ]; then
        error "No target device specified."
        echo ""
        usage
        exit 1
    fi
}

print_banner() {
    echo ""
    echo -e "${BOLD}kexec-wipe v${WIPE_VERSION}${RESET}"
    echo -e "${BOLD}Secure NVMe Drive Sanitization${RESET}"
    echo ""
}

main() {
    parse_args "$@"

    print_banner
    check_root
    validate_device "$TARGET_DEVICE"

    # Non-root path needs nvme-cli on the host; root path gets it from initramfs
    local is_root=0
    if is_root_device "$TARGET_DEVICE"; then
        is_root=1
    else
        if ! command -v nvme &>/dev/null; then
            fatal "nvme-cli is required but not found. Install it with your package manager."
        fi
    fi

    if [ "$is_root" -eq 1 ]; then
        warn "TARGET DEVICE IS THE ROOT DISK!"
        warn "This will kexec into a minimal environment to sanitize."
        warn "THE SYSTEM WILL REBOOT as part of this process."
    fi

    echo -e "${BOLD}Device Information:${RESET}"
    get_device_info "$TARGET_DEVICE"
    echo ""

    local method_display="$METHOD"
    [ "$method_display" = "auto" ] && method_display="auto (crypto-erase -> block-erase)"
    echo -e "${BOLD}Sanitize method:${RESET} $method_display"
    echo ""

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN - no changes will be made."
        if [ "$is_root" -eq 1 ]; then
            info "Would kexec into minimal environment and sanitize $TARGET_DEVICE."
        else
            info "Would unmount all partitions on $TARGET_DEVICE and sanitize."
        fi
        exit 0
    fi

    confirm "You are about to PERMANENTLY SANITIZE $TARGET_DEVICE. All data will be destroyed."

    if [ "$is_root" -eq 1 ]; then
        do_kexec_wipe "$TARGET_DEVICE" "$METHOD"
    else
        detach_device "$TARGET_DEVICE"
        do_sanitize "$TARGET_DEVICE" "$METHOD"
    fi
}

main "$@"
