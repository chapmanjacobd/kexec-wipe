#!/bin/bash
#
# kexec-wipe - Securely wipe NVMe drives
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
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

    # Get the device name of the root filesystem (strip partition suffix)
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || return 1
    root_dev=$(basename "$root_dev")
    # Use lsblk to find the parent (disk) device. This correctly handles
    # NVMe (nvme0n1p2 -> nvme0n1), mmcblk (mmcblk0p1 -> mmcblk0), and
    # traditional (sda1 -> sda) partition naming.
    local parent
    parent=$(lsblk -n -o PKNAME "/dev/$root_dev" 2>/dev/null | head -1) || true
    if [ -n "$parent" ]; then
        root_dev="$parent"
    else
        # Fallback: best-effort string stripping
        root_dev="${root_dev%%p[0-9]*}"
        root_dev="${root_dev%%[0-9]*}"
    fi

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

    # Unmount first so LVM/RAID teardown doesn't fail with "device is busy".
    unmount_device "$dev"
    deactivate_swap "$dev"
    remove_raid "$dev"
    remove_lvm "$dev"
}
# --- end lib/unmount.sh ---

# --- begin lib/sanitize.sh ---
#!/bin/bash
# NVMe sanitize operations with crypto-erase, block-erase, and overwrite

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
INITRAMFS_BASE_URL="https://github.com/chapmanjacobd/kexec-wipe/releases/download"
INITRAMFS_FILE="kexec-wipe-initramfs-${INITRAMFS_VERSION}.cpio.gz"

# Pinned Fedora Cloud Base raw image for --install-fedora.
# The xz filename and checksums are compose-specific, so they are pinned
# here (mirroring INITRAMFS_VERSION) and bumped by the maintainer per release.
INSTALL_FEDORA_RELEASE="44"
INSTALL_FEDORA_CURRENT="1.7"
INSTALL_FEDORA_BASE="https://download.fedoraproject.org/pub/fedora/linux/releases/${INSTALL_FEDORA_RELEASE}/Cloud"
INSTALL_FEDORA_SHA256_x86_64="7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953"
INSTALL_FEDORA_SHA256_aarch64="090d3cb07b266535ff81603d12cd143626caedc51be46977fef5f9161d5117b3"

fedora_raw_url() {
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch="aarch64" ;;
        *) arch="x86_64" ;;
    esac
    echo "${INSTALL_FEDORA_BASE}/${arch}/images/Fedora-Cloud-Base-AmazonEC2-${INSTALL_FEDORA_RELEASE}-${INSTALL_FEDORA_CURRENT}.${arch}.raw.xz"
}

fedora_raw_sha256() {
    case "$(uname -m)" in
        aarch64|arm64) echo "$INSTALL_FEDORA_SHA256_aarch64" ;;
        *) echo "$INSTALL_FEDORA_SHA256_x86_64" ;;
    esac
}

