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
