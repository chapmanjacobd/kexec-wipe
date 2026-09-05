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
    if ! command -v findmnt >/dev/null 2>&1; then
        warn "Cannot determine the root device (findmnt missing); assuming '$dev' is the root device."
        sleep 10
        return 0
    fi
    local src
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || {
        warn "Cannot determine the root device (findmnt failed); assuming '$dev' is the root device."
        sleep 10
        return 0
    }
    src="${src%%\[*\]}"

    if ! command -v lsblk >/dev/null 2>&1; then
        warn "Cannot determine the root device (lsblk missing); assuming '$dev' is the root device."
        sleep 10
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
    # NVMe partitions are named "<dev>pN". Match only those (not e.g. nvme0n10
    # when targeting nvme0n1) and the whole device itself.
    local part
    for part in /dev/"$devname" /dev/"${devname}"p[0-9]*; do
        [ -b "$part" ] || continue
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
    # Match the PV name exactly: either the whole device (/dev/nvme0n1) or one
    # of its partitions (/dev/nvme0n1p2). Avoid matching e.g. /dev/nvme0n10
    # when targeting /dev/nvme0n1.
    pvs_output=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
        | awk -v dev="/dev/$devname" '$1 == dev || $1 ~ "^" dev "p[0-9]+$"' || true)

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
    local devname
    devname=$(basename "$dev")

    if ! command -v mdadm &>/dev/null; then
        return
    fi

    info "Checking for MD RAID on $dev..."

    local md_paths=""
    # grep exits 1 when no array uses this disk; turn that into an empty list.
    # Match member tokens exactly ("nvme0n1p1[0]" or "nvme0n1[0]"), not
    # prefixes of other namespaces such as "nvme0n10p1[0]".
    md_paths=$(cat /proc/mdstat 2>/dev/null | grep -E "[[:space:]]${devname}(p[0-9]+)?\[[0-9]+\]" | awk '{print $1}') || md_paths=""

    if [ -n "$md_paths" ]; then
        for md in $md_paths; do
            info "  Stopping MD array: /dev/$md"
            mdadm --stop "/dev/$md" 2>/dev/null || true
        done
    fi
}

# Refuse to proceed if the device still has active consumers (mounts or swap)
# after teardown. Sanitizing a device that is still mounted risks corruption or
# a rejected sanitize; the whole point of this tool is to avoid that.
assert_device_detached() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    local remaining=""
    if command -v lsblk >/dev/null 2>&1; then
        remaining=$(lsblk -lno MOUNTPOINTS "/dev/$devname" 2>/dev/null | grep -E '^/' || true)
    else
        remaining=$(mount | awk -v d="/dev/$devname" 'index($1, d) == 1 { print $1 " on " $3 }' || true)
    fi
    if [ -n "$remaining" ]; then
        fatal "Device $dev is still mounted; refusing to sanitize. Remaining mounts:
$remaining"
    fi

    if [ -f /proc/swaps ]; then
        if grep -qE "^/dev/${devname}(p[0-9]+)?[[:space:]]" /proc/swaps 2>/dev/null; then
            fatal "Device $dev is still used as swap; refusing to sanitize."
        fi
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

    # Verify nothing is still using the device before sanitizing it.
    assert_device_detached "$dev"
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

