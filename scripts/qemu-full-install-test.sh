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
# Run on x86_64 or aarch64 hosts. On aarch64 the guest is a real Fedora
# aarch64 system, so the UKI kexec path (Fedora arm64 boots Unified Kernel
# Images) is exercised for real as well.
#
# The guest's NVMe is backed only by a qcow2 file. NO host block device is ever
# attached to QEMU; the host's real NVMe is never touched.
#
# Requires: qemu-system-x86_64 (or qemu-system-aarch64 on arm64), qemu-img, an
#           OVMF/AAVMF firmware, genisoimage/mkisofs/xorriso, curl, ssh, socat,
#           and an ssh key at ~/.ssh/id_ed25519.pub (or id_rsa.pub).
# The guest itself needs internet access (QEMU user networking) to download the
# Fedora image and packages. Roughly 10 GB of disk space in the workdir.
#
# Usage:
#   scripts/qemu-full-install-test.sh
#   scripts/qemu-full-install-test.sh --workdir=/tmp/foo --port=2223 --skip-boot-check
#   scripts/qemu-full-install-test.sh --arch=aarch64 --mem=4096   (arm64 host)
#
# Options:
#   --arch=ARCH      x86_64 (default) or aarch64; picks the QEMU binary, machine
#                    type (q35/virt), firmware (OVMF/AAVMF), and serial console
#                    (ttyS0/ttyAMA0). Defaults to the host architecture.
#   --workdir=DIR    Scratch directory (default: /tmp/kexec-wipe-full-test)
#   --port=N         Host ssh forward port (default: 2222)
#   --mem=MB         Guest RAM (default: 8192)
#   --disk-size=S    Virtual NVMe size (default: 12G; the qcow2 is sparse)
#   --skip-boot-check  Skip the clean-reboot + ssh verification phase
#   --skip-install   Skip --install-fedora: run only the sanitize/kexec path
#                    (build the wipe initramfs, kexec into it, reboot). The
#                    minimal path starts wipe.sh from cloud-init and monitors
#                    the serial console instead of setting up guest SSH.
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
SKIP_INSTALL=0
DIRECT_WIPE=0
KEEP=0
ARCH=""
GUEST_USER="fedora"
PROVISION_USER="fedora"

# Polling loops below are sized for KVM. An aarch64 guest cannot use x86 KVM,
# so boot_vm falls back to TCG (software emulation), which is slower and
# flakier; WAIT_MULT scales every wait budget when that happens. The x86_64
# guest uses KVM when it is available.
WAIT_MULT=1

# ---------------------------------------------------------------------------
# Host tooling / environment
# ---------------------------------------------------------------------------

# The arch determines which QEMU binary, machine type, firmware, and serial
# console the guest uses. Default to the host architecture.
host_arch_matching() {
    case "$(uname -m)" in
        aarch64|arm64) echo "aarch64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *) echo "ERROR: unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
    esac
}

qemu_bin() {
    case "$ARCH" in
        aarch64) echo "qemu-system-aarch64" ;;
        *)       echo "qemu-system-x86_64" ;;
    esac
}

# The virtio-net device name differs per machine type: q35 exposes PCIe
# (virtio-net-pci), while the aarch64 virt machine expects an MMIO device.
net_device() {
    case "$ARCH" in
        aarch64) echo "virtio-net-device" ;;
        *)       echo "virtio-net-pci" ;;
    esac
}

serial_console() {
    case "$ARCH" in
        aarch64) echo "ttyAMA0" ;;
        *)       echo "ttyS0" ;;
    esac
}

OVMF_CODE=""
OVMF_VARS=""

