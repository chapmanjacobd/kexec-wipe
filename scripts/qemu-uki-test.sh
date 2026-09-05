#!/bin/bash
#
# QEMU test for the UKI kexec path on aarch64: proves that
#     kexec -l <uki.efi> --initrd=<ours>
# boots <ours> /init rather than the UKI's embedded initrd. This validates the
# .efi branch of lib/kexec.sh, which is how kexec-wipe loads Unified Kernel
# Images (UKI) on aarch64.
#
# It builds a UKI from the host kernel plus a deliberately different "embedded"
# initramfs, boots a stage-1 initramfs that kexec's into that UKI with a second
# ("ours") initramfs, then checks the serial log for the markers.
#
# This must run on an aarch64 host: it embeds the host kernel in the UKI and
# relies on the host kexec-tools being able to unpack a UKI (arm64 support
# landed in kexec-tools 2.0.30). The CI runs it on ubuntu-26.04-arm, whose
# distro kexec-tools is new enough. It is intentionally not run on x86_64
# (Ubuntu LTS x86_64 runners still ship kexec-tools without UKI support).
#
# Requires: an aarch64 host, qemu-system-aarch64, busybox, kexec-tools,
# binutils (objcopy), cpio, gzip, and a systemd UKI stub
# (linuxaa64.efi.stub, e.g. from systemd-boot).
#
# Usage:
#   scripts/qemu-uki-test.sh [--kernel=/boot/vmlinuz-...] [--outdir=/tmp/...]
#
set -euo pipefail

KERNEL=""
OUT_DIR="/tmp/kexec-wipe-uki-test"
STUB=""

usage() {
    echo "Usage: $0 [--kernel=FILE] [--outdir=DIR]" >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel=*) KERNEL="${1#--kernel=}" ;;
            --outdir=*) OUT_DIR="${1#--outdir=}" ;;
            *) usage ;;
        esac
        shift
    done
    if [ -z "$KERNEL" ]; then
        KERNEL="/boot/vmlinuz-$(uname -r)"
        [ -f "$KERNEL" ] || KERNEL="$(ls /boot/vmlinuz-* 2>/dev/null | head -1)"
    fi
    [ -n "$KERNEL" ] && [ -f "$KERNEL" ] || { echo "ERROR: kernel not found" >&2; exit 1; }
}

require_tools() {
    local missing=()
    for t in qemu-system-aarch64 cpio gzip objcopy busybox kexec ldd; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || { echo "ERROR: missing tools: ${missing[*]}" >&2; exit 1; }
}

