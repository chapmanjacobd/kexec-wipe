#!/bin/bash
#
# Full end-to-end QEMU test for `wipe.sh /dev/nvme0n1 --install-fedora`.
#
# This is the real thing, not a stub:
#   1. Boots an actual Fedora Cloud guest on a virtual NVMe (qcow2 file).
#   2. Inside the guest runs the real wipe.sh, which builds a guest-kernel-
#      matched initramfs, embeds the real Fedora Cloud raw image, kexec's into
#      the minimal environment, writes the image, installs GRUB (handling the
#      btrfs root/home/boot/var subvolumes), provisions a user + ssh keys,
#      and switch_root's into the fresh Fedora.
#   3. Reboots the VM and verifies the installed Fedora boots cleanly via GRUB
#      and that you can ssh in as the provisioned user.
#
# The guest's NVMe is backed only by a qcow2 file. NO host block device is ever
# attached to QEMU; the host's real NVMe is never touched.
#
# Requires: qemu-system-x86_64, qemu-img, an OVMF firmware, genisoimage/mkisofs,
#           curl, ssh, and an ssh key at ~/.ssh/id_ed25519.pub (or id_rsa.pub).
# The guest itself needs internet access (QEMU user networking) to download the
# Fedora image and busybox. Roughly 10 GB of disk space in the workdir.
#
# Usage:
#   scripts/qemu-full-install-test.sh
#   scripts/qemu-full-install-test.sh --workdir=/tmp/foo --port=2223 --skip-boot-check
#
# Options:
#   --workdir=DIR    Scratch directory (default: /tmp/kexec-wipe-full-test)
#   --port=N         Host ssh forward port (default: 2222)
#   --mem=MB         Guest RAM (default: 8192)
#   --skip-boot-check  Skip the clean-reboot + ssh verification phase
#   --keep           Do not remove the workdir on exit
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

WORKDIR="/tmp/kexec-wipe-full-test"
PORT=2222
MEM=8192
DISK_SIZE=12G
SKIP_BOOT_CHECK=0
KEEP=0
ARCH="x86_64"
GUEST_USER="fedora"
PROVISION_USER="fedora"

# ---------------------------------------------------------------------------
# Host tooling / environment
# ---------------------------------------------------------------------------

OVMF_CODE=""
OVMF_VARS=""