# Build the wipe initramfs on the host at runtime. This (unlike shipping a
# prebuilt initramfs) guarantees the staged kernel modules (xfs/btrfs/ext4/nvme)
# match the kernel that will be kexec'd, so modprobe can load the NVMe driver
# after kexec even on distros that build it as a module (e.g. Fedora).
#
# The initramfs builder and the init script are embedded into wipe.sh by
# build.sh (write_embedded_initramfs_build_sh / write_embedded_initramfs_init).
build_initramfs_on_host() {
    local dest="$1"

    for d in bash cpio gzip; do
        command -v "$d" >/dev/null 2>&1 || fatal "$d is required to build the initramfs on the host."
    done

    local srcdir="${WIPE_TMPDIR}/initramfs-src"
    mkdir -p "$srcdir"
    write_embedded_initramfs_build_sh "$srcdir/build.sh"
    write_embedded_initramfs_init "$srcdir/init"
    chmod +x "$srcdir/build.sh" "$srcdir/init"

    info "Building initramfs on host (matching kernel $(uname -r))..."
    if ! bash "$srcdir/build.sh" --output="$dest"; then
        fatal "Failed to build the initramfs on the host."
    fi

    if [ ! -s "$dest" ]; then
        fatal "Built initramfs is empty."
    fi

    success "Initramfs built for $(platform_arch) ($(bytes_to_human "$(stat -c%s "$dest")"))."
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

# Embed files into a copy of the initramfs cpio archive in a single pass. The
# kernel-initramfs is itself an unpacked RAM filesystem, so adding files makes
# them available to initramfs/init as if on disk. All files are added after one
# extraction so a large archive (e.g. an embedded Fedora image) is only
# decompressed and recompressed once. Prints the augmented initramfs path.
#
#   args: INITRAMFS_IN  (path to source cpio.gz)
#         OUT           (path to the augmented cpio.gz)
#         PAIR...       (each "EMBEDDED_PATH=FILE")
augment_initramfs() {
    local src="$1" out="$2"
    shift 2
    local work

    if [ -z "$src" ] || [ ! -f "$src" ]; then
        fatal "augment_initramfs: source initramfs '$src' not found."
    fi
    [ -n "$out" ] || fatal "augment_initramfs: no output path."

    work=$(mktemp -d /tmp/kexec-wipe-augment.XXXXXX)
    gzip -dc "$src" | ( cd "$work" && cpio -idm 2>/dev/null )

    local pair path file dest
    for pair in "$@"; do
        path="${pair%%=*}"
        file="${pair#*=}"
        [ -n "$path" ] || fatal "augment_initramfs: bad pair '$pair'."
        [ -f "$file" ] || fatal "augment_initramfs: file to embed '$file' not found."
        dest="$work/${path#/}"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "$dest"
    done

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

    check_kexec

    make_tmpdir
    local initramfs_path
    initramfs_path="${WIPE_TMPDIR}/kexec-wipe-initramfs.cpio.gz"

    build_initramfs_on_host "$initramfs_path"

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

        # Copy the provisioned account's own authorized_keys. When provisioning a
        # regular user, use that user's keys (not root's, which is what $HOME
        # resolves to under sudo). When provisioning root, use root's keys.
        local auth_keys=""
        if [ "$provision_user" = "root" ]; then
            [ -f "/root/.ssh/authorized_keys" ] && auth_keys="/root/.ssh/authorized_keys"
        else
            local user_home
            user_home=$(getent passwd "$provision_user" 2>/dev/null | cut -d: -f6)
            [ -n "$user_home" ] || user_home="/home/$provision_user"
            [ -f "$user_home/.ssh/authorized_keys" ] && auth_keys="$user_home/.ssh/authorized_keys"
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
        augmented=$(augment_initramfs "$initramfs_path" "${initramfs_path%.gz}.augmented.cpio.gz" \
            "/opt/fedora.raw.xz=$fedora" \
            "/opt/kexec-wipe-hostname=${WIPE_TMPDIR}/hostname" \
            "/opt/kexec-wipe-user=${WIPE_TMPDIR}/user" \
            "/opt/kexec-wipe-authorized_keys=${WIPE_TMPDIR}/authorized_keys")
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

    # Internal test hook (used by the QEMU CI tests, not a user-facing flag):
    # don't abort the initramfs if the device does not implement the NVMe
    # Sanitize command (e.g. QEMU's emulated NVMe). Never set on real hardware;
    # see initramfs/init.
    if [ "${KEXEC_WIPE_TEST_MODE:-0}" = "1" ]; then
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
        # UKI: kexec-tools (>= 2.0.25) detects the PE's .linux section and loads
        # it. Our --initrd is passed as an *additional* initrd segment after the
        # UKI's embedded one; the kernel unpacks all initrds in order, so our
        # wipe /init (unpacked last) is the one that runs. This requires
        # kexec-tools 2.0.25+ (verified by the QEMU UKI test in CI).
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
    echo -e "${BOLD}Secure NVMe Device Sanitization${RESET}"
    echo ""
}

main() {
    parse_args "$@"

    # Resolve /dev/disk/by-* style symlinks so basename-based checks (NVMe name
    # validation, root-device detection, teardown) see the real kernel device.
    TARGET_DEVICE=$(readlink -f "$TARGET_DEVICE" 2>/dev/null || echo "$TARGET_DEVICE")

    print_banner
    check_root
    validate_device "$TARGET_DEVICE"

    # The kexec path builds its initramfs on the host (nvme-cli is needed unless
    # Docker is available to build it statically), while the direct path runs
    # nvme sanitize on the host. Both paths also need nvme-cli installed.
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
        if ! command -v nvme &>/dev/null && ! command -v docker &>/dev/null; then
            fatal "nvme-cli is required on the host (or Docker to build it) to build the initramfs. Install nvme-cli."
        fi
        for d in bash cpio gzip; do
            command -v "$d" &>/dev/null || fatal "$d is required to build the initramfs on the host."
        done
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
        do_kexec_wipe "$TARGET_DEVICE" "$METHOD" "$INSTALL_FEDORA"
    else
        detach_device "$TARGET_DEVICE"
        do_sanitize "$TARGET_DEVICE" "$METHOD"
    fi
}

main "$@"

# --- begin embedded: initramfs/init ---
write_embedded_initramfs_init() {
    cat > "$1" <<'KW_EMBED_init_EOF'
#!/bin/sh
#
# kexec-wipe initramfs init script
#
# This runs in a minimal in-memory environment after kexec.
# It reads kexec_wipe_dev and kexec_wipe_method from the kernel command line,
# sanitizes the target device, and reboots.
#

set -e

# Shared libraries for dynamically-linked binaries live in /lib
export LD_LIBRARY_PATH=/lib

log() {
    echo "[kexec-wipe] $*"
}

warn() {
    echo "[kexec-wipe] WARNING: $*" >&2
}

fatal() {
    echo "[kexec-wipe] FATAL: $*" >&2
    sleep 5
    reboot -f
}

# "Fatal" failure that still gives the operator a grace period to read the
# message before the system is force-rebooted.
fatal_reboot() {
    echo "[kexec-wipe] FATAL: $*" >&2
    echo "[kexec-wipe] The system will reboot in 30 seconds..."
    i=30
    while [ "$i" -gt 0 ]; do
        printf '\r[kexec-wipe] Rebooting in %02d s (Ctrl-Alt-Del to abort where supported)   ' "$i"
        sleep 1
        i=$((i - 1))
    done
    echo ""
    reboot -f
}

parse_cmdline() {
    local cmdline
    cmdline=$(cat /proc/cmdline)

    KEXEC_WIPE_DEV=""
    KEXEC_WIPE_METHOD="auto"
    KEXEC_WIPE_INSTALL=0
    # Test-only mode: still attempt the real NVMe sanitize, but a full failure
    # must not abort the script. Used by CI to exercise the install pipeline
    # against QEMU's emulated NVMe, which does not implement the NVMe Sanitize
    # command. Not for production use.
    KEXEC_WIPE_TEST=0
    # Optional overrides for the Fedora install source (used by tests). When
    # empty, the pinned release/checksum above is used.
    KEXEC_WIPE_FEDORA_IMAGE=""
    KEXEC_WIPE_HOSTNAME=""
    KEXEC_WIPE_USER=""

    for arg in $cmdline; do
        case "$arg" in
            kexec_wipe_dev=*)
                KEXEC_WIPE_DEV="${arg#kexec_wipe_dev=}"
                ;;
            kexec_wipe_method=*)
                KEXEC_WIPE_METHOD="${arg#kexec_wipe_method=}"
                ;;
            kexec_wipe_install=*)
                KEXEC_WIPE_INSTALL="${arg#kexec_wipe_install=}"
                ;;
            kexec_wipe_test=*)
                KEXEC_WIPE_TEST="${arg#kexec_wipe_test=}"
                ;;
            kexec_wipe_fedora_image=*)
                KEXEC_WIPE_FEDORA_IMAGE="${arg#kexec_wipe_fedora_image=}"
                ;;
        esac
    done

    if [ -z "$KEXEC_WIPE_DEV" ]; then
        fatal "No target device specified in kernel command line."
    fi

    # Read the host hostname and the provision user from the embedded files
    # (written by the host-side script). Either file may be absent (e.g. older
    # images only embed one of them); tolerate a missing file.
    if [ -f /opt/kexec-wipe-hostname ]; then
        KEXEC_WIPE_HOSTNAME=$(cat /opt/kexec-wipe-hostname)
    fi
    if [ -f /opt/kexec-wipe-user ]; then
        KEXEC_WIPE_USER=$(cat /opt/kexec-wipe-user)
    fi
}

mount_pseudo_fs() {
    log "Mounting pseudo-filesystems..."
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sys /sys 2>/dev/null || true
    mount -t devtmpfs dev /dev 2>/dev/null || true

    # Wait for device nodes to appear
    log "Waiting for devices to settle..."
    sleep 3
}

check_device() {
    # Best-effort: if the target is an NVMe device whose driver is modular
    # (e.g. not built into the running kernel), try to load it before checking.
    case "$KEXEC_WIPE_DEV" in
        /dev/nvme*)
            # modprobe nvme pulls in nvme-core as a dependency and registers the
            # block device; fall back to nvme-core alone just in case.
            modprobe nvme 2>/dev/null || modprobe nvme-core 2>/dev/null || true
            # Probe is async; wait for the device node to register (up to ~10s).
            i=0
            while [ "$i" -lt 10 ] && [ ! -b "$KEXEC_WIPE_DEV" ]; do
                sleep 1
                i=$((i + 1))
            done
            ;;
    esac

    if [ ! -b "$KEXEC_WIPE_DEV" ]; then
        fatal "Target device $KEXEC_WIPE_DEV not found."
    fi
    log "Target device: $KEXEC_WIPE_DEV"
}

try_crypto_erase() {
    log "Attempting crypto-erase..."
    if nvme sanitize "$KEXEC_WIPE_DEV" -a start-crypto-erase 2>/dev/null; then
        return 0
    fi
    log "Crypto-erase failed or not supported."
    return 1
}

