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
