#!/bin/bash
#
# kexec-wipe - Securely wipe NVMe drives
#
# Usage:
#   curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh
#   sudo bash wipe.sh /dev/nvme0n1
#
# This file is assembled by build.sh from lib/*.sh modules.
# For development, edit the files in lib/ and run ./build.sh.
#
set -euo pipefail

WIPE_VERSION="0.2.1"

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

    model=$(nvme id-ctrl "$dev" -o json 2>/dev/null | sed -n 's/.*"mn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || true
    serial=$(nvme id-ctrl "$dev" -o json 2>/dev/null | sed -n 's/.*"sn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || true
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

# Return 0 (true) if the given device is the disk backing the root filesystem.
# If the root device cannot be determined, it conservatively returns 0 so the
# caller picks the (safer) kexec wipe path rather than wiping a mounted disk in
# place.
is_root_device() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    # findmnt reports btrfs subvolume roots as "/dev/nvme0n1p3[/root]"; strip
    # the "[...]" suffix so the path is the plain block device.
    local src
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || return 0
    src="${src%%\[*\]}"

    if ! command -v lsblk >/dev/null 2>&1; then
        return 0
    fi

    # Walk up to the whole-disk device backing the root mount. A single lsblk
    # PKNAME hop is not enough when the root sits on a dm/partition (e.g. LVM
    # on nvme0n1p2), so walk until lsblk reports no further parent.
    local parent=""
    local node="$src"
    local hops=8
    while [ "$hops" -gt 0 ]; do
        local p
        p=$(lsblk -n -o PKNAME "$node" 2>/dev/null | head -1) || true
        [ -n "$p" ] || break
        parent="$p"
        node="/dev/$p"
        hops=$((hops - 1))
    done

    # If the root sits directly on a whole disk (no partition parent), the walk
    # breaks immediately and $src itself is the disk.
    if [ -z "$parent" ]; then
        parent=$(basename "$src")
    fi

    [ "$parent" = "$devname" ]
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

    # lsblk reports the mount points of the whole disk, every partition, and
    # each subvolume (e.g. "/" and "/home" from one btrfs partition) on separate
    # lines. findmnt on the whole-disk device does NOT enumerate child
    # partitions, so we use lsblk instead.
    local mounts
    mounts=$(lsblk -lno MOUNTPOINTS "/dev/$devname" 2>/dev/null | grep -E '^/' || true)

    # Unmount deepest paths first (longest mount point first)
    if [ -n "$mounts" ]; then
        local tgt
        for tgt in $(printf '%s\n' "$mounts" | awk '{ print length, $0 }' | sort -rn | awk '{ $1=""; print }'); do
            [ -z "$tgt" ] && continue
            info "  Unmounting $tgt"
            umount -f "$tgt" 2>/dev/null || umount -l "$tgt" 2>/dev/null || true
        done
    fi

    # Fallback if lsblk is unavailable: check the device node itself.
    if ! command -v lsblk >/dev/null 2>&1 && mount | grep -q "^$dev "; then
        info "  Unmounting $dev"
        umount -f "$dev" 2>/dev/null || umount -l "$dev" 2>/dev/null || true
    fi
}

deactivate_swap() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    info "Deactivating swap on $dev..."
    local part
    for part in /dev/"$devname"*; do
        [ -b "$part" ] || continue
        [ "$part" = "$dev" ] && continue
        swapoff "$part" 2>/dev/null || true
    done
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

    local md_paths=""
    # grep exits 1 when no array uses this disk; turn that into an empty list.
    md_paths=$(cat /proc/mdstat 2>/dev/null | grep "$(basename "$dev")" | awk '{print $1}') || md_paths=""

    if [ -n "$md_paths" ]; then
        for md in $md_paths; do
            info "  Stopping MD array: /dev/$md"
            mdadm --stop "/dev/$md" 2>/dev/null || true
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
    # Deactivate LVM before stopping MD arrays: an active VG on an MD member
    # keeps the array busy and mdadm --stop will fail until the VG is inactive.
    remove_lvm "$dev"
    remove_raid "$dev"
}
# --- end lib/unmount.sh ---

