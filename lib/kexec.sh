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