try_block_erase() {
    log "Attempting block-erase..."
    if nvme sanitize "$KEXEC_WIPE_DEV" -a start-block-erase 2>/dev/null; then
        return 0
    fi
    log "Block-erase failed."
    return 1
}

try_overwrite() {
    log "Attempting overwrite (this may take a while)..."
    if nvme sanitize "$KEXEC_WIPE_DEV" -a start-overwrite 2>/dev/null; then
        return 0
    fi
    log "Overwrite failed."
    return 1
}

do_sanitize() {
    # In test mode (e.g. QEMU's emulated NVMe, which does not implement the
    # NVMe Sanitize command) we still attempt the real sanitize, but a full
    # failure must not abort the script so CI can exercise the rest of the
    # pipeline (install, switch_root).
    # Returns 0 on success, 1 on failure, 2 on test-mode-skip (sanitize does
    # not run).
    local ok=1

    case "$KEXEC_WIPE_METHOD" in
        crypto)
            try_crypto_erase || ok=0
            ;;
        block)
            try_block_erase || ok=0
            ;;
        overwrite)
            try_overwrite || ok=0
            ;;
        auto|"")
            try_crypto_erase || try_block_erase || ok=0
            if [ "$ok" -eq 0 ]; then
                log "All sanitize methods failed."
            fi
            ;;
        *)
            fatal "Unknown method: $KEXEC_WIPE_METHOD"
            ;;
    esac

    if [ "$ok" -eq 0 ]; then
        if [ "$KEXEC_WIPE_TEST" = "1" ]; then
            log "TEST MODE: sanitize failed but continuing (emulated device cannot sanitize)."
            return 2
        fi
        fatal_reboot "All sanitize methods failed."
    fi
}

# Query the NVMe sanitize log and echo "<state> <progress>", where <state> is
# one of: in-progress, success, failure, none. <progress> is the raw SPROG
# value (0-65535). Returns 1 if the log could not be read.
#
# NOTE: This whole function is intentionally duplicated in lib/sanitize.sh.
# This init runs under busybox sh inside the in-memory environment, while
# lib/sanitize.sh runs under bash on the host, so the two cannot share code.
# Keep both copies identical when changing the SPROG/SSTAT parsing.
sanitize_log_state() {
    local log sstat sprog status

    log=$(nvme sanitize-log "$KEXEC_WIPE_DEV" -o json 2>/dev/null) || return 1

    # Extract SPROG/SSTAT robustly. nvme-cli versions differ: some emit flat
    # decimal integers, some hex ("0x.."), and 1.x nests sstat as an object with
    # a human-readable "status" string. The awk handles all three forms. Values
    # may be hex; shell arithmetic interprets the "0x" prefix directly.
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

wait_for_completion() {
    local timeout=7200
    local elapsed=0
    local interval=5

    log "Waiting for sanitize to complete (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local state progress result pct
        result=$(sanitize_log_state) || result="none 0"
        state=${result%% *}
        progress=${result#* }

        case "$state" in
            in-progress)
                # SPROG is a fraction of 0x10000 (65536); progress is its numerator.
                pct=$(( progress * 100 / 65536 ))
                printf "\r  Sanitizing... %d%% " "$pct"
                ;;
            success)
                echo ""
                log "Sanitize completed successfully."
                return 0
                ;;
            failure)
                echo ""
                log "Sanitize completed with FAILURE."
                return 1
                ;;
            none|*)
                # No sanitize reported yet: the command may just have started and
                # the controller has not updated the log. Keep polling.
                if [ "$elapsed" -eq 0 ]; then
                    echo ""
                    log "No sanitize reported in progress yet."
                fi
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    log "Timed out waiting for sanitize."
    return 1
}

# Run the sanitize and wait for completion, producing a single verdict:
#   - runs do_sanitize (which handles method selection and test-mode skipping)
#   - waits for completion for a real sanitize
#   - returns 4 on test-mode-skip (sanitize not performed), 0 on success.
# On any genuine failure it never returns (calls fatal_reboot internally).
sanitize_and_wait() {
    # do_sanitize returns 2 (test-mode-skip), which is non-zero: guard it so
    # `set -e` does not kill the shell before we can inspect $rc.
    local rc=0
    do_sanitize || rc=$?
    if [ "$rc" -eq 2 ]; then
        log "Sanitize was not performed (test/emulated device)."
        return 4
    fi
    # rc is 0 here: a real failure never returns from do_sanitize.
    if wait_for_completion; then
        log "Device $KEXEC_WIPE_DEV has been sanitized."
        return 0
    fi
    fatal_reboot "Sanitize failed or did not complete."
}

# --- Partition / filesystem helpers ------------------------------------

# Wait for a partition device node to appear (e.g. after writing an image and
# re-reading the partition table). Returns 0 when the device exists.
wait_for_partition() {
    local part="$1"
    local timeout="${2:-10}"
    local i=0
    while [ "$i" -lt "$timeout" ] && [ ! -b "$part" ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -b "$part" ]
}

# Detect filesystem type on a partition.  Tries busybox blkid with a few
# retries; returns 1 if detection fails.
detect_fs_type() {
    local part="$1"
    local attempt fs
    for attempt in 1 2 3; do
        fs=$(blkid "$part" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
        if [ -n "$fs" ]; then
            echo "$fs"
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- Optional: install Fedora after wipe --------------------------------
arch_name() {
    case "$(uname -m)" in
        aarch64|arm64) echo "aarch64" ;;
        *) echo "x86_64" ;;
    esac
}