find_ovmf() {
    for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do
        [ -f "$c" ] && { OVMF_CODE="$c"; break; }
    done
    for v in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do
        [ -f "$v" ] && { OVMF_VARS="$v"; break; }
    done
    [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: OVMF firmware not found" >&2; exit 1; }
}

SSH_PUBKEY=""
SSH_PRIVKEY=""

find_ssh_key() {
    for p in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        if [ -f "$p" ] && [ -f "$p.pub" ]; then
            SSH_PRIVKEY="$p"
            SSH_PUBKEY="$p.pub"
            return 0
        fi
    done
    echo "ERROR: no ssh key found at ~/.ssh/id_ed25519(.pub) or id_rsa(.pub)" >&2
    exit 1
}

require_tools() {
    local missing=()
    for t in qemu-system-x86_64 qemu-img curl sha256sum ssh cpio gzip genisoimage mkisofs xorriso; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # Need at least one iso tool; the check above is satisfied by any one of them.
    if ! command -v genisoimage >/dev/null 2>&1 \
       && ! command -v mkisofs >/dev/null 2>&1 \
       && ! command -v xorriso >/dev/null 2>&1; then
        echo "ERROR: need genisoimage, mkisofs or xorriso to build the seed ISO" >&2
        exit 1
    fi
    [ ${#missing[@]} -eq 0 ] || { echo "ERROR: missing tools: ${missing[*]}" >&2; exit 1; }
}

iso_tool() {
    command -v genisoimage || command -v mkisofs || command -v xorriso
}

# ---------------------------------------------------------------------------
# Pinned asset URLs/checksums (kept in sync with lib/kexec.sh)
# ---------------------------------------------------------------------------
source "${REPO_DIR}/lib/kexec.sh" 2>/dev/null || true

FEDORA_URL=""
FEDORA_SHA256=""

fedora_pins() {
    FEDORA_URL="${INSTALL_FEDORA_BASE}/${ARCH}/images/Fedora-Cloud-Base-AmazonEC2-${INSTALL_FEDORA_RELEASE}-${INSTALL_FEDORA_CURRENT}.${ARCH}.raw.xz"
    case "$ARCH" in
        aarch64) FEDORA_SHA256="$INSTALL_FEDORA_SHA256_aarch64" ;;
        *)       FEDORA_SHA256="$INSTALL_FEDORA_SHA256_x86_64" ;;
    esac
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

download_fedora() {
    local dest="$WORKDIR/fedora.raw.xz"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | awk '{print $1}')" = "$FEDORA_SHA256" ]; then
        echo "==> Using cached Fedora image"
        return 0
    fi
    echo "==> Downloading $FEDORA_URL"
    curl -fsSL --retry 3 "$FEDORA_URL" -o "$dest"
    local got
    got=$(sha256sum "$dest" | awk '{print $1}')
    [ "$got" = "$FEDORA_SHA256" ] || { echo "ERROR: Fedora image checksum mismatch ($got != $FEDORA_SHA256)" >&2; exit 1; }
}

make_disk() {
    echo "==> Creating virtual NVMe ($DISK_SIZE)"
    echo "==> Decompressing raw image (5 GB)"
    xz -dc "$WORKDIR/fedora.raw.xz" > "$WORKDIR/fedora.raw"
    rm -f "$WORKDIR/nvme.qcow2"
    qemu-img convert -f raw -O qcow2 "$WORKDIR/fedora.raw" "$WORKDIR/nvme.qcow2"
    qemu-img resize "$WORKDIR/nvme.qcow2" "$DISK_SIZE"
    rm -f "$WORKDIR/fedora.raw"
}

make_seed() {
    echo "==> Building cloud-init seed ISO"
    local seeddir="$WORKDIR/seed"
    rm -rf "$seeddir"
    mkdir -p "$seeddir"
    cat > "$seeddir/user-data" <<EOF
#cloud-config
hostname: qemu-host
manage_etc_hosts: true
users:
  - name: $GUEST_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_PUBKEY")
    shell: /bin/bash
  - name: root
    ssh_authorized_keys:
      - $(cat "$SSH_PUBKEY")
chpasswd:
  list: |
    root:kexecwipetest
  expire: false
ssh_pwauth: true
runcmd:
  - systemctl enable serial-getty@ttyS0.service
  - grubby --update-kernel=ALL --args="console=ttyS0,115200n8" || true
  - dnf -y install kexec-tools nvme-cli xz
  - echo "PHASE1-SETUP-DONE"
EOF
    printf 'instance-id: kexec-wipe-full-test\nlocal-hostname: qemu-host\n' > "$seeddir/meta-data"
    $(iso_tool) -output "$WORKDIR/seed.iso" -volid cidata -joliet -rock \
        "$seeddir/user-data" "$seeddir/meta-data" >/dev/null 2>&1
}

# QEMU_PID, QEMU_MON, SERIAL_LOG are globals set by boot_vm.
QEMU_PID=""
QEMU_MON=""
SERIAL_LOG=""
BOOT_SEED=0

boot_vm() {
    local with_seed="$1"
    local pflash_vars="$WORKDIR/OVMF_VARS.fd"
    cp "$OVMF_VARS" "$pflash_vars"
    SERIAL_LOG="$WORKDIR/serial-$(date +%s).log"
    QEMU_MON="$WORKDIR/mon-$(date +%s).sock"

    local args=(
        -machine q35,accel=kvm
        -cpu host -smp 4 -m "$MEM"
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$pflash_vars"
        -drive "file=$WORKDIR/nvme.qcow2,if=none,id=nvme0"
        -device "nvme,serial=deadbeef,drive=nvme0"
        -netdev "user,id=net0,hostfwd=tcp::$PORT-:22"
        -device virtio-net-pci,netdev=net0
        -serial "file:$SERIAL_LOG"
        -monitor "unix:$QEMU_MON,server,nowait"
        -nographic -no-reboot
    )
    if [ "$with_seed" -eq 1 ]; then
        args+=(-drive "file=$WORKDIR/seed.iso,if=virtio,format=raw,readonly=on")
    fi

    echo "==> Booting QEMU (seed=$with_seed)"
    setsid nohup qemu-system-x86_64 "${args[@]}" >/dev/null 2>&1 &
    QEMU_PID=$!
}

stop_vm() {
    if [ -S "$QEMU_MON" ]; then
        printf 'system_powerdown\n' | socat - "unix-connect:$QEMU_MON" >/dev/null 2>&1 || true
        sleep 5
    fi
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
}

root_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -i "$SSH_PRIVKEY" \
        -o ConnectTimeout=6 root@127.0.0.1 -p "$PORT" "$@"
}