# --- begin lib/sanitize.sh ---
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
# --- end lib/sanitize.sh ---

# --- begin lib/kexec.sh ---
#!/bin/bash
# kexec-based approach for sanitizing the root device

# Explicit architecture-specific initramfs assets. Update the URLs and
# checksums together when the initramfs content or release changes.
INITRAMFS_URL_x86_64="https://github.com/chapmanjacobd/kexec-wipe/releases/download/v0.2.1/kexec-wipe-initramfs-x86_64.cpio.gz"
INITRAMFS_URL_aarch64="https://github.com/chapmanjacobd/kexec-wipe/releases/download/v0.2.1/kexec-wipe-initramfs-aarch64.cpio.gz"
INITRAMFS_SHA256_x86_64="f022a0edf8d32f5429ca81a050b34d1c2f88f880ccccfd017693d6c915d9d818"
INITRAMFS_SHA256_aarch64="9270f4f4ae77177c5824c760abc5ef3cf8171119927332df30687e45d5a1e94a"

# Pinned Fedora Cloud Base raw image for --install-fedora.
# Bumped by the maintainer per Fedora release.
INSTALL_FEDORA_RELEASE="44"
INSTALL_FEDORA_CURRENT="1.7"
INSTALL_FEDORA_BASE="https://download.fedoraproject.org/pub/fedora/linux/releases/${INSTALL_FEDORA_RELEASE}/Cloud"
INSTALL_FEDORA_SHA256_x86_64="7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953"
INSTALL_FEDORA_SHA256_aarch64="090d3cb07b266535ff81603d12cd143626caedc51be46977fef5f9161d5117b3"

platform_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo "aarch64" ;;
        x86_64|amd64) echo "x86_64" ;;
        *) fatal "Unsupported architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
    esac
}

# Fail fast if the running architecture is unsupported. The return value is 0
# on success (unsupported arches make platform_arch fatal), so callers use this
# purely to validate before any destructive action.
check_arch() {
    platform_arch >/dev/null
}

initramfs_file() {
    case "$(platform_arch)" in
        aarch64) echo "kexec-wipe-initramfs-aarch64.cpio.gz" ;;
        *) echo "kexec-wipe-initramfs-x86_64.cpio.gz" ;;
    esac
}

initramfs_url() {
    case "$(platform_arch)" in
        aarch64) echo "$INITRAMFS_URL_aarch64" ;;
        *) echo "$INITRAMFS_URL_x86_64" ;;
    esac
}

initramfs_sha256() {
    case "$(platform_arch)" in
        aarch64) echo "$INITRAMFS_SHA256_aarch64" ;;
        *) echo "$INITRAMFS_SHA256_x86_64" ;;
    esac
}

fedora_raw_url() {
    local arch
    arch=$(platform_arch)
    echo "${INSTALL_FEDORA_BASE}/${arch}/images/Fedora-Cloud-Base-AmazonEC2-${INSTALL_FEDORA_RELEASE}-${INSTALL_FEDORA_CURRENT}.${arch}.raw.xz"
}

fedora_raw_sha256() {
    case "$(platform_arch)" in
        aarch64) echo "$INSTALL_FEDORA_SHA256_aarch64" ;;
        *) echo "$INSTALL_FEDORA_SHA256_x86_64" ;;
    esac
}

check_kexec() {
    if ! command -v kexec &>/dev/null; then
        fatal "kexec is required for root device sanitization but not found.
Install it with your package manager (e.g., 'apt install kexec-tools' or 'dnf install kexec-tools')."
    fi
}

download_url() {
    local url="$1"
    local dest="$2"

    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest"
    else
        fatal "Neither curl nor wget is available to download files."
    fi
}