# Decompress the raw image and write it to the device. We never write the
# compressed stream directly to the disk.
write_fedora_image() {
    local xzfile="$1"
    local dev="$2"

    log "Writing Fedora image to $dev (this can take a while)..."
    # Decompress (xz, or busybox's unlzma/lzcat applets) and write with dd.
    # `conv=fsync` forces dd to flush before returning so we know the image is
    # actually on disk. `status=none` is GNU-only; retry without it (busybox dd
    # prints to stderr, which we already suppress on the first attempt) if it
    # fails.
    write_with_dd() {
        local dec="$1"
        ( $dec | dd of="$dev" bs=4M conv=fsync status=none ) 2>/dev/null \
        || ( $dec | dd of="$dev" bs=4M conv=fsync ) \
        || ( $dec | dd of="$dev" bs=4M ) || fatal "Failed to write Fedora image."
    }
    if command -v xz >/dev/null 2>&1; then
        write_with_dd "xz -dc $xzfile"
    else
        write_with_dd "unlzma -dc $xzfile"
    fi

    sync
    sleep 1

    # Force the kernel to re-read the partition table. After writing a raw
    # image, the in-memory partition table is stale. BLKRRPART triggers a
    # rescan and uevent generation so devtmpfs can create the partition nodes.
    local devname
    devname=$(basename "$dev")

    # Remove stale partition nodes first (if any).
    for old_part in "${dev}"p*; do
        [ -b "$old_part" ] && rm -f "$old_part" 2>/dev/null || true
    done

    blockdev --rereadpt "$dev" 2>/dev/null || true

    # Also trigger a device-level rescan via sysfs (NVMe specific).
    if [ -d "/sys/block/$devname/device" ]; then
        echo 1 > "/sys/block/$devname/device/rescan" 2>/dev/null || true
    fi

    # Wait for partition nodes to appear (up to 10s).
    log "Waiting for partition nodes to appear..."
    local waited=0
    while [ "$waited" -lt 10 ]; do
        # Check if any partition of $dev exists.
        if ls "${dev}p"* >/dev/null 2>&1; then
            log "Partition table re-read complete."
            break
        fi
        sleep 1
        waited=$((waited + 1))
        # Retry the re-read on each iteration; sometimes the first attempt races.
        blockdev --rereadpt "$dev" 2>/dev/null || true
    done

    # Fallback: if partition nodes remain absent (e.g. emulated NVMe
    # devices where sysfs rescan is not supported), try partprobe to ask the
    # kernel to re-read and create the partition nodes.
    if ! ls "${dev}p"* >/dev/null 2>&1; then
        log "Partition nodes missing; trying partprobe..."
        partprobe "$dev" 2>/dev/null || true
        sleep 1
    fi

    # Fallback: if partition nodes remain absent (e.g. emulated NVMe
    # devices where sysfs rescan is not supported), create the partition device
    # nodes manually. The kernel has usually already re-read the partition
    # table via BLKRRPART and registered the partitions in sysfs; only the
    # devtmpfs node materialization failed. Read each partition's real
    # major:minor from sysfs (/sys/block/<dev>/<part>/dev) and mknod it. This is
    # correct for any namespace/controller layout, unlike guessing that the
    # partition index equals the minor number.
    if ! ls "${dev}p"* >/dev/null 2>&1; then
        log "Partition nodes missing; creating them manually from sysfs..."
        local part
        for part in /sys/block/"$devname"/"$devname"p*; do
            [ -e "$part" ] || continue
            local name partdev major minor node
            name=$(basename "$part")
            partdev=$(cat "$part/dev" 2>/dev/null) || continue
            major="${partdev%:*}"
            minor="${partdev#*:}"
            node="/dev/$name"
            [ -n "$major" ] && [ -n "$minor" ] || continue
            if [ ! -b "$node" ]; then
                mknod "$node" b "$major" "$minor" 2>/dev/null || true
            fi
        done
        if ls "${dev}p"* >/dev/null 2>&1; then
            log "Partition nodes created manually."
        fi
    fi

    log "Fedora image written."
}

# Echo the ext/xfs/btrfs partitions in the written image (one per line). They
# are the only candidates that could hold the OS root.
candidate_root_parts() {
    local dev="$1"
    blkid "$dev"* 2>/dev/null | grep -iE 'TYPE="(xfs|ext4|ext3|ext2|btrfs)"' | cut -d: -f1
}

# Try mounting each candidate partition under $1 (mountpoint) and return the
# first one that is actually a bootable OS root (has /etc/fstab or /sbin/init).
# This avoids mistaking a separate /boot or /boot/efi partition for the root:
# the real root is identified by content, not position. On success sets
# ROOT_PART and ROOT_FS for the caller and returns 0 (leaves the partition
# mounted at $1). Returns 1 if no candidate qualifies.
mount_os_root() {
    local mnt="$1"
    local part fs

    for part in $(candidate_root_parts "$KEXEC_WIPE_DEV"); do
        fs=$(detect_fs_type "$part") || continue
        case "$fs" in
            xfs)   [ -d /sys/fs/xfs ] || modprobe xfs 2>/dev/null || true ;;
            btrfs) modprobe btrfs 2>/dev/null || true ;;
            ext*|*) modprobe "$fs" 2>/dev/null || true ;;
        esac
        if mount_root_part "$part" "$mnt" "$fs"; then
            if [ -e "$mnt/etc/fstab" ] || [ -e "$mnt/sbin/init" ]; then
                ROOT_PART="$part"
                ROOT_FS="$fs"
                log "  OS root on $part ($fs)"
                return 0
            fi
            # Not the OS root (e.g. a separate /boot partition); try the next one.
            umount "$mnt" 2>/dev/null || true
        fi
    done
    return 1
}

# Mount the OS root partition, selecting the correct btrfs subvolume when the
# default subvolume is not the OS root. Fedora Cloud Base images keep the OS in
# a "root" subvolume while the default subvolume is the (empty) btrfs top
# level, so a plain "mount -t btrfs" would expose no /usr, /etc or /sbin/init.
# Returns 0 when the mount point contains a valid OS root.
mount_root_part() {
    local dev="$1" mnt="$2" fs="$3"

    if [ "$fs" != "btrfs" ]; then
        mount -t "$fs" "$dev" "$mnt" 2>/dev/null
        return $?
    fi

    modprobe btrfs 2>/dev/null || true

    local sub
    for sub in "" "root" "@" "@root" "ROOT"; do
        if [ -z "$sub" ]; then
            mount -t btrfs "$dev" "$mnt" 2>/dev/null
        else
            mount -t btrfs -o "subvol=$sub" "$dev" "$mnt" 2>/dev/null
        fi
        if [ $? -eq 0 ] && [ -e "$mnt/sbin/init" ]; then
            mount_sibling_subvolumes "$dev" "$mnt"
            return 0
        fi
        umount "$mnt" 2>/dev/null || true
    done
    return 1
}

