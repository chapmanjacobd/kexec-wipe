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

# Stage kernel filesystem modules (xfs/btrfs/ext4) and the NVMe driver modules
# so the chroot bootloader step can mount the written Fedora image and so the
# target NVMe is visible after kexec even when the running kernel has NVMe
# support as modules (e.g. Fedora). Modules are kernel-version-specific, so the
# build host's matching modules are copied as a reasonable default.
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
    for fs in xfs btrfs ext4; do
        if [ -d "$src/kernel/fs/$fs" ]; then
            echo "  - $fs"
            cp -a "$src/kernel/fs/$fs" "$dst/kernel/fs/"
        fi
    done
    # NVMe driver (nvme-core, nvme, nvme-auth, nvme-keyring, ...). Without
    # these the target device may not appear after kexec on distros that build
    # NVMe support as modules.
    if [ -d "$src/kernel/drivers/nvme" ]; then
        echo "  - nvme (drivers)"
        mkdir -p "$dst/kernel/drivers"
        cp -a "$src/kernel/drivers/nvme" "$dst/kernel/drivers/"
        # Resolve and copy any dependencies of the NVMe driver modules (e.g.
        # kernel/crypto/hkdf on kernels where nvme-auth is modular), otherwise
        # busybox modprobe cannot load nvme after kexec.
        local mod
        for mod in $(cd "$dst" && find kernel/drivers/nvme -name '*.ko*' 2>/dev/null); do
            copy_module_with_deps "$mod" "$src" "$dst"
        done
    fi
    # Minimal metadata so modprobe can resolve the staged modules.
    mkdir -p "$dst"
    for f in modules.dep modules.dep.bin modules.builtin modules.builtin.bin modules.alias modules.alias.bin modules.symbols; do
        [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f" 2>/dev/null || true
    done
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
    for cmd in sh bash mount umount mkdir cat echo ls grep sed mknod sleep \
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