find_ovmf() {
    if [ "$ARCH" = "aarch64" ]; then
        for c in /usr/share/AAVMF/AAVMF_CODE_4M.fd /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/AAVMF_CODE.fd; do
            [ -f "$c" ] && { OVMF_CODE="$c"; break; }
        done
        for v in /usr/share/AAVMF/AAVMF_VARS_4M.fd /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/edk2/aarch64/AAVMF_VARS.fd; do
            [ -f "$v" ] && { OVMF_VARS="$v"; break; }
        done
    else
        for c in /usr/share/edk2/ovmf/OVMF_CODE_4M.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
                 /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
            [ -f "$c" ] && { OVMF_CODE="$c"; break; }
        done
        for v in /usr/share/edk2/ovmf/OVMF_VARS_4M.fd /usr/share/edk2/ovmf/OVMF_VARS.fd \
                 /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
            [ -f "$v" ] && { OVMF_VARS="$v"; break; }
        done
    fi
    local fw
    [ "$ARCH" = "aarch64" ] && fw="AAVMF" || fw="OVMF"
    [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "ERROR: $fw firmware not found" >&2; exit 1; }
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
    local qemu
    qemu=$(qemu_bin)
    local missing=()
    local tools=("$qemu" qemu-img curl sha256sum base64 cpio gzip xz socat)
    [ "$DIRECT_WIPE" -eq 0 ] && tools+=(ssh)
    for t in "${tools[@]}"; do
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
    if command -v genisoimage >/dev/null 2>&1; then
        echo "genisoimage"
    elif command -v mkisofs >/dev/null 2>&1; then
        echo "mkisofs"
    elif command -v xorriso >/dev/null 2>&1; then
        echo "xorriso"
    fi
}

# Build a cloud-init seed ISO. xorriso needs `-as mkisofs`; genisoimage/mkisofs
# take the flags directly.
make_iso() {
    local output="$1"
    shift
    local tool
    tool=$(iso_tool) || { echo "ERROR: no ISO tool available" >&2; exit 1; }
    local stderr
    stderr=$(mktemp)
    if [ "$tool" = "xorriso" ]; then
        timeout 30 xorriso -as mkisofs -output "$output" -volid cidata -joliet -rock "$@" 2>"$stderr" || {
            echo "ERROR: iso tool failed (exit $?). stderr:" >&2; cat "$stderr" >&2; rm -f "$stderr"; exit 1
        }
    else
        timeout 30 "$tool" -output "$output" -volid cidata -joliet -rock "$@" 2>"$stderr" || {
            echo "ERROR: $tool failed (exit $?). stderr:" >&2; cat "$stderr" >&2; rm -f "$stderr"; exit 1
        }
    fi
    rm -f "$stderr"
}

# ---------------------------------------------------------------------------
# Pinned asset URLs/checksums are sourced from lib/kexec.sh (the same pins
# wipe.sh embeds). Fail loudly rather than silently building empty URLs if the
# source ever changes shape.
source "${REPO_DIR}/lib/kexec.sh" || { echo "ERROR: cannot source ${REPO_DIR}/lib/kexec.sh for the Fedora pins" >&2; exit 1; }
[ -n "${INSTALL_FEDORA_RELEASE:-}" ] || { echo "ERROR: lib/kexec.sh did not define INSTALL_FEDORA_RELEASE" >&2; exit 1; }

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
    # The firmware variable store is mutated when GRUB registers its boot
    # entry. Start each test with a fresh store, then preserve it across the
    # install and verification boots.
    rm -f "$WORKDIR/OVMF_VARS.fd"
    qemu-img convert -f raw -O qcow2 "$WORKDIR/fedora.raw" "$WORKDIR/nvme.qcow2"
    if [ "$SKIP_INSTALL" -eq 0 ]; then
        qemu-img resize "$WORKDIR/nvme.qcow2" "$DISK_SIZE"
    fi
    rm -f "$WORKDIR/fedora.raw"
}

