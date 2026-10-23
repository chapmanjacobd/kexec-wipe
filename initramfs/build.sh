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
#   - cpio, gzip, xz, zstd
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

OUTPUT=""
ALPINE_CDN="https://dl-cdn.alpinelinux.org/alpine/latest-stable"
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

# Fetch a URL to stdout (curl preferred, wget fallback). Returns 0 on success.
http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
            --retry-delay 2 --retry-max-time 90 "$url" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=10 --tries=3 "$url" 2>/dev/null && return 0
    fi
    return 1
}

# Map the host architecture to the Alpine CDN architecture name.
alpine_arch_name() {
    case "$(host_arch)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7" ;;
        armv6l|arm) echo "armhf" ;;
        *)       host_arch ;;
    esac
}

# Return 0 if the given file is a statically linked ELF executable. The
# initramfs has no shared libraries, so a dynamic (or corrupt) busybox is
# useless to us.
busybox_is_static() {
    local bin="$1"
    # Must be a real ELF binary first (a flaky download can leave garbage).
    [ -f "$bin" ] || return 1
    local magic
    magic=$(od -An -tx1 -N4 "$bin" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ] || return 1
    if command -v file >/dev/null 2>&1; then
        # "statically linked" (classic non-PIE) or "static-pie linked" (modern
        # busybox builds) both describe a fully static executable.
        file -b "$bin" 2>/dev/null | grep -Eqi 'statically linked|static-pie'
        return $?
    fi
    # Fallback: ldd exits non-zero for a static executable (no dynamic deps).
    if command -v ldd >/dev/null 2>&1; then
        if ldd "$bin" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi
    return 0
}

# Try to obtain a busybox binary via the host package manager. Debian/Ubuntu
# ship busybox-static (statically linked); Fedora's busybox package is dynamic,
# so the static check below rejects it and this tier falls through to the
# Alpine CDN fallback. Needs sudo unless already root.
install_busybox_via_pkg() {
    local destdir="$1"
    local maybe_sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || return 1
        maybe_sudo="sudo"
    fi
    local pkg_root
    pkg_root=$(mktemp -d)

    if command -v apt-get >/dev/null 2>&1; then
        echo "Fetching busybox-static via apt-get..."
        # Refresh the package cache (harmless; also fine if this fails, the
        # cached lists may already be good enough).
        $maybe_sudo apt-get update -qq >/dev/null 2>&1 || true
        if (cd "$pkg_root" && apt-get download -qq busybox-static >/dev/null 2>&1); then
            local deb bb
            deb=$(find "$pkg_root" -name 'busybox-static*.deb' -type f | head -1)
            if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1 \
               && dpkg-deb -x "$deb" "$pkg_root/extracted" 2>/dev/null; then
                bb=$(find "$pkg_root/extracted" -name busybox -type f | head -1)
                if [ -n "$bb" ] && busybox_is_static "$bb"; then
                    if cp "$bb" "$destdir" 2>/dev/null; then
                        rm -rf "$pkg_root"
                        return 0
                    fi
                fi
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then
        echo "Fetching busybox via dnf..."
        if (cd "$pkg_root" && $maybe_sudo dnf -q download busybox >/dev/null 2>&1); then
            local rpm bb
            rpm=$(find "$pkg_root" -name 'busybox*.rpm' -type f | head -1)
            if [ -n "$rpm" ] && command -v rpm2cpio >/dev/null 2>&1 \
               && command -v cpio >/dev/null 2>&1; then
                local rpm_name
                rpm_name=$(basename "$rpm")
                if (cd "$pkg_root" && rpm2cpio "$rpm_name" | cpio -idm --quiet >/dev/null 2>&1); then
                    bb=$(find "$pkg_root" -path '*/bin/busybox' -type f | head -1)
                    if [ -n "$bb" ] && busybox_is_static "$bb"; then
                        if cp "$bb" "$destdir" 2>/dev/null; then
                            rm -rf "$pkg_root"
                            return 0
                        fi
                    fi
                fi
            fi
        fi
    fi

    rm -rf "$pkg_root"
    return 1
}