check_kexec() {
    if ! command -v kexec &>/dev/null; then
        fatal "kexec is required for root disk sanitization but not found.
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

# Download and verify the Fedora Cloud Base raw image on the host.
download_fedora_image() {
    local dest="$1"
    local url="${2:-$(fedora_raw_url)}"
    local expected="${3:-$(fedora_raw_sha256)}"

    info "Downloading Fedora Cloud Base from ${url}..."

    if command -v curl &>/dev/null; then
        curl -fsSL --retry 3 "$url" -o "$dest" || fatal "Failed to download Fedora image."
    elif command -v wget &>/dev/null; then
        wget -q -O "$dest" "$url" || fatal "Failed to download Fedora image."
    else
        fatal "Neither curl nor wget is available to download the Fedora image."
    fi

    if [ ! -s "$dest" ]; then
        fatal "Downloaded Fedora image is empty."
    fi

    local got
    got=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$got" != "$expected" ]; then
        fatal "Fedora image checksum mismatch (got $got, expected $expected)."
    fi

    success "Fedora image downloaded and verified ($(bytes_to_human "$(stat -c%s "$dest")"))."
}

# Embed a file into a copy of the initramfs cpio archive. The kernel-initramfs is
# itself an unpacked RAM filesystem, so appending a file to it makes that file
# available to the initramfs/init as if on disk. Prints the augmented initramfs
# path.
#
#   args: INITRAMFS_IN  (path to source cpio.gz)
#         EMBEDDED_PATH (absolute path the file should appear at in the initramfs)
#         FILE          (path to the file to embed)
#         [OUT]         (optional output path; defaults to <dir>/augmented.cpio.gz)
augment_initramfs() {
    local src="$1" path="$2" file="$3" out="${4:-}"
    local work

    [ -n "$out" ] || out="${src%.gz}.augmented.cpio.gz"

    work=$(mktemp -d /tmp/kexec-wipe-augment.XXXXXX)
    gzip -dc "$src" | ( cd "$work" && cpio -idm 2>/dev/null )

    local dest="$work/${path#/}"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"

    ( cd "$work" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$out" )

    rm -rf "$work"
}

# Federation finds a kernel image (optionally with its initrd) suitable for kexec.
# On classic setups this is vmlinuz + separate initrd, or a single UKI (Unified
# Kernel Image, common on aarch64) that embeds linux+initrd. Prints "<kernel> [initrd]".
find_kernel() {
    local kver
    kver=$(uname -r)

    local candidates=(
        "/boot/vmlinuz-${kver}"
        "/boot/kernel-${kver}"
        "/boot/bzImage-${kver}"
        "/boot/vmlinux-${kver}"
        "/vmlinuz-${kver}"
        "/boot/EFI/fedora/linux-${kver}.efi"
        "/boot/EFI/fedora/vmlinuz-${kver}"
    )

    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    fatal "Could not find kernel image for ${kver}. Searched: ${candidates[*]}"
}

# Locate the initrd (if any) accompanying a classic kernel image. UKIs embed
# their initrd, so nothing to return there.
find_initrd() {
    local kernel="$1"
    local kver
    kver=$(uname -r)

    # .efi is a UKI; the initrd is within the binary.
    case "$kernel" in
        *.efi) return 0 ;;
    esac

    local candidates=(
        "/boot/initramfs-${kver}.img"
        "/boot/initrd.img-${kver}"
        "/boot/initramfs-${kver}"
        "/initramfs-${kver}.img"
    )

    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    warn "No separate initrd found for ${kernel}; using kernel as-is (UKI assumes embedded initrd)."
}

do_kexec_wipe() {
    local dev="$1"
    local method="${2:-auto}"
    local install="${3:-0}"

    check_kexec

    make_tmpdir
    local initramfs_path="${WIPE_TMPDIR}/${INITRAMFS_FILE}"

    download_initramfs "$initramfs_path"

    # With --install-fedora, the Fedora image is downloaded on the host and
    # embedded into the initramfs. The image path is handed to the initramfs
    # via the kernel command line.
    if [ "$install" -eq 1 ]; then
        local fedora="${WIPE_TMPDIR}/fedora.raw.xz"
        download_fedora_image "$fedora"

        # Capture the host's hostname and authorized_keys for user provisioning.
        local host_hostname
        host_hostname=$(hostname)
        echo "$host_hostname" > "${WIPE_TMPDIR}/hostname"
        info "  Hostname:  $host_hostname"

        local auth_keys=""
        if [ -f "${HOME:-/root}/.ssh/authorized_keys" ]; then
            auth_keys="${HOME:-/root}/.ssh/authorized_keys"
        elif [ -f "/root/.ssh/authorized_keys" ]; then
            auth_keys="/root/.ssh/authorized_keys"
        fi
        if [ -n "$auth_keys" ] && [ -s "$auth_keys" ]; then
            cp "$auth_keys" "${WIPE_TMPDIR}/authorized_keys"
            info "  SSH keys:  $(wc -l < "${WIPE_TMPDIR}/authorized_keys") key(s) from $auth_keys"
        else
            warn "No authorized_keys found; SSH key access will not be configured."
            : > "${WIPE_TMPDIR}/authorized_keys"
        fi

        info "Embedding Fedora image into initramfs..."
        local augmented
        augmented=$(augment_initramfs "$initramfs_path" "/opt/fedora.raw.xz" "$fedora")
        augmented=$(augment_initramfs "$augmented" "/opt/kexec-wipe-hostname" "${WIPE_TMPDIR}/hostname")
        augmented=$(augment_initramfs "$augmented" "/opt/kexec-wipe-authorized_keys" "${WIPE_TMPDIR}/authorized_keys")
        initramfs_path="$augmented"
        info "  Augmented initramfs: $initramfs_path"
    fi

    local kernel
    kernel=$(find_kernel)
    info "Using kernel: $kernel"

    local cmdline="root=/dev/ram rw quiet panic=10"
    cmdline="${cmdline} kexec_wipe_dev=${dev}"
    cmdline="${cmdline} kexec_wipe_method=${method}"

    if [ "$install" -eq 1 ]; then
        cmdline="${cmdline} kexec_wipe_install=1"
        cmdline="${cmdline} kexec_wipe_fedora_image=/opt/fedora.raw.xz"
        info "  Install:    Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} (pre-downloaded) after wipe"
    fi

    # For a classic kernel, pass the separate initrd. For a UKI (.efi), the
    # initrd is embedded; no --initrd is needed.
    local initrd
    initrd=$(find_initrd "$kernel")

    info "Loading kernel into memory..."
    info "  Kernel:    $kernel"
    if [ -n "$initrd" ]; then
        info "  Initrd:    $initrd"
    else
        info "  Initrd:    (embedded in UKI)"
    fi
    info "  Initramfs: $initramfs_path"
    info "  Target:    $dev"

    if [ -n "$initrd" ]; then
        # Classic kernel: load with the wipe initramfs.
        kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" \
            || fatal "Failed to load kernel into memory via kexec."
    else
        # UKI (.efi): try loading the UKI with our initramfs directly. If kexec
        # cannot parse the PE, extract the embedded initrd (objcopy) and
        # concatenate it with ours.
        if kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" 2>/dev/null; then
            : # loaded UKI directly
        else
            local kinitrd="${WIPE_TMPDIR}/uki-initrd"
            info "Direct UKI load failed; extracting embedded initrd for a combined initramfs..."
            if extract_uki_initrd "$kernel" "$kinitrd"; then
                cat "$kinitrd" "$initramfs_path" > "${WIPE_TMPDIR}/combined-initrd"
            else
                cat "$initramfs_path" > "${WIPE_TMPDIR}/combined-initrd"
            fi
            kexec -l "$kernel" --initrd="${WIPE_TMPDIR}/combined-initrd" --command-line="$cmdline" \
                || fatal "Failed to load kernel into memory via kexec."
        fi
    fi

    success "Kernel loaded. System will now kexec into minimal environment."
    warn "THE SYSTEM WILL REBOOT MOMENTARILY. Any unsaved work will be lost."
    echo ""

    sleep 3

    sync
    kexec -e || fatal "kexec -e failed. System may need manual reboot."
}

# Extract the initrd payload from a UKI (.efi) file. UKIs are PE images with a
# .linux/.initrd section pair; objcopy can dump arbitrary sections.
extract_uki_initrd() {
    local uki="$1"
    local out="$2"

    if command -v objcopy &>/dev/null; then
        if objcopy --dump-section .initrd="$out" "$uki" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
        # Some UKIs use a different section name; fall through and warn.
        warn "Could not extract .initrd from UKI ${uki}."
    else
        warn "objcopy not available to extract UKI initrd."
    fi
    return 1
}
# --- end lib/kexec.sh ---

#!/bin/bash

usage() {
    cat <<EOF
kexec-wipe - Securely wipe NVMe drives

Usage:
  curl -sL https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
  sudo ./wipe.sh /dev/nvme0n1 [OPTIONS]

Arguments:
  /dev/nvmeXnY          Target NVMe device to sanitize

Options:
  --method=METHOD       Sanitize method (default: auto)
                        auto       - Try crypto-erase, then block-erase
                        crypto     - Crypto-erase only (fastest for SED drives)
                        block      - Block-erase only
                        overwrite  - Overwrite (slowest, most thorough)
  --dry-run             Show what would be done without making changes
  --install-fedora      After sanitizing the root disk via kexec, write a
                        Fedora Cloud Base image and install a bootloader so it
                        can boot. Requires the root-disk (kexec) path.
  --help                Show this help message

Examples:
  sudo bash wipe.sh /dev/nvme0n1
  sudo bash wipe.sh /dev/nvme0n1 --method=block
  sudo bash wipe.sh /dev/nvme0n1 --install-fedora
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
    INSTALL_FEDORA=0

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
            --install-fedora)
                INSTALL_FEDORA=1
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
        if [ "$INSTALL_FEDORA" -eq 1 ]; then
            fatal "--install-fedora requires targeting the root disk (it runs inside the kexec initramfs)."
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
    if [ "$INSTALL_FEDORA" -eq 1 ]; then
        echo -e "${BOLD}Install:${RESET} Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} (${INSTALL_FEDORA_CURRENT})"
    fi
    echo ""

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN - no changes will be made."
        if [ "$is_root" -eq 1 ]; then
            info "Would kexec into minimal environment and sanitize $TARGET_DEVICE."
            if [ "$INSTALL_FEDORA" -eq 1 ]; then
                info "Would then install Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} on $TARGET_DEVICE."
            fi
        else
            info "Would unmount all partitions on $TARGET_DEVICE and sanitize."
        fi
        exit 0
    fi

    confirm "You are about to PERMANENTLY SANITIZE $TARGET_DEVICE. All data will be destroyed."

    if [ "$is_root" -eq 1 ]; then
        do_kexec_wipe "$TARGET_DEVICE" "$METHOD" "$INSTALL_FEDORA"
    else
        detach_device "$TARGET_DEVICE"
        do_sanitize "$TARGET_DEVICE" "$METHOD"
    fi
}

main "$@"