# Resolve an fstab source field ("UUID=...", "LABEL=..." or "/dev/...") to the
# matching partition device node on the target disk. Echoes the node on success;
# returns 1 if nothing matches. Used to mount non-btrfs sibling partitions (e.g.
# the EFI System Partition) inside the chroot.
resolve_fstab_source() {
    local src="$1" want val part
    case "$src" in
        UUID=*)
            want=${src#UUID=}
            for part in /dev/"$(basename "$KEXEC_WIPE_DEV")"p*; do
                [ -b "$part" ] || continue
                val=$(blkid "$part" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
                [ -n "$val" ] && [ "$val" = "$want" ] && { echo "$part"; return 0; }
            done
            ;;
        LABEL=*)
            want=${src#LABEL=}
            for part in /dev/"$(basename "$KEXEC_WIPE_DEV")"p*; do
                [ -b "$part" ] || continue
                val=$(blkid "$part" 2>/dev/null | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
                [ -n "$val" ] && [ "$val" = "$want" ] && { echo "$part"; return 0; }
            done
            ;;
        /dev/*)
            [ -b "$src" ] && { echo "$src"; return 0; }
            ;;
    esac
    return 1
}

# Fedora Cloud Base images also keep /boot, /home and /var in their own btrfs
# subvolumes, and the EFI System Partition at /boot/efi. Mount those (as listed
# in the image's /etc/fstab) underneath the mounted OS root so that chroot
# operations (grub2-install, grub2-mkconfig, user provisioning) see the real
# filesystem layout instead of the empty mount-point directories.
mount_sibling_subvolumes() {
    local dev="$1" mnt="$2"
    [ -f "$mnt/etc/fstab" ] || return 0

    local line src fspath fstype opts subvol target srcdev
    while IFS= read -r line; do
        case "$line" in \#*|"") continue ;; esac
        set -- $line
        [ $# -lt 4 ] && continue
        src="$1"; fspath="$2"; fstype="$3"; opts="$4"

        if [ "$fstype" = "btrfs" ]; then
            case "$fspath" in
                /boot|/home|/var|/opt|/srv|/root) ;;
                *) continue ;;
            esac
            subvol=""
            case "$opts" in
                *subvol=*) subvol=$(echo "$opts" | sed -n 's/.*subvol=\([^,]*\).*/\1/p') ;;
                *) continue ;;
            esac
            [ -n "$subvol" ] || continue
            target="$mnt$fspath"
            [ -d "$target" ] || mkdir -p "$target"
            mountpoint -q "$target" 2>/dev/null && continue
            if mount -t btrfs -o "subvol=$subvol" "$dev" "$target" 2>/dev/null; then
                log "  Mounted subvolume $subvol at $fspath"
            fi
        elif [ "$fspath" = "/boot/efi" ]; then
            # The EFI System Partition is a separate non-btrfs partition.
            # Mount it so chrooted grub2-install can write the bootloader.
            srcdev=$(resolve_fstab_source "$src") || continue
            target="$mnt$fspath"
            [ -d "$target" ] || mkdir -p "$target"
            mountpoint -q "$target" 2>/dev/null && continue
            modprobe vfat 2>/dev/null || true
            if mount -t "$fstype" "$srcdev" "$target" 2>/dev/null; then
                log "  Mounted EFI partition $srcdev at $fspath"
            else
                warn "Could not mount EFI partition $srcdev at $fspath."
            fi
        fi
    done < "$mnt/etc/fstab"
}

# Unmount everything mounted beneath a mount point (deepest first), leaving the
# top mount itself intact. Used so sibling subvolumes do not leave the root
# mount busy, and so switch_root hands a clean tree to systemd.
unmount_tree() {
    local top="$1" tmp="/tmp/unmount-tree.$$"
    awk -v top="$top" 'index($2, top "/") == 1 { print length($2), $2 }' \
        /proc/mounts 2>/dev/null | sort -rn | awk '{ print $2 }' > "$tmp"
    local m
    while IFS= read -r m; do
        umount "$m" 2>/dev/null || true
    done < "$tmp"
    rm -f "$tmp"
}

# Install a bootloader into the Fedora image so it boots on bare metal.
# We chroot into the image's root and run its own grub2-install, which keeps the
# image's normal boot config and covers both UEFI and legacy BIOS targets.
install_bootloader() {
    local dev="$1"

    log "Installing bootloader on $dev..."

    local mnt=/mnt/root
    mkdir -p "$mnt"
    if ! mount_os_root "$mnt"; then
        warn "Could not find and mount the OS root; skipping bootloader install."
        return 0
    fi

    # Bind system pseudo-fses so chrooted tools work.
    mount -t proc proc "$mnt/proc" 2>/dev/null || true
    mount -t sysfs sys "$mnt/sys" 2>/dev/null || true
    mount -t devtmpfs dev "$mnt/dev" 2>/dev/null || true

    local uefi=0
    if [ -d /sys/firmware/efi ]; then
        uefi=1
    fi

    # Expose UEFI NVRAM variables to the chroot so grub2-install can register a
    # boot entry. Not fatal if unavailable; the install falls back to --no-nvram.
    if [ "$uefi" -eq 1 ] && [ -d "$mnt/sys/firmware/efi" ]; then
        mkdir -p "$mnt/sys/firmware/efi/efivars"
        mount -t efivarfs efivarfs "$mnt/sys/firmware/efi/efivars" 2>/dev/null || true
    fi

    if [ -x "$mnt/sbin/grub2-install" ] || [ -x "$mnt/usr/sbin/grub2-install" ]; then
        local grub_target
        grub_target=$(detect_grub_target "$uefi")

        log "Using GRUB (target: $grub_target) from the installed image..."
        # grub2-install is the real bootloader install; mkconfig only regenerates
        # the config and is NOT a fallback for a failed install. Report success
        # only when the bootloader was actually written to the disk.
        #
        # Fedora patches grub2-install to refuse EFI installs unless --force is
        # given (plain grub2-install would replace the image's signed shim/grub
        # EFI binaries with unsigned ones and break Secure Boot). This is a
        # fresh install where we explicitly want the bootloader written, so
        # --force is correct. If efibootmgr cannot register an NVRAM entry (no
        # efivarfs in the initramfs chroot), retry with --no-nvram: the EFI
        # files are still written and the disk remains bootable via the
        # removable-media fallback (EFI/BOOT/BOOTX64.EFI).
        if chroot "$mnt" /bin/bash -c \
                "grub2-install --target=$grub_target --no-floppy --force '$dev' 2>/dev/null || \
                 grub2-install --target=$grub_target --no-floppy --force --no-nvram '$dev' 2>/dev/null || \
                 grub2-install --no-floppy --force '$dev' 2>/dev/null"; then
            chroot "$mnt" /bin/bash -c "grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1" || true
            log "GRUB installed successfully."
        else
            warn "GRUB installation failed; leaving image as-is."
        fi
    else
        warn "No GRUB found in installed image; skipping bootloader install."
    fi

    sync
    unmount_tree "$mnt"
    umount "$mnt" 2>/dev/null || true
}

detect_grub_target() {
    local uefi="$1"
    if [ "$(arch_name)" = "aarch64" ]; then
        # ARM64 is always EFI (there is no legacy BIOS ARM path).
        echo "arm64-efi"
    elif [ "$uefi" -eq 1 ]; then
        echo "x86_64-efi"
    else
        echo "i386-pc"
    fi
}

# Sanitize a hostname for use as a Linux username.  Lowercases, truncates to 32
# characters, and strips characters outside [a-z0-9_-].  Returns empty string if
# the result would be empty.
sanitize_username() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g' | cut -c1-32)
    echo "$cleaned"
}