# Download the Alpine busybox-static package directly from the CDN and extract
# the statically linked binary from it. Alpine's CDN (dl-cdn.alpinelinux.org)
# is far more reliable than busybox.net and needs no Docker. The package
# version is resolved from the repository APKINDEX so no version is hardcoded,
# and it needs no root (no chroot, no container).
download_busybox_from_alpine() {
    local output="$1"
    local arch
    arch=$(alpine_arch_name)
    local base="${ALPINE_CDN}/main/${arch}"

    echo "Downloading busybox-static from Alpine CDN (${arch})..."

    # `|| true` absorbs the benign EPIPE: curl keeps writing while tar stops at
    # the end-of-archive marker (the APK has trailing padding). Real success is
    # judged by the extracted file below, not the pipeline status.
    local ver
    ver=$(http_get "${base}/APKINDEX.tar.gz" | tar -xzO APKINDEX 2>/dev/null \
          | awk '/^P:busybox-static$/ { f=1; next } f && /^V:/ { sub(/^V:/, ""); print; exit }' \
          || true)
    if [ -z "$ver" ]; then
        echo "Could not resolve busybox-static version from the Alpine APKINDEX." >&2
        return 1
    fi

    local extract_dir
    extract_dir=$(mktemp -d)
    http_get "${base}/busybox-static-${ver}.apk" | tar -xz -C "$extract_dir" 2>/dev/null || true
    local bb="$extract_dir/bin/busybox.static"
    if busybox_is_static "$bb" && cp "$bb" "$output" 2>/dev/null; then
        rm -rf "$extract_dir"
        return 0
    fi
    echo "busybox.static not found or not a static ELF in the extracted APK." >&2
    rm -rf "$extract_dir"
    return 1
}

# Obtain a busybox static binary matching the target architecture. The primary
# source is Alpine's busybox-static package (all architectures, verified static,
# reliable CDN); Docker, the host package manager and a host busybox are
# fallbacks.
install_busybox() {
    echo "Installing busybox..."

    # Tier 1: Alpine busybox-static APK straight from the CDN (all arches).
    if { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }; then
        if download_busybox_from_alpine "$BUILD_DIR/bin/busybox"; then
            chmod +x "$BUILD_DIR/bin/busybox"
            return 0
        fi
    fi

    # Tier 2: build from Alpine via Docker.
    if [ "$USE_DOCKER" -eq 1 ] && command -v docker >/dev/null 2>&1; then
        echo "Building busybox static via Docker (arch: $(host_arch))..."
        # Run the container in an `if` so a failed build (missing applet,
        # builder image, etc.) falls through to another static-busybox source
        # instead of dying under `set -e`.
        if docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$BUILD_DIR:/output" alpine:latest sh -ec '
            apk add --no-cache busybox-static >/dev/null
            mkdir -p /output/bin
            busybox_path=""
            for candidate in /bin/busybox.static /busybox.static /bin/busybox; do
                if [ -x "$candidate" ]; then
                    busybox_path="$candidate"
                    break
                fi
            done
            [ -n "$busybox_path" ]
            cp "$busybox_path" /output/bin/busybox
            chown "$HOST_UID:$HOST_GID" /output/bin/busybox
        '; then
            if [ -s "$BUILD_DIR/bin/busybox" ] \
               && busybox_is_static "$BUILD_DIR/bin/busybox"; then
                chmod +x "$BUILD_DIR/bin/busybox"
                return 0
            fi
        fi
        echo "Docker busybox build failed; trying another fallback."
    fi

    # Tier 3: host package manager (apt-get / dnf).
    if install_busybox_via_pkg "$BUILD_DIR/bin/busybox"; then
        chmod +x "$BUILD_DIR/bin/busybox"
        return 0
    fi

    # Tier 4: host busybox binary, but never accept a dynamic binary because
    # the initramfs does not copy its runtime libraries.
    if command -v busybox >/dev/null 2>&1; then
        local host_busybox
        host_busybox=$(command -v busybox)
        if busybox_is_static "$host_busybox"; then
            cp "$host_busybox" "$BUILD_DIR/bin/busybox"
            chmod +x "$BUILD_DIR/bin/busybox"
            return 0
        fi
        echo "Host busybox is not statically linked; refusing to use it." >&2
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

# Busybox modprobe cannot decompress module files, so expand any compressed
# (.ko.xz/.ko.zst) modules that were staged and strip the compression suffix
# from modules.dep, which busybox uses to resolve module paths.
decompress_staged_modules() {
    local dst="$1"
    local expanded=0
    local mod plain tmp
    while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        plain="${mod%.xz}"
        case "$mod" in
            *.ko.xz)
                tmp="${mod}.expanded"
                xz -dc "$mod" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
                plain="${mod%.xz}"
                ;;
            *.ko.zst)
                tmp="${mod}.expanded"
                zstd -q -dc "$mod" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
                plain="${mod%.zst}"
                ;;
            *) continue ;;
        esac
        mv -f "$tmp" "$plain"
        rm -f "$mod"
        expanded=1
    done < <(find "$dst/kernel" -type f \( -name '*.ko.xz' -o -name '*.ko.zst' \) 2>/dev/null)
    if [ "$expanded" -eq 1 ]; then
        # Not anchored to end-of-line: modules.dep entries end with ':'.
        sed -E -i 's/\.(xz|zst)//g' "$dst/modules.dep" 2>/dev/null || true
    fi

    local remaining
    remaining=$(find "$dst/kernel" -type f \( -name '*.ko.xz' -o -name '*.ko.zst' \) 2>/dev/null)
    if [ -n "$remaining" ]; then
        echo "ERROR: compressed kernel modules remain; xz and zstd are required to build the initramfs:" >&2
        printf '%s\n' "$remaining" >&2
        return 1
    fi
}