download_initramfs() {
    local dest="$1"
    local arch
    arch=$(platform_arch)
    local url
    url=$(initramfs_url)
    local expected
    expected=$(initramfs_sha256)

    info "Downloading initramfs from ${url}..."

    download_url "$url" "$dest" || fatal "Failed to download ${arch} initramfs."

    if [ ! -s "$dest" ]; then
        fatal "Downloaded initramfs is empty."
    fi

    local got
    got=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$got" != "$expected" ]; then
        fatal "Initramfs checksum mismatch for ${arch} (got $got, expected $expected)."
    fi

    success "Initramfs downloaded and verified for ${arch} ($(bytes_to_human "$(stat -c%s "$dest")"))."
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

    if [ -z "$src" ] || [ ! -f "$src" ]; then
        fatal "augment_initramfs: source initramfs '$src' not found."
    fi

    [ -n "$out" ] || out="${src%.gz}.augmented.cpio.gz"

    work=$(mktemp -d /tmp/kexec-wipe-augment.XXXXXX)
    gzip -dc "$src" | ( cd "$work" && cpio -idm 2>/dev/null )

    local dest="$work/${path#/}"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"

    ( cd "$work" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$out" )

    rm -rf "$work"
    echo "$out"
}

# Find a kernel image (optionally with its initrd) suitable for kexec. On
# classic setups this is vmlinuz + separate initrd, or a single UKI (Unified
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


do_kexec_wipe() {
    local dev="$1"
    local method="${2:-auto}"
    local install="${3:-0}"
    local test_mode="${4:-0}"

    check_kexec

    make_tmpdir
    local initramfs_path="${WIPE_TMPDIR}/$(initramfs_file)"

    download_initramfs "$initramfs_path"

    # With --install-fedora, the Fedora image is downloaded on the host and
    # embedded into the initramfs. The image path is handed to the initramfs
    # via the kernel command line.
    if [ "$install" -eq 1 ]; then
        local fedora="${WIPE_TMPDIR}/fedora.raw.xz"
        download_fedora_image "$fedora"

        # Capture the host hostname and the user to provision on the fresh install.
        # The provision user prefers the invoking user ($SUDO_USER) so the new
        # account matches the person running the wipe. When the wipe is run as
        # root (no SUDO_USER) or via "sudo ... as root", we provision the root
        # account itself: no user is created, only /root/.ssh/authorized_keys is
        # copied over.
        local host_hostname
        host_hostname=$(hostname)
        echo "$host_hostname" > "${WIPE_TMPDIR}/hostname"
        info "  Hostname:  $host_hostname"

        local provision_user
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            provision_user="$SUDO_USER"
        else
            provision_user="root"
        fi
        echo "$provision_user" > "${WIPE_TMPDIR}/user"
        info "  User:       $provision_user"

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
        augmented=$(augment_initramfs "$augmented" "/opt/kexec-wipe-user" "${WIPE_TMPDIR}/user")
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
        info "  Install:    Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} (pre-downloaded) after sanitize"
    fi

    # Test-only: don't abort the initramfs if the device does not implement the
    # NVMe Sanitize command (e.g. QEMU's emulated NVMe). Never set on real
    # hardware; see initramfs/init.
    if [ "$test_mode" -eq 1 ]; then
        cmdline="${cmdline} kexec_wipe_test=1"
        warn "  TEST MODE: sanitize failure will be ignored (device cannot be sanitized)."
    fi

    # A .efi kernel is a Unified Kernel Image (UKI): linux + initrd are embedded
    # in one PE binary. A classic kernel (vmlinuz/bzImage/...) has no embedded
    # initrd, so we hand it our wipe initramfs as the initrd.
    info "Loading kernel into memory..."
    info "  Kernel:    $kernel"
    info "  Initramfs: $initramfs_path"
    info "  Target:    $dev"

    if [[ "$kernel" == *.efi ]]; then
        # UKI: load its .linux section with our wipe initramfs as the initrd.
        # We deliberately use ONLY our initramfs (not the UKI's embedded one) so
        # our /init runs the wipe. Do not try to concatenate the UKI's embedded
        # initrd with ours: both are compressed cpio streams and the kernel
        # unpacks only the first gzip member, so the appended initramfs (and its
        # /init) would be silently dropped.
        info "  Boot image: UKI (.efi, embedded initrd)"
        kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" \
            || fatal "Failed to load UKI kernel into memory via kexec."
    else
        # Classic kernel: load with the wipe initramfs as the initrd.
        info "  Boot image: classic kernel (wipe initramfs as initrd)"
        kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" \
            || fatal "Failed to load kernel into memory via kexec."
    fi

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
kexec-wipe - Sanitize NVMe devices

Usage:
  curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh
  sudo bash wipe.sh /dev/nvme0n1
  sudo ./wipe.sh /dev/nvme0n1 [OPTIONS]

Arguments:
  /dev/nvmeXnY          Target NVMe device to sanitize

Options:
  --method=METHOD       Sanitize method (default: auto)
                        auto       - Try crypto-erase, then block-erase
                        crypto     - Crypto-erase only (fastest for self-encrypting devices)
                        block      - Block-erase only
                        overwrite  - Overwrite (slowest, most thorough)
  --dry-run             Show what would be done without making changes
  --install-fedora      After sanitizing the device via kexec, write a Fedora
                        Cloud Base image and install a bootloader so it can boot.
                        Works on the root device or any other device.
  --test-mode           TESTING ONLY: continue even if the sanitize command is
                        not supported by the device (e.g. QEMU's emulated
                        NVMe). Never use on real hardware.
  --help                Show this help message

Examples:
  sudo bash wipe.sh /dev/nvme0n1
  sudo bash wipe.sh /dev/nvme0n1 --method=block
  sudo bash wipe.sh /dev/nvme0n1 --install-fedora
  sudo bash wipe.sh /dev/nvme0n1 --dry-run

How it works:
  Non-root device: unmounts partitions, runs nvme sanitize directly.
  Root device: kexec's into a minimal in-memory environment to sanitize
  without any mounted filesystems, then reboots.
EOF
}

parse_args() {
    TARGET_DEVICE=""
    METHOD="auto"
    DRY_RUN=0
    INSTALL_FEDORA=0
    TEST_MODE=0

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
            --test-mode)
                TEST_MODE=1
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
    echo -e "${BOLD}Secure NVMe Device Sanitization${RESET}"
    echo ""
}