# Configure a user account and SSH access on the freshly written Fedora image.
# The provision user (embedded at /opt/kexec-wipe-user) is used as the
# username, falling back to the hostname file when no separate user was
# embedded. authorized_keys is read from the embedded file at
# /opt/kexec-wipe-authorized_keys.
configure_fedora_user() {
    # Prefer the provision user; fall back to the hostname for images that only
    # embed one of the two.
    local provision_user="$KEXEC_WIPE_USER"
    if [ -z "$provision_user" ]; then
        provision_user="$KEXEC_WIPE_HOSTNAME"
    fi
    if [ -z "$provision_user" ]; then
        warn "No provision user; skipping user provisioning."
        return 0
    fi

    local username
    username=$(sanitize_username "$provision_user")
    if [ -z "$username" ]; then
        warn "Provision user '$provision_user' produced empty username; skipping user provisioning."
        return 0
    fi

    log "Configuring user '$username' (source: '$provision_user')..."

    local mnt=/mnt/root
    mkdir -p "$mnt"
    if ! mount_os_root "$mnt"; then
        warn "Could not find and mount the OS root; skipping user provisioning."
        return 0
    fi

    mount -t proc proc "$mnt/proc" 2>/dev/null || true
    mount -t sysfs sys "$mnt/sys" 2>/dev/null || true
    mount -t devtmpfs dev "$mnt/dev" 2>/dev/null || true

    if [ "$username" = "root" ]; then
        # Provisioning the root account: no useradd or sudoers needed (root
        # already has full access), just install the SSH keys and enable sshd.
        if [ -f /opt/kexec-wipe-authorized_keys ] && [ -s /opt/kexec-wipe-authorized_keys ]; then
            mkdir -p "$mnt/root/.ssh"
            chmod 0700 "$mnt/root/.ssh"
            cp /opt/kexec-wipe-authorized_keys "$mnt/root/.ssh/authorized_keys"
            chroot "$mnt" /bin/bash -c "chown root:root /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys" 2>/dev/null || true
            log "Copied authorized_keys for root."
        else
            warn "No authorized_keys found; SSH key access not configured."
        fi
        chroot "$mnt" /bin/bash -c "systemctl enable sshd" 2>/dev/null || \
        chroot "$mnt" /bin/bash -c "ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service" 2>/dev/null || \
        warn "Could not enable sshd; you may need to enable it manually."

        sync
        unmount_tree "$mnt"
        umount "$mnt" 2>/dev/null || true
        log "User provisioning complete."
        return 0
    fi

    local chroot_ok=1

    if ! chroot "$mnt" /bin/bash -c "id '$username'" >/dev/null 2>&1; then
        if chroot "$mnt" /bin/bash -c "useradd -m -G wheel -c 'kexec-wipe user' '$username'" 2>/dev/null; then
            log "Created user '$username'."
        else
            warn "useradd failed; skipping user provisioning."
            chroot_ok=0
        fi
    else
        log "User '$username' already exists; skipping creation."
        # Ensure the user is in the wheel group even if it already existed.
        chroot "$mnt" /bin/bash -c "usermod -aG wheel '$username'" 2>/dev/null || true
    fi

    if [ "$chroot_ok" -eq 1 ]; then
        # Grant passwordless sudo via a drop-in.
        chroot "$mnt" /bin/bash -c "mkdir -p /etc/sudoers.d && echo '$username ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$username && chmod 0440 /etc/sudoers.d/$username" 2>/dev/null || warn "Could not configure sudo for '$username'."

        # Set up SSH authorized_keys.
        chroot "$mnt" /bin/bash -c "mkdir -p /home/$username/.ssh && chown $username:$username /home/$username/.ssh && chmod 0700 /home/$username/.ssh" 2>/dev/null || true
        if [ -f /opt/kexec-wipe-authorized_keys ] && [ -s /opt/kexec-wipe-authorized_keys ]; then
            cp /opt/kexec-wipe-authorized_keys "$mnt/home/$username/.ssh/authorized_keys"
            chroot "$mnt" /bin/bash -c "chown $username:$username /home/$username/.ssh/authorized_keys && chmod 0600 /home/$username/.ssh/authorized_keys" 2>/dev/null || true
            log "Copied authorized_keys for '$username'."
        else
            warn "No authorized_keys found; SSH key access not configured."
        fi

        # Ensure sshd is enabled on boot.
        chroot "$mnt" /bin/bash -c "systemctl enable sshd" 2>/dev/null || \
        chroot "$mnt" /bin/bash -c "ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service" 2>/dev/null || \
        warn "Could not enable sshd; you may need to enable it manually."
    fi

    sync
    unmount_tree "$mnt"
    umount "$mnt" 2>/dev/null || true

    log "User provisioning complete."
}

install_fedora() {
    log "=== Installing Fedora after sanitize ==="
    if [ "$KEXEC_WIPE_INSTALL" != "1" ]; then
        return 0
    fi

    if [ -z "$KEXEC_WIPE_FEDORA_IMAGE" ] || [ ! -f "$KEXEC_WIPE_FEDORA_IMAGE" ]; then
        fatal "No Fedora image found. wipe.sh must embed it before kexec."
    fi

    local xzfile="$KEXEC_WIPE_FEDORA_IMAGE"
    log "Using pre-embedded Fedora image: $xzfile"

    write_fedora_image "$xzfile" "$KEXEC_WIPE_DEV"
    install_bootloader "$KEXEC_WIPE_DEV"
    rm -f "$xzfile"

    log "Fedora installation complete."
}

cleanup_and_reboot() {
    log "Syncing..."
    sync
    log "Rebooting..."
    reboot -f
}

# After --install-fedora, skip the reboot and boot directly into the freshly
# written Fedora via switch_root. systemd (Fedora's init) mounts the API
# filesystems (/dev, /proc, /sys, /run) itself early in boot, so we only need
# to provide a console and the mounted root partition.
switch_to_fedora() {
    local newroot=/sysroot

    # Mount the OS root (identifies the real root partition by content). If
    # blkid cannot detect any filesystem, fall back to blind-probing known fs
    # types on the first partition.
    mkdir -p "$newroot"
    if ! mount_os_root "$newroot"; then
        warn "blkid could not identify the OS root; trying mount fallback..."
        local found=""
        for part in /dev/"$(basename "$KEXEC_WIPE_DEV")"p*; do
            [ -b "$part" ] || continue
            for try_fs in ext4 ext3 ext2 xfs btrfs; do
                if mount -t "$try_fs" "$part" "$newroot" 2>/dev/null; then
                    ROOT_PART="$part"
                    ROOT_FS="$try_fs"
                    found=1
                    log "Detected $try_fs via mount fallback."
                    break 2
                fi
            done
        done
        if [ -z "$found" ]; then
            warn "Could not detect Fedora root filesystem; cannot switch_root."
            return 1
        fi
    fi

    # The provisioning chroot ran without a loaded SELinux policy, so the files
    # it touched (/etc/passwd, /etc/shadow, /home/..., ...) are unlabeled. On
    # SELinux-enforcing systems that breaks confined services (dbus-broker,
    # sshd) on the first real boot. Schedule a relabel via the installed
    # system's standard /.autorelabel mechanism.
    if [ -f "$newroot/etc/selinux/config" ] && \
       grep -qE '^SELINUX=(enforcing|permissive)' "$newroot/etc/selinux/config" 2>/dev/null; then
        touch "$newroot/.autorelabel"
        log "SELinux relabel scheduled (/.autorelabel)."
    fi

    [ -e /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
    sync

    # Drop the sibling subvolumes so systemd mounts them itself per /etc/fstab.
    unmount_tree "$newroot"

    log "Switching root into Fedora ($ROOT_PART)..."
    exec switch_root -c /dev/console "$newroot" /sbin/init
}

main() {
    log "=== kexec-wipe initramfs ==="

    # Kernel unpacks initramfs as root; mount pseudo-filesystems on top
    mkdir -p /proc /sys /dev /tmp
    mount_pseudo_fs
    parse_cmdline
    check_device

    log "Sanitize method: $KEXEC_WIPE_METHOD"

    # sanitize_and_wait logs the outcome and only ever returns 0 (sanitized) or
    # 4 (test-mode-skip: sanitize not performed); on a genuine failure it never
    # returns (fatal_reboot). The `|| true` guards the 4 against set -e.
    sanitize_and_wait || true

    install_fedora

    # When installing Fedora, provision the user and boot straight into it.
    if [ "$KEXEC_WIPE_INSTALL" = "1" ]; then
        configure_fedora_user
        log "Booting into freshly installed Fedora..."
        sleep 3
        if switch_to_fedora; then
            # switch_root exec's into systemd; we only reach here on failure.
            :
        fi
        log "switch_root failed; falling back to reboot."
        sleep 2
    else
        log "Rebooting in 5 seconds..."
        sleep 5
    fi

    cleanup_and_reboot
}

main
KW_EMBED_init_EOF
}
# --- end embedded: initramfs/init ---