user_ssh() {
    local user="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -i "$SSH_PRIVKEY" \
        -o ConnectTimeout=6 "$user@127.0.0.1" -p "$PORT" "$@"
}

wait_guest_ssh() {
    echo "==> Waiting for guest ssh (root)"
    local tries=0
    until root_ssh 'echo UP' 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt 90 ] && { echo "ERROR: guest ssh did not come up" >&2; exit 1; }
        sleep 5
    done
}

wait_phase1() {
    echo "==> Waiting for Phase-1 setup (kexec-tools/nvme-cli)"
    local tries=0
    until root_ssh 'grep -q PHASE1-SETUP-DONE /var/log/cloud-init-output.log' 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt 60 ] && { echo "ERROR: Phase-1 setup timed out" >&2; exit 1; }
        sleep 5
    done
    echo "==> Phase-1 setup done"
}

prepare_guest() {
    echo "==> Building wipe.sh"
    ( cd "$REPO_DIR" && ./build.sh >/dev/null )

    echo "==> Building initramfs in guest (matches guest kernel)"
    tar czf - -C "$REPO_DIR" initramfs | root_ssh \
        'rm -rf /opt/kw-initramfs && mkdir -p /opt/kw-initramfs && \
         tar xzf - -C /opt/kw-initramfs && cd /opt/kw-initramfs/initramfs && \
         bash build.sh --output=/root/kexec-wipe-initramfs-x86_64.cpio.gz' \
        | tail -2

    echo "==> Installing wipe.sh in guest"
    local newsha
    newsha=$(root_ssh 'sha256sum /root/kexec-wipe-initramfs-x86_64.cpio.gz' | awk '{print $1}')
    # Build a guest-local variant of wipe.sh that points at the locally built,
    # kernel-matched initramfs and puts the kexec console on ttyS0.
    sed -e "s|^INITRAMFS_URL_x86_64=.*|INITRAMFS_URL_x86_64=\"file:///root/kexec-wipe-initramfs-x86_64.cpio.gz\"|" \
        -e "s|^INITRAMFS_SHA256_x86_64=.*|INITRAMFS_SHA256_x86_64=\"$newsha\"|" \
        -e 's|cmdline="root=/dev/ram rw quiet panic=10"|cmdline="root=/dev/ram rw quiet panic=10 console=ttyS0,115200n8"|' \
        "$REPO_DIR/wipe.sh" \
        | root_ssh 'cat > /root/wipe.sh && chmod +x /root/wipe.sh && bash -n /root/wipe.sh'

    echo "==> Ensuring /root/.ssh/authorized_keys is present for user provisioning"
    cat "$SSH_PUBKEY" | root_ssh \
        'mkdir -p /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
}

run_wipe() {
    echo "==> Running wipe.sh /dev/nvme0n1 --install-fedora --test-mode"
    # Run as root, but with SUDO_USER set so the provisioned user is $PROVISION_USER.
    root_ssh "echo YES | SUDO_USER=$PROVISION_USER nohup bash -c 'bash /root/wipe.sh /dev/nvme0n1 --install-fedora --test-mode > /root/wipe-run.log 2>&1' &" \
        >/dev/null 2>&1 || true
}