make_seed() {
    echo "==> Building cloud-init seed ISO"
    local console
    console=$(serial_console)
    # Tools the guest needs for wipe.sh's on-host initramfs build
    # (initramfs/build.sh): nvme-cli, cpio, gzip, xz, and on aarch64 a static
    # busybox (Fedora's busybox package is statically linked; on x86_64 the
    # builder downloads an official static busybox directly instead).
    local dw_pkgs="kexec-tools nvme-cli xz cpio gzip parted"
    [ "$ARCH" = "aarch64" ] && dw_pkgs="${dw_pkgs} busybox"
    local seeddir="$WORKDIR/seed"
    rm -rf "$seeddir"
    mkdir -p "$seeddir"

    if [ "$DIRECT_WIPE" -eq 1 ]; then
        # The minimal job only verifies UKI kexec. Put the already-built script
        # in the seed and let cloud-init launch it, avoiding guest SSH entirely.
        local wipe_b64
        wipe_b64=$(sed -e "s|cmdline=\"root=/dev/ram rw quiet panic=10\"|cmdline=\"root=/dev/ram rw quiet panic=10 console=${console},115200n8\"|" \
            "$REPO_DIR/wipe.sh" | base64 -w0)
        dw_pkgs="kexec-tools nvme-cli xz cpio gzip busybox"
        cat > "$seeddir/user-data" <<EOF
#cloud-config
write_files:
  - path: /root/wipe.sh
    permissions: '0755'
    encoding: b64
    content: |
      $wipe_b64
runcmd:
  - dnf -y install $dw_pkgs
  - echo PHASE1-SETUP-DONE
  - echo YES | KEXEC_WIPE_TEST_MODE=1 bash /root/wipe.sh /dev/nvme0n1 > /root/wipe-run.log 2>&1
EOF
        printf 'instance-id: kexec-wipe-minimal-test\nlocal-hostname: qemu-host\n' > "$seeddir/meta-data"
        make_iso "$WORKDIR/seed.iso" "$seeddir/user-data" "$seeddir/meta-data"
        return 0
    fi

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
  - systemctl enable serial-getty@${console}.service
  - grubby --update-kernel=ALL --args="console=${console},115200n8" || true
  - dnf -y install $dw_pkgs
  - echo "PHASE1-SETUP-DONE"
EOF
    printf 'instance-id: kexec-wipe-full-test\nlocal-hostname: qemu-host\n' > "$seeddir/meta-data"
    make_iso "$WORKDIR/seed.iso" "$seeddir/user-data" "$seeddir/meta-data"
}

# QEMU_PID, QEMU_MON, SERIAL_LOG are globals set by boot_vm.
QEMU_PID=""
QEMU_MON=""
SERIAL_LOG=""

boot_vm() {
    local with_seed="$1"
    local pflash_vars="$WORKDIR/OVMF_VARS.fd"
    [ -f "$pflash_vars" ] || cp "$OVMF_VARS" "$pflash_vars"
    SERIAL_LOG="$WORKDIR/serial-$(date +%s).log"
    QEMU_MON="$WORKDIR/mon-$(date +%s).sock"

    local qemu machine netdev accel cpu
    qemu=$(qemu_bin)
    # GitHub-hosted runners may not expose a usable /dev/kvm: ARM64 runners
    # have none, and x86_64 runners ship it root:kvm 660 until the CI workflow
    # chmod's it. Never spawn QEMU to probe (that can block); just check the
    # device node is openable, and fall back to TCG with a concrete CPU if not.
    accel="kvm"
    cpu="host"
    if [ "$ARCH" = "aarch64" ] || [ ! -r /dev/kvm ]; then
        echo "==>  /dev/kvm not usable; falling back to TCG (software emulation)"
        # Use multi-threaded TCG and a large translation-block cache so the
        # four guest vCPUs do not serialize and hot guest code is not repeatedly
        # translated during the install.
        # QEMU interprets an unqualified tb-size value in MiB.
        accel="tcg,thread=multi,tb-size=1024"
        cpu="max"
        # Scale every wait budget: software-emulated guests boot and run many
        # times slower than under KVM, and ARM runner performance varies a lot
        # run to run.
        WAIT_MULT=4
    fi
    case "$ARCH" in
        aarch64) machine="virt" ;;
        *)       machine="q35" ;;
    esac
    netdev=$(net_device)

    local args=(
        -machine "$machine"
        -accel "$accel"
        -cpu "$cpu" -smp 4 -m "$MEM"
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$pflash_vars"
        -drive "file=$WORKDIR/nvme.qcow2,if=none,id=nvme0"
        -device "nvme,serial=deadbeef,drive=nvme0"
        -netdev "user,id=net0,hostfwd=tcp::$PORT-:22"
        -device "${netdev},netdev=net0"
        -serial "file:$SERIAL_LOG"
        -monitor "unix:$QEMU_MON,server,nowait"
        -nographic -no-reboot
    )
    if [ "$with_seed" -eq 1 ]; then
        args+=(-drive "file=$WORKDIR/seed.iso,if=virtio,format=raw,readonly=on")
    fi

    echo "==> Booting QEMU (seed=$with_seed, arch=$ARCH)"
    local qemu_stderr="$WORKDIR/qemu-stderr.log"
    : > "$qemu_stderr"
    setsid nohup "$qemu" "${args[@]}" >/dev/null 2>"$qemu_stderr" &
    QEMU_PID=$!
    # QEMU may fail instantly (e.g. bad args, KVM unavailable); surface the
    # error instead of letting wait_guest_ssh spin silently for 450s.
    sleep 3
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU exited immediately. stderr:" >&2
        cat "$qemu_stderr" >&2
        exit 1
    fi
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
    local max_tries=$(( 90 * WAIT_MULT ))
    local tries=0
    until root_ssh 'echo UP' 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt "$max_tries" ]; then
            {
                echo "ERROR: guest ssh did not come up"
                echo "--- serial log tail (guest boot progress) ---"
                tail -40 "$SERIAL_LOG" 2>/dev/null
                echo "--- qemu stderr ---"
                cat "$WORKDIR/qemu-stderr.log" 2>/dev/null
            } >&2
            exit 1
        fi
        sleep 5
    done
}