# --- begin embedded: initramfs/build.sh ---
write_embedded_initramfs_build_sh() {
    cat > "$1" <<'KW_EMBED_build_sh_EOF'
#!/bin/bash
#
# Build a pre-built initramfs for kexec-wipe releases
#
# This creates a minimal initramfs with:
#   - busybox-static (for shell and basic utilities)
#   - nvme-cli-static (for sanitize commands)
#   - init script
#
# Usage:
#   ./initramfs/build.sh [--output=initramfs.cpio.gz]
#
# Requirements:
#   - Docker (for building static nvme-cli)
#   - cpio, gzip
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

OUTPUT=""
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
USE_DOCKER=1
BUILD_DIR=""

# Host architecture (normalized).
host_arch() {
    local a
    a=$(uname -m)
    case "$a" in
        aarch64|arm64) echo "aarch64" ;;
        *) echo "$a" ;;
    esac
}

# Obtain a busybox static binary matching the target architecture. The official
# prebuilt static binaries only exist for x86_64, so other architectures (e.g.
# aarch64) build from Alpine via Docker, falling back to host busybox.
install_busybox() {
    echo "Installing busybox..."

    if [ "$(host_arch)" = "x86_64" ] && command -v curl >/dev/null 2>&1; then
        curl -fsSL "$BUSYBOX_URL" -o "$BUILD_DIR/bin/busybox" && chmod +x "$BUILD_DIR/bin/busybox" && return 0
    fi

    if [ "$USE_DOCKER" -eq 1 ] && command -v docker >/dev/null 2>&1; then
        echo "Building busybox static via Docker (arch: $(host_arch))..."
        docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$BUILD_DIR:/output" alpine:latest sh -c '
            apk add --no-cache busybox-static >/dev/null 2>&1
            cp /bin/busybox.static /output/bin/busybox 2>/dev/null \
                || cp /busybox.static /output/bin/busybox 2>/dev/null \
                || cp /bin/busybox /output/bin/busybox 2>/dev/null
            chown -R $HOST_UID:$HOST_GID /output/bin/busybox
        '
        chmod +x "$BUILD_DIR/bin/busybox" && return 0
        echo "Docker busybox build failed; falling back to host busybox."
    fi

    if command -v busybox >/dev/null 2>&1; then
        cp "$(command -v busybox)" "$BUILD_DIR/bin/busybox"
        chmod +x "$BUILD_DIR/bin/busybox"
        return 0
    fi

    echo "ERROR: Could not obtain a busybox binary for arch $(host_arch)" >&2
    exit 1
}

# Copy a dynamically-linked binary plus its shared libraries into the build dir.
# Copy a shared library into the build, preserving the soname symlink that the
# dynamic loader needs. `resolved` is the soname path from ldd (e.g.
# /usr/lib64/libcurl.so.4); we copy the real versioned file and add a symlink
# from the soname to it (libcurl.so.4 -> libcurl.so.4.8.0).
copy_lib() {
    local resolved="$1"
    local lib_dir="$BUILD_DIR/lib"

    [ -f "$resolved" ] || return 0

    local real soname
    real=$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")
    soname=$(basename "$resolved")
    local realname
    realname=$(basename "$real")

    if [ -f "$real" ] && [ ! -e "$lib_dir/$realname" ]; then
        cp -L "$real" "$lib_dir/$realname"
    fi
    if [ "$soname" != "$realname" ] && [ ! -e "$lib_dir/$soname" ]; then
        ln -sf "$realname" "$lib_dir/$soname"
    fi
}

