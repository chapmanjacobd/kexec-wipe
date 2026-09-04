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

# Host architecture (normalized). Used to pick the right binaries.
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
# aarch64) are built from Alpine via Docker, falling back to host busybox.
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
# Reuses the ldd-parsing approach also used for nvme-cli.
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
        [ -f "$resolved" ] || continue
        local real
        real=$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")
        local name
        name=$(basename "$real")
        if [ -f "$real" ] && [ ! -e "$lib_dir/$name" ]; then
            cp -L "$real" "$lib_dir/$name"
        fi
    done
    return 0
}

# Copy the Fedora install support tools (network, verification, decompression,
# partitioning, grub chroot helpers). When Docker is available these come from
# Alpine so HTTPS + partprobe are fully functional; otherwise best-effort from
# the host.
install_install_tools() {
    mkdir -p "$BUILD_DIR/usr/bin" "$BUILD_DIR/etc"

    # CA certificates so HTTPS downloads verify.
    if [ "$USE_DOCKER" -eq 1 ] && command -v docker >/dev/null 2>&1; then
        echo "Bundling network/install tools via Docker..."
        docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$BUILD_DIR:/output" alpine:latest sh -c '
            apk add --no-cache curl xz iproute2 parted util-linux-misc >/dev/null 2>&1
            mkdir -p /output/bin /output/usr/bin /output/lib /output/etc
            for b in curl xz ip partprobe blockdev; do
                p=$(command -v $b 2>/dev/null) || continue
                if [ "${p#/usr/}" != "$p" ]; then dest=/output/usr/bin; else dest=/output/bin; fi
                cp -L "$p" "$dest/$(basename $p)"
                deps=$(ldd "$p" 2>/dev/null || true)
                printf "%s\n" "$deps" | while read -r _ a _; do
                    case "$a" in
                        /*) cp -L "$a" /output/lib/ 2>/dev/null || true ;;
                    esac
                done
            done
            cp -rL /etc/ssl /output/etc/ 2>/dev/null || true
            cp /etc/ssl/certs/ca-certificates.crt /output/etc/ 2>/dev/null || true
            chown -R $HOST_UID:$HOST_GID /output
        ' || true
        chmod +x "$BUILD_DIR"/bin/curl "$BUILD_DIR"/bin/xz "$BUILD_DIR"/bin/ip \
            "$BUILD_DIR"/bin/partprobe "$BUILD_DIR"/bin/blockdev \
            "$BUILD_DIR"/usr/bin/curl "$BUILD_DIR"/usr/bin/xz "$BUILD_DIR"/usr/bin/ip \
            "$BUILD_DIR"/usr/bin/partprobe "$BUILD_DIR"/usr/bin/blockdev 2>/dev/null || true
    fi

    # Best-effort fallback from the host (only if not already copied via Docker).
    for b in curl wget xz ip partprobe blockdev; do
        if [ -e "$BUILD_DIR/bin/$b" ] || [ -e "$BUILD_DIR/usr/bin/$b" ]; then
            continue
        fi
        if command -v "$b" >/dev/null 2>&1; then
            case "$b" in
                curl) copy_bin_with_libs "$(command -v curl)" "$BUILD_DIR/bin/curl" || true ;;
                wget) copy_bin_with_libs "$(command -v wget)" "$BUILD_DIR/bin/wget" || true ;;
                xz)   copy_bin_with_libs "$(command -v xz)" "$BUILD_DIR/bin/xz" || true ;;
                ip)   copy_bin_with_libs "$(command -v ip)" "$BUILD_DIR/bin/ip" || true ;;
                partprobe) copy_bin_with_libs "$(command -v partprobe)" "$BUILD_DIR/bin/partprobe" || true ;;
                blockdev) copy_bin_with_libs "$(command -v blockdev)" "$BUILD_DIR/bin/blockdev" || true ;;
            esac
        fi
    done
    [ -d /etc/ssl ] && cp -rL /etc/ssl "$BUILD_DIR/etc/" 2>/dev/null || true
    [ -f /etc/ca-certificates.crt ] && cp /etc/ca-certificates.crt "$BUILD_DIR/etc/" 2>/dev/null || true
}

# Stage kernel filesystem modules (xfs/btrfs/ext4) so the chroot bootloader step
# can mount the written Fedora image. Modules are kernel-version-specific, so we
# copy the build host's matching modules as a reasonable default.
stage_fs_modules() {
    local kver
    kver=$(uname -r)
    local src="/lib/modules/${kver}"
    local dst="$BUILD_DIR/lib/modules/${kver}"

    if [ ! -d "$src/kernel/fs" ]; then
        echo "WARNING: No kernel modules found at $src; chroot mount may fail (raw image may still boot via its own initramfs)." >&2
        return 0
    fi

    echo "Staging filesystem kernel modules ($kver)..."
    mkdir -p "$dst/kernel/fs"
    for fs in xfs btrfs ext4; do
        if [ -d "$src/kernel/fs/$fs" ]; then
            echo "  - $fs"
            cp -a "$src/kernel/fs/$fs" "$dst/kernel/fs/"
        fi
    done
    # Minimal metadata so modprobe can resolve the staged modules.
    mkdir -p "$dst"
    for f in modules.dep modules.dep.bin modules.builtin modules.builtin.bin modules.alias modules.alias.bin modules.symbols; do
        [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f" 2>/dev/null || true
    done
}

parse_args() {
    OUTPUT="${SCRIPT_DIR}/kexec-wipe-initramfs.cpio.gz"

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

    # Copy the binary
    cp "$nvme_bin" "$BUILD_DIR/bin/nvme"

    # Copy required shared libraries
    local lib_dir="$BUILD_DIR/lib"
    mkdir -p "$lib_dir"

    # Parse ldd output: each line is either "  lib => /path (0xaddr)" or "  /path (0xaddr)"
    ldd "$nvme_bin" 2>/dev/null | while IFS= read -r line; do
        # Extract the path: if there's "=>" use the right side, otherwise use the first field
        local resolved
        if echo "$line" | grep -q '=>'; then
            resolved=$(echo "$line" | sed 's/.*=> \([^ ]*\).*/\1/')
        else
            resolved=$(echo "$line" | awk '{print $1}')
        fi

        # Skip non-path entries (vdso) and the dynamic linker (we'll handle it separately)
        case "$resolved" in
            linux-vdso*) continue ;;
            *ld-linux*) continue ;;
            /*) ;;
            *) continue ;;
        esac

        [ -f "$resolved" ] || continue

        local lib_name
        lib_name=$(basename "$resolved")

        # Resolve symlinks to the actual file
        local real_path
        real_path=$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")

        if [ -f "$real_path" ] && [ ! -e "$lib_dir/$lib_name" ]; then
            cp -L "$real_path" "$lib_dir/$lib_name"
        fi
    done

    # Copy ld-linux-x86-64.so.2 (the dynamic linker) into the right place
    local ld_line
    ld_line=$(ldd "$nvme_bin" 2>/dev/null | grep 'ld-linux' | head -1)
    if [ -n "$ld_line" ]; then
        local ld_path
        ld_path=$(echo "$ld_line" | awk '{print $1}')
        if [ -n "$ld_path" ] && [ -f "$ld_path" ]; then
            local ld_real
            ld_real=$(readlink -f "$ld_path" 2>/dev/null || echo "$ld_path")
            mkdir -p "$BUILD_DIR/lib64"
            cp -L "$ld_real" "$BUILD_DIR/lib64/"
        fi
    fi
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
    for cmd in sh bash mount umount mkdir cat echo ls grep sed mknod sleep \
               reboot poweroff halt dmesg hexdump head tail wc find df free \
               lsblk blkid fdisk parted sync dd chroot sha256sum chmod \
               udhcpc ip xz unlzma lzcat modprobe awk switch_root; do
        ln -sf busybox "$cmd"
    done
    cd "$REPO_DIR"

    # Install Fedora network/install support tools (curl/xz/ip/partprobe/CA certs)
    install_install_tools

    # Stage filesystem kernel modules for the chroot bootloader step.
    stage_fs_modules

    # Build nvme-cli
    echo "Building nvme-cli..."
    if [ "$USE_DOCKER" -eq 1 ] && command -v docker &>/dev/null; then
        echo "Building static nvme-cli via Docker..."
        docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$BUILD_DIR:/output" alpine:latest sh -c '
            apk add --no-cache git gcc make musl-dev linux-headers json-c-dev openssl-dev python3 meson \
            && git clone --depth 1 --branch v2.16 https://github.com/linux-nvme/nvme-cli.git /tmp/nvme-cli \
            && cd /tmp/nvme-cli \
            && meson setup .build --buildtype=release --default-library=static -Ddocs=false \
            && meson compile -C .build nvme \
            && cp .build/nvme /output/bin/nvme \
            && chown -R $HOST_UID:$HOST_GID /output
        ' || {
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
