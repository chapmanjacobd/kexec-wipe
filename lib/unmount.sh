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