wait_phase1() {
    echo "==> Waiting for Phase-1 setup (kexec-tools/nvme-cli)"
    local max_tries=$(( 60 * WAIT_MULT ))
    local tries=0
    until root_ssh 'grep -q PHASE1-SETUP-DONE /var/log/cloud-init-output.log' 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt "$max_tries" ]; then
            {
                echo "ERROR: Phase-1 setup timed out"
                echo "--- serial log tail ---"
                tail -40 "$SERIAL_LOG" 2>/dev/null
                echo "--- guest cloud-init log tail ---"
                root_ssh 'tail -40 /var/log/cloud-init-output.log' 2>/dev/null
            } >&2
            exit 1
        fi
        sleep 5
    done
    echo "==> Phase-1 setup done"
}

prepare_guest() {
    echo "==> Installing wipe.sh in guest"
    # wipe.sh now builds its initramfs on the host (guest) at runtime, so no
    # prebuilt initramfs needs to be shipped or pointed at. Only the kexec
    # command line is patched so the wipe logs to the serial console.
    local console
    console=$(serial_console)
    sed -e "s|cmdline=\"root=/dev/ram rw quiet panic=10\"|cmdline=\"root=/dev/ram rw quiet panic=10 console=${console},115200n8\"|" \
        "$REPO_DIR/wipe.sh" \
        | root_ssh 'cat > /root/wipe.sh && chmod +x /root/wipe.sh && bash -n /root/wipe.sh'
}

run_wipe() {
    local wipe_arg=""
    if [ "$SKIP_INSTALL" -eq 0 ]; then
        echo "==> Running wipe.sh /dev/nvme0n1 --install-fedora (test mode)"
        wipe_arg="--install-fedora"
    else
        echo "==> Running wipe.sh /dev/nvme0n1 (test mode, sanitize/kexec only)"
    fi
    # Run as root, with SUDO_USER set so the provisioned user is $PROVISION_USER.
    # KEXEC_WIPE_TEST_MODE=1 lets the kexec'd initramfs continue when QEMU's
    # emulated NVMe does not implement the Sanitize command.
    # Detach on the guest (setsid + closed stdio) so this ssh returns
    # immediately: check_serial owns progress tracking via the serial log, and
    # the interactive 'read YES' confirmation is fed through the pipe. Without
    # the detach, a hung guest would pin this ssh (and thus CI) with no output.
    root_ssh "setsid bash -c 'echo YES | KEXEC_WIPE_TEST_MODE=1 SUDO_USER=$PROVISION_USER bash /root/wipe.sh /dev/nvme0n1 $wipe_arg > /root/wipe-run.log 2>&1' </dev/null >/dev/null 2>&1 &" \
        >/dev/null 2>&1 || true
}