copy_bin_with_libs() {
    local bin="$1"
    local target="$2"

    [ -x "$bin" ] || return 1
    cp "$bin" "$target"
    chmod +x "$target"

    local lib_dir="$BUILD_DIR/lib"
    mkdir -p "$lib_dir"
    ldd "$bin" 2>/dev/null | while IFS= read -r line; do
        local resolved
        if echo "$line" | grep -q '=>'; then
            resolved=$(echo "$line" | sed 's/.*=> \([^ ]*\).*/\1/')
        else
            resolved=$(echo "$line" | awk '{print $1}')
        fi
        case "$resolved" in
            linux-vdso*) continue ;;
            *ld-linux*) continue ;;
            /*) ;;
            *) continue ;;
        esac
        copy_lib "$resolved"
    done

    # The ELF interpreter (dynamic loader) itself. copy_lib places it under
    # /lib, but the interpreter in the ELF header may point at /lib64. Mirror
    # it to both locations so dynamically-linked helpers can actually exec.
    local ld_line
    ld_line=$(ldd "$bin" 2>/dev/null | grep 'ld-linux' | head -1)
    if [ -n "$ld_line" ]; then
        local ld_path
        ld_path=$(echo "$ld_line" | awk '{print $1}')
        if [ -n "$ld_path" ] && [ -f "$ld_path" ]; then
            local ld_base
            ld_base=$(basename "$ld_path")
            if [ ! -e "$BUILD_DIR/lib/$ld_base" ]; then
                cp -L "$ld_path" "$BUILD_DIR/lib/$ld_base"
            fi
            mkdir -p "$BUILD_DIR/lib64"
            if [ ! -e "$BUILD_DIR/lib64/$ld_base" ]; then
                cp -L "$ld_path" "$BUILD_DIR/lib64/$ld_base"
            fi
        fi
    fi
    return 0
}

# Copy disk tools (partprobe, blockdev) needed by the Fedora install path.
# xz is not needed here: busybox provides xz/unlzma/lzcat applets.
install_disk_tools() {
    mkdir -p "$BUILD_DIR/bin"

    for b in partprobe blockdev; do
        if [ -e "$BUILD_DIR/bin/$b" ]; then
            continue
        fi
        if command -v "$b" >/dev/null 2>&1; then
            copy_bin_with_libs "$(command -v "$b")" "$BUILD_DIR/bin/$b" || true
        fi
    done
}

# Copy a module file and its transitive dependencies (resolved via the source
# modules.dep) into the build tree. `mod` is a path relative to /lib/modules/$kver
# (e.g. kernel/drivers/nvme/host/nvme.ko.xz). Returns after copying each
# dependency once.
copy_module_with_deps() {
    local mod="$1" src="$2" dst="$3"
    local depfile="$src/modules.dep"

    [ -f "$depfile" ] || return 0
    local line
    line=$(grep -E "^${mod}:" "$depfile" 2>/dev/null || true)
    [ -z "$line" ] && return 0

    local deps=${line#*:}
    local d
    for d in $deps; do
        [ -f "$src/$d" ] || continue
        if [ ! -e "$dst/$d" ]; then
            mkdir -p "$(dirname "$dst/$d")"
            cp -a "$src/$d" "$dst/$d"
            copy_module_with_deps "$d" "$src" "$dst"
        fi
    done
}

# Stage kernel filesystem modules (xfs/btrfs/ext4 and fat/vfat) and the NVMe
# driver modules so the chroot bootloader step can mount the written Fedora
# image (including its EFI System Partition) and so the target NVMe is visible
# after kexec even when the running kernel has NVMe support as modules (e.g.
# Fedora). Modules are kernel-version-specific, so the build host's matching
# modules are copied as a reasonable default.
stage_fs_modules() {
    local kver
    kver=$(uname -r)
    local src="/lib/modules/${kver}"
    local dst="$BUILD_DIR/lib/modules/${kver}"

    if [ ! -d "$src/kernel/fs" ]; then
        echo "WARNING: No kernel modules found at $src; chroot mount may fail (raw image may still boot via its own initramfs)." >&2
        return 0
    fi

    echo "Staging kernel modules ($kver)..."
    mkdir -p "$dst/kernel/fs"
    # xfs/btrfs/ext4: the OS root and its btrfs sibling subvolumes.
    # fat (contains fat.ko + vfat.ko): the EFI System Partition that
    # grub2-install writes the bootloader to.
    local deps=0 fsdir
    for fsdir in xfs btrfs ext4 fat; do
        if [ -d "$src/kernel/fs/$fsdir" ]; then
            echo "  - $fsdir"
            cp -a "$src/kernel/fs/$fsdir" "$dst/kernel/fs/"
            deps=1
        fi
    done
    # NVMe driver (nvme-core, nvme, nvme-auth, nvme-keyring, ...). Without
    # these the target device may not appear after kexec on distros that build
    # NVMe support as modules.
    if [ -d "$src/kernel/drivers/nvme" ]; then
        echo "  - nvme (drivers)"
        mkdir -p "$dst/kernel/drivers"
        cp -a "$src/kernel/drivers/nvme" "$dst/kernel/drivers/"
        deps=1
    fi
    # Minimal metadata so modprobe can resolve the staged modules.
    mkdir -p "$dst"
    for f in modules.dep modules.dep.bin modules.builtin modules.builtin.bin modules.alias modules.alias.bin modules.symbols; do
        [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f" 2>/dev/null || true
    done
    # Resolve and copy transitive module dependencies (e.g. nls_cp437/nls_ascii
    # for vfat, hkdf for nvme-auth) so busybox modprobe can load them after
    # kexec.
    if [ "$deps" -eq 1 ]; then
        local mod
        for mod in $(cd "$dst" && find kernel -name '*.ko*' 2>/dev/null); do
            copy_module_with_deps "$mod" "$src" "$dst"
        done
    fi
}

parse_args() {
    OUTPUT="${SCRIPT_DIR}/kexec-wipe-initramfs-$(host_arch).cpio.gz"

    while [ $# -gt 0 ]; do
        case "$1" in
            --output=*)
                OUTPUT="${1#--output=}"
                ;;
            --no-docker)
                USE_DOCKER=0
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done

    case "$OUTPUT" in
        /*) ;;
        *) OUTPUT="$REPO_DIR/$OUTPUT" ;;
    esac
}

check_deps() {
    local missing=()
    for dep in cpio gzip; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

cleanup_build() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
}

copy_nvme_with_libs() {
    local nvme_bin
    nvme_bin=$(command -v nvme) || { echo "WARNING: nvme not found. Initramfs will lack nvme support."; return 0; }

    echo "Copying nvme-cli with shared libraries..."
    copy_bin_with_libs "$nvme_bin" "$BUILD_DIR/bin/nvme"
}

build_initramfs() {
    BUILD_DIR=$(mktemp -d /tmp/kexec-wipe-build.XXXXXX)
    trap cleanup_build EXIT

    echo "Building initramfs in $BUILD_DIR..."

    # Create directory structure
    mkdir -p "$BUILD_DIR"/{bin,sbin,etc,proc,sys,dev,tmp,var}

    # Install busybox (arch-aware)
    install_busybox

    # Create busybox symlinks
    cd "$BUILD_DIR/bin"
    for cmd in sh bash mount umount mountpoint mkdir cat cp echo ls grep sed mknod sleep \
               reboot poweroff halt dmesg hexdump head tail wc find df free \
               lsblk blkid fdisk parted sync dd chroot sha256sum chmod tr uname rm rmdir \
               xz unlzma lzcat modprobe awk switch_root timeout \
               cut sort basename dirname expr printf seq stat touch; do
        ln -sf busybox "$cmd"
    done
    cd "$REPO_DIR"

    # The kernel auto-loads modules via /sbin/modprobe; ensure the symlink exists.
    mkdir -p "$BUILD_DIR/sbin"
    ln -sf ../bin/busybox "$BUILD_DIR/sbin/modprobe"

    # Install Fedora install support tools (xz/partprobe/blockdev)
    install_disk_tools

    # Stage filesystem kernel modules for the chroot bootloader step.
    stage_fs_modules

    # Build nvme-cli
    echo "Building nvme-cli..."
    if [ "$USE_DOCKER" -eq 1 ] && command -v docker &>/dev/null; then
        echo "Building static nvme-cli via Docker..."
        local nvme_container="kexec-wipe-nvme-$$"
        docker run --name "$nvme_container" alpine:latest sh -c '
            apk add --no-cache bash git gcc make musl-dev linux-headers json-c-dev openssl-dev openssl-libs-static python3 meson ninja \
            && git clone --depth 1 https://github.com/linux-nvme/libnvme.git /tmp/libnvme \
            && cd /tmp/libnvme \
            && meson setup .build --buildtype=release --default-library=static -Ddocs=false -Dpython=disabled \
            && meson compile -C .build \
            && meson install -C .build \
            && git clone --depth 1 --branch v2.16 https://github.com/linux-nvme/nvme-cli.git /tmp/nvme-cli \
            && cd /tmp/nvme-cli \
            && meson setup .build --buildtype=release --default-library=static -Dprefer_static=true -Dc_link_args=-static -Ddocs=false \
            && meson compile -C .build nvme \
            && cp .build/nvme /tmp/nvme \
            && strip /tmp/nvme
        ' && {
            mkdir -p "$BUILD_DIR/bin"
            docker cp "$nvme_container":/tmp/nvme "$BUILD_DIR/bin/nvme"
            chmod +x "$BUILD_DIR/bin/nvme"
            docker rm "$nvme_container" >/dev/null 2>&1
        } || {
            docker rm "$nvme_container" >/dev/null 2>&1 || true
            echo "Docker static build failed, trying to copy host nvme-cli with libs..."
            copy_nvme_with_libs
        }
    else
        copy_nvme_with_libs
    fi

    # Install init script
    cp "${SCRIPT_DIR}/init" "$BUILD_DIR/init"
    chmod +x "$BUILD_DIR/init"

    # Build cpio archive
    echo "Packing initramfs..."
    cd "$BUILD_DIR"
    find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUTPUT"
    cd "$REPO_DIR"

    local size
    size=$(stat -c%s "$OUTPUT")
    echo "Initramfs built: $OUTPUT ($size bytes)"
}

main() {
    parse_args "$@"
    check_deps
    build_initramfs
}

main "$@"
KW_EMBED_build_sh_EOF
}
# --- end embedded: initramfs/build.sh ---