# kexec-tools gained arm64 UKI (PE .linux section) support in 2.0.30. Older
# versions fail with "Cannot determine the file type" at kexec -l time.
check_kexec_version() {
    local v maj minor patch num
    v=$(kexec --version 2>&1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$v" ] || { echo "ERROR: could not parse kexec --version" >&2; exit 1; }
    maj=${v%%.*}
    minor=${v#*.}; minor=${minor%%.*}
    patch=${v##*.}
    num=$(( maj * 100000 + minor * 1000 + patch ))
    if [ "$num" -ge 200030 ]; then
        echo "Using kexec-tools ${v} (>= 2.0.30, has arm64 UKI support)"
    else
        echo "ERROR: kexec-tools ${v} cannot load a UKI on arm64 (need >= 2.0.30)" >&2
        exit 1
    fi
}

find_stub() {
    local c
    c=$(find /usr/lib /lib -name 'linuxaa64.efi.stub' 2>/dev/null | head -1)
    [ -n "$c" ] || { echo "ERROR: systemd UKI stub (linuxaa64.efi.stub) not found; install systemd-boot" >&2; exit 1; }
    STUB="$c"
}

# Build a tiny initramfs whose /init prints MARKER and powers off.
make_marker_initramfs() {
    local marker="$1" out="$2"
    local w="$OUT_DIR/marker"
    rm -rf "$w"
    mkdir -p "$w/bin"
    cp "$(command -v busybox)" "$w/bin/busybox"
    chmod +x "$w/bin/busybox"
    for app in sh echo poweroff; do
        ln -sf busybox "$w/bin/$app"
    done
    cat > "$w/init" <<EOF
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
echo "$marker"
poweroff -f
EOF
    chmod +x "$w/init"
    ( cd "$w" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$out" )
    rm -rf "$w"
}

build_uki() {
    local w="$OUT_DIR/uki"
    rm -rf "$w"
    mkdir -p "$w"

    # The embedded initrd must NOT win; if it runs, the test fails.
    make_marker_initramfs "KEXEC-WIPE-UKI-EMBEDDED-INITRD-RAN" "$w/embedded.cpio.gz"

    printf 'console=ttyAMA0\n' > "$w/cmdline"
    cp /etc/os-release "$w/os-release" 2>/dev/null || printf 'ID=test\n' > "$w/os-release"

    objcopy \
        --add-section .osrel="$w/os-release" --change-section-vma .osrel=0x20000 \
        --add-section .cmdline="$w/cmdline" --change-section-vma .cmdline=0x30000 \
        --add-section .linux="$KERNEL" --change-section-vma .linux=0x2000000 \
        --add-section .initrd="$w/embedded.cpio.gz" --change-section-vma .initrd=0x3000000 \
        "$STUB" "$OUT_DIR/uki.efi"

    rm -rf "$w"
}

# Copy a dynamically-linked binary plus its shared libraries and the ELF
# interpreter into the stage-1 build tree.
copy_bin_with_libs() {
    local bin="$1" build="$2"
    cp "$bin" "$build/bin/"
    local resolved
    ldd "$bin" 2>/dev/null | while IFS= read -r line; do
        resolved=$(echo "$line" | sed -n 's/.*=> \([^ ]*\).*/\1/p')
        [ -z "$resolved" ] && resolved=$(echo "$line" | awk '{print $1}')
        case "$resolved" in
            /*) [ -f "$resolved" ] && [ ! -e "$build/lib/$(basename "$resolved")" ] && cp -L "$resolved" "$build/lib/" || true ;;
        esac
    done
    local ld
    ld=$(ldd "$bin" 2>/dev/null | awk '/ld-linux/ {print $1}' | head -1)
    if [ -n "$ld" ] && [ -f "$ld" ]; then
        mkdir -p "$build/lib64"
        [ -e "$build/lib/$(basename "$ld")" ] || cp -L "$ld" "$build/lib/$(basename "$ld")"
        [ -e "$build/lib64/$(basename "$ld")" ] || cp -L "$ld" "$build/lib64/$(basename "$ld")"
    fi
}

build_stage1() {
    local w="$OUT_DIR/stage1"
    rm -rf "$w"
    mkdir -p "$w"/{bin,lib,lib64,proc,sys,dev,tmp}

    cp "$(command -v busybox)" "$w/bin/busybox"
    chmod +x "$w/bin/busybox"
    for app in sh mount echo poweroff ls cat; do
        ln -sf busybox "$w/bin/$app"
    done

    copy_bin_with_libs "$(command -v kexec)" "$w"

    cp "$OUT_DIR/uki.efi" "$w/uki.efi"
    cp "$OUT_DIR/ours.cpio.gz" "$w/ours.cpio.gz"

    cat > "$w/init" <<'EOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/lib
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
echo "KEXEC-WIPE-UKI-STAGE1-START"
kexec -l /uki.efi --initrd=/ours.cpio.gz --command-line="console=ttyAMA0" \
    || { echo "KEXEC-WIPE-UKI-KEXEC-LOAD-FAILED"; poweroff -f; }
echo "KEXEC-WIPE-UKI-KEXEC-LOADED"
kexec -e
echo "KEXEC-WIPE-UKI-KEXEC-FAILED"
poweroff -f
EOF
    chmod +x "$w/init"

    ( cd "$w" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUT_DIR/stage1.cpio.gz" )
    rm -rf "$w"
}

run_qemu() {
    rm -f "$OUT_DIR/serial.log"
    timeout 300 qemu-system-aarch64 \
        -machine virt -cpu max -m 1024 \
        -kernel "$KERNEL" \
        -initrd "$OUT_DIR/stage1.cpio.gz" \
        -append "console=ttyAMA0" \
        -nographic -no-reboot \
        > "$OUT_DIR/serial.log" 2>&1 || true
}

check() {
    local log="$OUT_DIR/serial.log"
    echo "=== SERIAL OUTPUT ==="
    cat "$log"
    echo "=== END ==="

    local ok=1
    grep -q "KEXEC-WIPE-UKI-STAGE1-START" "$log" || { echo "FAIL: stage1 did not start" >&2; ok=0; }
    grep -q "KEXEC-WIPE-UKI-KEXEC-LOADED" "$log" || { echo "FAIL: kexec -l did not succeed" >&2; ok=0; }
    grep -q "KEXEC-WIPE-UKI-BOOT-OK" "$log" || { echo "FAIL: our initrd did not boot" >&2; ok=0; }
    if grep -q "KEXEC-WIPE-UKI-EMBEDDED-INITRD-RAN" "$log"; then
        echo "FAIL: the UKI's embedded initrd ran instead of ours" >&2
        ok=0
    fi
    if grep -q "KEXEC-WIPE-UKI-KEXEC-LOAD-FAILED" "$log"; then
        echo "FAIL: kexec -l rejected the UKI (or --initrd)" >&2
        ok=0
    fi
    if grep -q "Cannot determine the file type" "$log"; then
        echo "FAIL: kexec-tools could not recognize the UKI; needs >= 2.0.30 (arm64)" >&2
        ok=0
    fi
    if grep -q "KEXEC-WIPE-UKI-KEXEC-FAILED" "$log"; then
        echo "FAIL: kexec -e failed" >&2
        ok=0
    fi
    [ "$ok" -eq 1 ] || { echo "FAIL: UKI kexec test" >&2; exit 1; }
    echo "PASS: UKI kexec loads our initrd and boots it"
}

main() {
    [ "$(uname -m)" = "aarch64" ] || { echo "ERROR: the UKI kexec test must run on an aarch64 host" >&2; exit 1; }
    parse_args "$@"
    require_tools
    check_kexec_version
    find_stub
    mkdir -p "$OUT_DIR"
    make_marker_initramfs "KEXEC-WIPE-UKI-BOOT-OK" "$OUT_DIR/ours.cpio.gz"
    build_uki
    build_stage1
    run_qemu
    check
}

main "$@"