check_serial() {
    echo "==> Waiting for pipeline to complete (up to ~10 min)"
    local tries=0
    until grep -q "Switching root into Fedora" "$SERIAL_LOG" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt 120 ] && { echo "ERROR: pipeline did not reach switch_root" >&2; tail -30 "$SERIAL_LOG"; exit 1; }
        sleep 5
    done

    local ok=1
    local markers=(
        "Fedora image written"
        "GRUB installed successfully"
        "Created user"
        "Copied authorized_keys"
        "User provisioning complete"
        "Switching root into Fedora"
    )
    for marker in "${markers[@]}"; do
        if grep -q "$marker" "$SERIAL_LOG"; then
            echo "OK: $marker"
        else
            echo "FAIL: missing '$marker'" >&2
            ok=0
        fi
    done
    [ "$ok" -eq 1 ] || { echo "ERROR: pipeline markers missing" >&2; exit 1; }

    echo "==> Waiting for the freshly installed Fedora to boot"
    local switch_line
    switch_line=$(grep -n "Switching root into Fedora" "$SERIAL_LOG" | tail -1 | cut -d: -f1)
    tries=0
    # Accept either the login banner or a reboot (the first boot may run the
    # SELinux autorelabel and reboot before getty prints the banner).
    until grep -n "Fedora Linux 44" "$SERIAL_LOG" 2>/dev/null \
            | awk -F: -v s="$switch_line" '$1 > s' | grep -q . \
          || ! kill -0 "$QEMU_PID" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt 90 ] && { echo "ERROR: fresh Fedora did not boot" >&2; exit 1; }
        sleep 5
    done
    echo "PASS: install pipeline complete, fresh Fedora started booting"
}

verify_boot() {
    echo "==> Clean reboot of the installed Fedora (GRUB + own initramfs)"
    stop_vm
    sleep 3
    boot_vm 0

    # The first boot may run the SELinux autorelabel (scheduled by the tool),
    # which relabels the filesystem and reboots, exiting QEMU (-no-reboot).
    # Detect that and relaunch once.
    local tries=0
    while [ "$tries" -lt 90 ]; do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "==> VM exited (autorelabel reboot); relaunching"
            sleep 3
            boot_vm 0
            tries=$((tries + 1))
            sleep 5
            continue
        fi
        if user_ssh "$PROVISION_USER" \
                'test -d "$HOME" && sudo whoami' 2>/dev/null | grep -q root; then
            echo "PASS: installed Fedora boots cleanly and ssh as '$PROVISION_USER' works"
            return 0
        fi
        tries=$((tries + 1))
        sleep 5
    done
    echo "ERROR: installed Fedora ssh verification failed" >&2
    exit 1
}

cleanup() {
    stop_vm
    if [ "$KEEP" -eq 0 ]; then
        rm -rf "$WORKDIR"
    else
        echo "==> Workdir kept at $WORKDIR (--keep)"
    fi
}

usage() {
    sed -n '2,32p' "$0"
    exit 1
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --workdir=*) WORKDIR="${1#--workdir=}" ;;
            --port=*) PORT="${1#--port=}" ;;
            --mem=*) MEM="${1#--mem=}" ;;
            --skip-boot-check) SKIP_BOOT_CHECK=1 ;;
            --keep) KEEP=1 ;;
            --help|-h) usage ;;
            *) echo "Unknown argument: $1" >&2; usage ;;
        esac
        shift
    done

    require_tools
    find_ovmf
    find_ssh_key
    fedora_pins
    mkdir -p "$WORKDIR"

    trap cleanup EXIT

    download_fedora
    make_disk
    make_seed
    boot_vm 1
    wait_guest_ssh
    wait_phase1
    prepare_guest
    run_wipe
    check_serial
    if [ "$SKIP_BOOT_CHECK" -eq 0 ]; then
        verify_boot
    fi
    echo "ALL PASS: full --install-fedora run verified in QEMU"
}

main "$@"