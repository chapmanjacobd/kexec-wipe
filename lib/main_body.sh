#!/bin/bash

usage() {
    cat <<EOF
kexec-wipe - Sanitize NVMe devices

Usage:
  curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh
  sudo bash wipe.sh /dev/nvme0n1
  sudo ./wipe.sh /dev/nvme0n1 [OPTIONS]

Arguments:
  /dev/nvmeXnY          Target NVMe device to sanitize

Options:
  --method=METHOD       Sanitize method (default: auto)
                        auto       - Try crypto-erase, then block-erase
                        crypto     - Crypto-erase only (fastest for self-encrypting devices)
                        block      - Block-erase only
                        overwrite  - Overwrite (slowest, most thorough)
  --dry-run             Show what would be done without making changes
  --install-fedora      After sanitizing the device via kexec, write a Fedora
                        Cloud Base image and install a bootloader so it can boot.
                        Works on the root device or any other device.
  --help                Show this help message

Examples:
  sudo bash wipe.sh /dev/nvme0n1
  sudo bash wipe.sh /dev/nvme0n1 --method=block
  sudo bash wipe.sh /dev/nvme0n1 --install-fedora
  sudo bash wipe.sh /dev/nvme0n1 --dry-run

How it works:
  Non-root device: unmounts partitions, runs nvme sanitize directly.
  Root device: kexec's into a minimal in-memory environment to sanitize
  without any mounted filesystems, then reboots.
EOF
}

parse_args() {
    TARGET_DEVICE=""
    METHOD="auto"
    DRY_RUN=0
    INSTALL_FEDORA=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --method=*)
                METHOD="${1#--method=}"
                case "$METHOD" in
                    auto|crypto|block|overwrite) ;;
                    *) fatal "Invalid method: $METHOD (use: auto, crypto, block, overwrite)" ;;
                esac
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --install-fedora)
                INSTALL_FEDORA=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            /*)
                TARGET_DEVICE="$1"
                ;;
            *)
                fatal "Unknown argument: $1"
                ;;
        esac
        shift
    done

    if [ -z "$TARGET_DEVICE" ]; then
        error "No target device specified."
        echo ""
        usage
        exit 1
    fi
}

print_banner() {
    echo ""
    echo -e "${BOLD}kexec-wipe v${WIPE_VERSION}${RESET}"
    echo -e "${BOLD}Secure NVMe Device Sanitization${RESET}"
    echo ""
}

main() {
    parse_args "$@"

    # Resolve /dev/disk/by-* style symlinks so basename-based checks (NVMe name
    # validation, root-device detection, teardown) see the real kernel device.
    TARGET_DEVICE=$(readlink -f "$TARGET_DEVICE" 2>/dev/null || echo "$TARGET_DEVICE")

    print_banner
    check_root
    validate_device "$TARGET_DEVICE"

    # The kexec path builds its initramfs on the host (nvme-cli is needed unless
    # Docker is available to build it statically), while the direct path runs
    # nvme sanitize on the host. Both paths also need nvme-cli installed.
    local is_root=0
    if is_root_device "$TARGET_DEVICE"; then
        is_root=1
    fi

    local use_kexec=0
    if [ "$is_root" -eq 1 ] || [ "$INSTALL_FEDORA" -eq 1 ]; then
        use_kexec=1
    fi

    if [ "$use_kexec" -eq 1 ]; then
        # Fail fast on unsupported architectures before any destructive action.
        check_arch
        if ! command -v nvme &>/dev/null && ! command -v docker &>/dev/null; then
            fatal "nvme-cli is required on the host (or Docker to build it) to build the initramfs. Install nvme-cli."
        fi
        check_host_tools "$INSTALL_FEDORA"
    elif ! command -v nvme &>/dev/null; then
        fatal "nvme-cli is required but not found. Install it with your package manager."
    fi

    if [ "$is_root" -eq 1 ]; then
        warn "TARGET DEVICE IS THE ROOT DEVICE!"
        warn "This will kexec into a minimal environment to sanitize."
        warn "THE SYSTEM WILL REBOOT as part of this process."
    elif [ "$INSTALL_FEDORA" -eq 1 ]; then
        warn "TARGET IS NOT THE ROOT DEVICE, but --install-fedora sanitizes and replaces"
        warn "its contents, installs a bootloader, and boots into the fresh install."
        warn "THE SYSTEM WILL REBOOT as part of this process."
    fi

    echo -e "${BOLD}Device Information:${RESET}"
    get_device_info "$TARGET_DEVICE"
    echo ""

    local method_display="$METHOD"
    [ "$method_display" = "auto" ] && method_display="auto (crypto-erase -> block-erase)"
    echo -e "${BOLD}Sanitize method:${RESET} $method_display"
    if [ "$INSTALL_FEDORA" -eq 1 ]; then
        echo -e "${BOLD}Install:${RESET} Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} (${INSTALL_FEDORA_CURRENT})"
    fi
    echo ""

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY RUN - no changes will be made."
        if [ "$use_kexec" -eq 1 ]; then
            info "Would kexec into minimal environment and sanitize $TARGET_DEVICE."
            if [ "$INSTALL_FEDORA" -eq 1 ]; then
                info "Would then install Fedora Cloud Base ${INSTALL_FEDORA_RELEASE} on $TARGET_DEVICE."
            fi
        else
            info "Would unmount all partitions on $TARGET_DEVICE and sanitize."
        fi
        exit 0
    fi

    confirm "You are about to PERMANENTLY SANITIZE $TARGET_DEVICE. All data will be destroyed."

    if [ "$use_kexec" -eq 1 ]; then
        if [ "$is_root" -eq 0 ]; then
            # kexec reboots into the initramfs, but tear the device down first
            # anyway so the sanitize never runs underneath live mounts/swap/LVM,
            # matching the guarantee the direct path enforces.
            detach_device "$TARGET_DEVICE"
        fi
        do_kexec_wipe "$TARGET_DEVICE" "$METHOD" "$INSTALL_FEDORA"
    else
        detach_device "$TARGET_DEVICE"
        do_sanitize "$TARGET_DEVICE" "$METHOD"
    fi
}

main "$@"
