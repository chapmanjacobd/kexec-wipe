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