check_serial() {
    local max_tries=$(( 120 * WAIT_MULT ))
    local tries=0

    # Minimal path (--skip-install): the kexec'd wipe initramfs sanitizes (the
    # emulated NVMe cannot, so test mode logs the skip), then reboots, which
    # -no-reboot turns into a QEMU process exit. That exit is the signal that
    # the whole UKI-kexec/sanitize pipeline ran through.
    if [ "$SKIP_INSTALL" -eq 1 ]; then
        echo "==> Waiting for the wipe initramfs to run (up to ~$(( max_tries * 5 / 60 )) min)"
        until grep -q "Sanitize was not performed (test/emulated device)" "$SERIAL_LOG" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -gt "$max_tries" ] && { echo "ERROR: wipe did not reach the sanitize step" >&2; tail -40 "$SERIAL_LOG"; exit 1; }
            sleep 5
        done
        echo "OK: sanitize ran (test-mode skip on emulated NVMe)"

        echo "==> Waiting for the guest to reboot out of the wipe initramfs"
        tries=0
        until ! kill -0 "$QEMU_PID" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -gt "$max_tries" ] && { echo "ERROR: guest did not reboot after the wipe" >&2; tail -40 "$SERIAL_LOG"; exit 1; }
            sleep 5
        done
        echo "PASS: kexec into the wipe initramfs completed and rebooted (QEMU exited)"
        return 0
    fi

    echo "==> Waiting for pipeline to complete (up to ~$(( max_tries * 5 / 60 )) min)"
    tries=0
    until grep -q "Switching root into Fedora" "$SERIAL_LOG" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -gt "$max_tries" ] && { echo "ERROR: pipeline did not reach switch_root" >&2; tail -30 "$SERIAL_LOG"; exit 1; }
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
        [ "$tries" -gt "$(( 90 * WAIT_MULT ))" ] && { echo "ERROR: fresh Fedora did not boot" >&2; exit 1; }
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
    local max_tries=$(( 90 * WAIT_MULT ))
    local tries=0
    while [ "$tries" -lt "$max_tries" ]; do
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
    sed -n '2,47p' "$0"
    exit 1
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch=*) ARCH="${1#--arch=}" ;;
            --workdir=*) WORKDIR="${1#--workdir=}" ;;
            --port=*) PORT="${1#--port=}" ;;
            --mem=*) MEM="${1#--mem=}" ;;
            --disk-size=*) DISK_SIZE="${1#--disk-size=}" ;;
            --skip-boot-check) SKIP_BOOT_CHECK=1 ;;
            --skip-install) SKIP_INSTALL=1 ;;
            --keep) KEEP=1 ;;
            --help|-h) usage ;;
            *) echo "Unknown argument: $1" >&2; usage ;;
        esac
        shift
    done

    [ -n "$ARCH" ] || ARCH=$(host_arch_matching)
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) echo "ERROR: unsupported arch '$ARCH' (use x86_64 or aarch64)" >&2; exit 1 ;;
    esac

    if [ "$SKIP_INSTALL" -eq 1 ]; then
        DIRECT_WIPE=1
    fi
    require_tools
    find_ovmf
    if [ "$DIRECT_WIPE" -eq 0 ]; then
        find_ssh_key
    fi
    fedora_pins
    mkdir -p "$WORKDIR"

    trap cleanup EXIT

    download_fedora
    make_disk
    if [ "$DIRECT_WIPE" -eq 1 ]; then
        echo "==> Building wipe.sh"
        ( cd "$REPO_DIR" && ./build.sh >/dev/null )
    fi
    make_seed
    boot_vm 1
    if [ "$DIRECT_WIPE" -eq 0 ]; then
        wait_guest_ssh
        wait_phase1
        prepare_guest
        run_wipe
    fi
    check_serial
    if [ "$SKIP_INSTALL" -eq 1 ]; then
        echo "ALL PASS: sanitize/kexec pipeline verified in QEMU (${ARCH})"
        exit 0
    fi
    if [ "$SKIP_BOOT_CHECK" -eq 0 ]; then
        verify_boot
    fi
    echo "ALL PASS: full --install-fedora run verified in QEMU"
}

main "$@"