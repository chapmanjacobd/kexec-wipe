#!/bin/bash
#
# Local integration test: boot the kexec-wipe initramfs in QEMU, sanitize an
# emulated NVMe (test mode), install a fake "Fedora" image over HTTP, and boot
# into the freshly written root.
#
# This mirrors the CI "QEMU Fedora install test" job but runs against a local
# qemu + host kernel so it can be iterated without pushing to GitHub.
#
# Usage:
#   ./initramfs/build.sh --output=/tmp/initramfs.cpio.gz
#   scripts/qemu-install-test.sh --initrd=/tmp/initramfs.cpio.gz
#
# Requirements: qemu-system-x86_64, sudo (losetup), curl/xz, python3, cpio, gzip
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

INITRD=""
KERNEL=""
OUT_DIR="/tmp/kexec-wipe-qemu-test"
MOD_LIST=(kernel/drivers/nvme/host/nvme.ko)

usage() {
    echo "Usage: $0 --initrd=FILE [--kernel=FILE] [--outdir=DIR]" >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --initrd=*) INITRD="${1#--initrd=}" ;;
            --kernel=*) KERNEL="${1#--kernel=}" ;;
            --outdir=*) OUT_DIR="${1#--outdir=}" ;;
            *) usage ;;
        esac
        shift
    done
    [ -n "$INITRD" ] || usage
    if [ -z "$KERNEL" ]; then
        # Prefer the running kernel, whose modules were staged into the initramfs.
        KERNEL="/boot/vmlinuz-$(uname -r)"
        [ -f "$KERNEL" ] || KERNEL="$(ls /boot/vmlinuz-* | head -1)"
    fi
}

# Recursively stage a kernel module and its dependencies from modules.dep,
# decompressing .ko.xz/.ko.zst to .ko so busybox modprobe can load them.
stage_modules() {
    local src="$1" dst="$2"
    local -A staged

    stage_one() {
        local depfile="$1"
        [ -n "$depfile" ] || return 0
        local srcfile="$src/$depfile"
        if [ -f "$srcfile" ] && [ "${staged[$depfile]:-}" != "1" ]; then
            local plain="${depfile%.xz}"
            plain="${plain%.zst}"
            staged[$depfile]=1
            local dstfile="$dst/$plain"
            mkdir -p "$(dirname "$dstfile")"
            case "$depfile" in
                *.xz)  xz -dc "$srcfile" > "$dstfile" ;;
                *.zst) zstd -dc "$srcfile" > "$dstfile" 2>/dev/null || zcat "$srcfile" > "$dstfile" ;;
                *)     cp -a "$srcfile" "$dstfile" ;;
            esac
            local line deps
            line=$(grep "^$depfile:" "$src/modules.dep" 2>/dev/null || true)
            deps="${line#*: }"
            local d
            for d in $deps; do
                stage_one "$d"
            done
        fi
    }

    local mod
    for mod in "${MOD_LIST[@]}"; do
        # Allow both .ko and compressed variants.
        for cand in "$src/$mod" "$src/$mod.xz" "$src/$mod.zst"; do
            [ -f "$cand" ] && stage_one "${cand#"$src"/}"
        done
    done

    # Rewrite modules.dep so it references uncompressed .ko files.
    sed -E 's/\.(xz|zst)//g' "$src/modules.dep" > "$dst/modules.dep" 2>/dev/null || true
    for f in modules.dep.bin modules.builtin modules.builtin.bin modules.alias modules.alias.bin modules.symbols modules.softdep; do
        [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f" 2>/dev/null || true
    done
}