# Stage kernel filesystem modules (xfs/btrfs/ext4 and fat/vfat) and the NVMe
# driver modules so the chroot bootloader step can mount the written Fedora
# image (including its EFI System Partition) and so the target NVMe is visible
# after kexec even when the running kernel has NVMe support as modules (e.g.
# Fedora). Modules are kernel-version-specific, so the build host's matching
# modules are copied as a reasonable default.
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
    # xfs/btrfs/ext4: the OS root and its btrfs sibling subvolumes.
    # fat (contains fat.ko + vfat.ko): the EFI System Partition that
    # grub2-install writes the bootloader to.
    local deps=0 fsdir
    for fsdir in xfs btrfs ext4 fat; do
        if [ -d "$src/kernel/fs/$fsdir" ]; then
            echo "  - $fsdir"
            cp -a "$src/kernel/fs/$fsdir" "$dst/kernel/fs/"
            deps=1
        fi
    done
    # NVMe driver (nvme-core, nvme, nvme-auth, nvme-keyring, ...). Without
    # these the target device may not appear after kexec on distros that build
    # NVMe support as modules.
    if [ -d "$src/kernel/drivers/nvme" ]; then
        echo "  - nvme (drivers)"
        mkdir -p "$dst/kernel/drivers"
        cp -a "$src/kernel/drivers/nvme" "$dst/kernel/drivers/"
        deps=1
    fi
    # Minimal metadata so modprobe can resolve the staged modules.
    mkdir -p "$dst"
    for f in modules.dep modules.dep.bin modules.builtin modules.builtin.bin modules.alias modules.alias.bin modules.symbols; do
        [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f" 2>/dev/null || true
    done
    # Resolve and copy transitive module dependencies (e.g. nls_cp437/nls_ascii
    # for vfat, hkdf for nvme-auth) so busybox modprobe can load them after
    # kexec.
    if [ "$deps" -eq 1 ]; then
        local mod
        for mod in $(cd "$dst" && find kernel -name '*.ko*' 2>/dev/null); do
            copy_module_with_deps "$mod" "$src" "$dst"
        done
    fi
    # busybox modprobe cannot load compressed modules.
    decompress_staged_modules "$dst"
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
    for dep in cpio gzip xz zstd; do
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
    if ! busybox_is_static "$BUILD_DIR/bin/busybox"; then
        echo "ERROR: initramfs requires a statically linked busybox." >&2
        exit 1
    fi

    # Create busybox symlinks. partprobe and blockdev are busybox applets and
    # cover the Fedora install path (partition rescans) without needing host
    # util-linux copies in the initramfs.
    cd "$BUILD_DIR/bin"
    for cmd in ash sh bash mount umount mountpoint mkdir cat cp echo ls grep sed mknod sleep \
               reboot poweroff halt dmesg hexdump head tail wc find df free \
               blkid fdisk partprobe blockdev sync dd chroot sha256sum chmod tr uname rm rmdir \
               xz unlzma lzcat modprobe awk switch_root timeout \
               cut sort basename dirname expr printf seq stat touch; do
        ln -sf busybox "$cmd"
    done
    cd "$REPO_DIR"

    # The kernel auto-loads modules via /sbin/modprobe; ensure the symlink exists.
    mkdir -p "$BUILD_DIR/sbin"
    ln -sf ../bin/busybox "$BUILD_DIR/sbin/modprobe"

    # Install Fedora install support (partprobe/blockdev busybox applets were
    # symlinked above; host xz/unlzma come via busybox too).
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