main() {
    parse_args "$@"

    print_banner
    check_root
    validate_device "$TARGET_DEVICE"

    # Non-root path needs nvme-cli on the host; the kexec path gets it from the
    # initramfs. --install-fedora also takes the kexec path on any disk: it
    # writes an image, installs a bootloader and switch_roots into the fresh
    # OS, all of which happen inside the minimal environment.
    local is_root=0
    if is_root_device "$TARGET_DEVICE"; then
        is_root=1
    fi

    local use_kexec=0
    if [ "$is_root" -eq 1 ] || [ "$INSTALL_FEDORA" -eq 1 ]; then
        use_kexec=1
    fi

    if [ "$use_kexec" -eq 1 ]; then
        # Fail fast on unsupported architectures before any destructive action.
        check_arch
    elif ! command -v nvme &>/dev/null; then
        fatal "nvme-cli is required but not found. Install it with your package manager."
    fi

    if [ "$is_root" -eq 1 ]; then
        warn "TARGET DEVICE IS THE ROOT DEVICE!"
        warn "This will kexec into a minimal environment to sanitize."
        warn "THE SYSTEM WILL REBOOT as part of this process."
    elif [ "$INSTALL_FEDORA" -eq 1 ]; then
        warn "TARGET IS NOT THE ROOT DEVICE, but --install-fedora sanitizes and replaces"
        warn "its contents, installs a bootloader, and boots into the fresh install."
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
        if [ "$use_kexec" -eq 1 ]; then
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

    if [ "$use_kexec" -eq 1 ]; then
        do_kexec_wipe "$TARGET_DEVICE" "$METHOD" "$INSTALL_FEDORA" "$TEST_MODE"
    else
        detach_device "$TARGET_DEVICE"
        do_sanitize "$TARGET_DEVICE" "$METHOD"
    fi
}

main "$@"
