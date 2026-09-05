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
    # initrd, so we hand it our wipe initramfs as the initrd. In both cases the
    # command is identical: kexec-tools unpacks a UKI's .linux section and loads
    # it as a plain kernel (arm64 support since 2.0.30, x86_64 since 2.0.31),
    # and when --initrd is given it replaces the UKI's embedded initrd so our
    # wipe /init is the one that runs. Verified by the aarch64 QEMU UKI test in
    # CI (ubuntu-26.04-arm).
    info "Loading kernel into memory..."
    info "  Kernel:    $kernel"
    info "  Initramfs: $initramfs_path"
    info "  Target:    $dev"

    if [[ "$kernel" == *.efi ]]; then
        info "  Boot image: UKI (.efi, embedded initrd)"
    else
        info "  Boot image: classic kernel (wipe initramfs as initrd)"
    fi
    kexec -l "$kernel" --initrd="$initramfs_path" --command-line="$cmdline" \
        || fatal "Failed to load $kernel into memory via kexec."

    success "Kernel loaded. System will now kexec into minimal environment."
    warn "THE SYSTEM WILL REBOOT MOMENTARILY. Any unsaved work will be lost."
    echo ""

    sleep 3

    sync
    kexec -e || fatal "kexec -e failed. System may need manual reboot."
}
