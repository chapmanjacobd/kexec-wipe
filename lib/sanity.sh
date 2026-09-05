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
