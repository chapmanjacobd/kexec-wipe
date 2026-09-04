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
