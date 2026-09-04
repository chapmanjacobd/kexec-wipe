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

    # Download busybox static
    echo "Downloading busybox static..."
    curl -fsSL "$BUSYBOX_URL" -o "$BUILD_DIR/bin/busybox"
    chmod +x "$BUILD_DIR/bin/busybox"

    # Create busybox symlinks
    cd "$BUILD_DIR/bin"
    for cmd in sh bash mount umount mkdir cat echo ls grep sed mknod sleep \
               reboot poweroff halt dmesg hexdump head tail wc find df free \
               lsblk blkid fdisk parted; do
        ln -sf busybox "$cmd"
    done
    cd "$REPO_DIR"

    # Build nvme-cli
    echo "Building nvme-cli..."
    if [ "$USE_DOCKER" -eq 1 ] && command -v docker &>/dev/null; then
        echo "Building static nvme-cli via Docker..."
        docker run --rm -v "$BUILD_DIR:/output" alpine:latest sh -c '
            apk add --no-cache git gcc make musl-dev linux-headers json-c-dev openssl-dev \
            && git clone --depth 1 https://github.com/linux-nvme/nvme-cli.git /tmp/nvme-cli \
            && cd /tmp/nvme-cli \
            && make STATIC=1 \
            && cp nvme /output/bin/nvme
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