prepare_initramfs() {
    local kver
    kver=$(uname -r)
    local src="/lib/modules/$kver"
    local wdir="$OUT_DIR/initramfs"
    local dst="$wdir/lib/modules/$kver"

    echo "==> Extracting initramfs"
    rm -rf "$wdir"
    mkdir -p "$wdir"
    cd "$wdir"
    zcat "$INITRD" | cpio -idm 2>/dev/null

    mkdir -p "$dst"
    echo "==> Staging kernel modules ($kver)"
    stage_modules "$src" "$dst"

    cd /
    echo "==> Repacking test initramfs"
    ( cd "$wdir" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUT_DIR/install-initramfs.cpio.gz" )
}

build_fake_fedora() {
    echo "==> Building fake Fedora raw image"
    local raw="$OUT_DIR/fedora.raw"
    rm -f "$raw" "$raw.xz"
    dd if=/dev/zero of="$raw" bs=1M count=96 status=none
    printf 'o\nn\np\n1\n\n+80M\nw\n' | fdisk "$raw" >/dev/null 2>&1
    local loop
    loop=$(sudo losetup -fP --show "$raw")
    sudo partprobe "$loop" 2>/dev/null || true
    sleep 1
    sudo mkfs.ext4 -q "${loop}p1"

    local root=$OUT_DIR/fedora-root
    rm -rf "$root"
    mkdir -p "$root"
    sudo mount "${loop}p1" "$root"
    sudo mkdir -p "$root"/{bin,sbin,dev,proc,sys,boot/grub2}
    sudo cp "$OUT_DIR/initramfs/bin/busybox" "$root/bin/busybox"
    sudo ln -sf busybox "$root/bin/sh"
    sudo touch "$root/boot/grub2/grub.cfg"
    printf '%s\n' '#!/bin/sh' \
        'echo "KEXEC-WIPE-TEST-INSTALL-BOOT-OK"' \
        '/bin/busybox sync' \
        '/bin/busybox sleep 1' \
        '/bin/busybox poweroff -f' > "$OUT_DIR/fedora-init"
    sudo cp "$OUT_DIR/fedora-init" "$root/sbin/init"
    sudo chmod +x "$root/sbin/init"
    sudo umount "$root"
    sudo losetup -d "$loop"

    xz -c "$raw" > "$raw.xz"
}

# Embed the fake Fedora .xz into a copy of the staged initramfs, mirroring how
# wipe.sh hands the image to the initramfs (lib/kexec.sh augment_initramfs).
embed_fedora() {
    echo "==> Embedding Fedora image into initramfs"
    local work="$OUT_DIR/augment"
    rm -rf "$work"
    mkdir -p "$work"
    gzip -dc "$OUT_DIR/install-initramfs.cpio.gz" | ( cd "$work" && cpio -idm 2>/dev/null )

    local dest="$work/opt"
    mkdir -p "$dest"
    cp "$OUT_DIR/fedora.raw.xz" "$dest/fedora.raw.xz"

    ( cd "$work" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUT_DIR/augmented-initramfs.cpio.gz" )
    rm -rf "$work"
}

run_qemu() {
    echo "==> Booting QEMU (timeout 150s)"
    rm -f "$OUT_DIR/install-disk.qcow2"
    qemu-img create -f qcow2 "$OUT_DIR/install-disk.qcow2" 128M >/dev/null

    timeout 150 qemu-system-x86_64 \
        -kernel "$KERNEL" \
        -initrd "$OUT_DIR/augmented-initramfs.cpio.gz" \
        -append "console=ttyS0 kexec_wipe_dev=/dev/nvme0n1 kexec_wipe_method=auto kexec_wipe_install=1 kexec_wipe_test=1 kexec_wipe_fedora_image=/opt/fedora.raw.xz" \
        -nographic -no-reboot -m 512 \
        -drive file="$OUT_DIR/install-disk.qcow2",if=none,id=nvme0 \
        -device nvme,serial=deadbeef,drive=nvme0 \
        > "$OUT_DIR/install-serial.log" 2>&1 || true

    echo "=== INSTALL SERIAL OUTPUT ==="
    cat "$OUT_DIR/install-serial.log"
    echo "=== END ==="
}

check() {
    local ok=1
    grep -q "Fedora installation complete" "$OUT_DIR/install-serial.log" || ok=0
    grep -q "KEXEC-WIPE-TEST-INSTALL-BOOT-OK" "$OUT_DIR/install-serial.log" || ok=0
    grep -q "Drive /dev/nvme0n1 has been sanitized" "$OUT_DIR/install-serial.log" || ok=0
    if [ "$ok" -eq 1 ]; then
        echo "PASS: full install pipeline verified."
    else
        echo "FAIL: missing expected markers in serial output." >&2
        exit 1
    fi
}

main() {
    parse_args "$@"
    mkdir -p "$OUT_DIR"
    prepare_initramfs
    build_fake_fedora
    embed_fedora
    run_qemu
    check
}

main "$@"
