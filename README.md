# kexec-wipe

Securely wipe NVMe drives with a single command. Supports both non-root drives (direct sanitization) and root drives (via kexec into a minimal in-memory environment).

## Quick Start

```bash
curl -sL https://raw.githubusercontent.com/xk/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
```

## How It Works

### Non-root drives
If the target NVMe is **not** your root filesystem:
1. All partitions on the device are unmounted
2. LVM volumes, swap, and MD RAID are deactivated
3. `nvme sanitize` is executed directly on the device

### Root drives
If the target NVMe **is** your root filesystem:
1. A pre-built initramfs (busybox + nvme-cli) is downloaded
2. The running kernel is loaded via `kexec` with the custom initramfs
3. The system kexec's into a minimal in-memory environment
4. `nvme sanitize` is executed with no mounted filesystems
5. Optionally (`--install-fedora`) a Fedora image is written and made bootable
6. The system reboots

## Sanitize Methods

| Method | Speed | Compatibility | Description |
|--------|-------|---------------|-------------|
| `crypto` | Fastest | SED/encrypted NVMe | Cryptographic erase |
| `block` | Fast | All NVMe | Physical block erase |
| `overwrite` | Slow | All NVMe | Full overwrite |
| `auto` | - | - | Tries crypto, falls back to block (default) |

## Usage

```bash
# Auto-detect best sanitize method (default)
sudo bash wipe.sh /dev/nvme0n1

# Force a specific method
sudo bash wipe.sh /dev/nvme0n1 --method=block

# Sanitize the root disk, then install Fedora on it and make it bootable
sudo bash wipe.sh /dev/nvme0n1 --install-fedora

# Preview without making changes
sudo bash wipe.sh /dev/nvme0n1 --dry-run
```

## Arguments

| Argument | Description |
|----------|-------------|
| `/dev/nvmeXnY` | Target NVMe device (required) |
| `--method=METHOD` | Sanitize method: `auto`, `crypto`, `block`, `overwrite` |
| `--install-fedora` | After wiping the root disk, write a Fedora Cloud Base image and install a bootloader (kexec/root path only) |
| `--dry-run` | Show what would be done without making changes |
| `--help` | Show help message |

## Install Fedora Afterward

`--install-fedora` turns a root-disk wipe into a full reinstall: after the kexec
initramfs sanitizes the drive, it:

1. Brings up networking (DHCP) and downloads the pinned Fedora Cloud Base
   `raw.xz` image for your architecture.
2. Verifies the image SHA256.
3. Decompresses the raw image and writes it to the target (it never writes the
   compressed stream directly to the disk).
4. Detects UEFI vs BIOS and architecture, chroots into the installed OS, and
   runs `grub2-install`/`grub2-mkconfig` so the fresh Fedora boots on bare metal
   on subsequent boots.
5. `switch_root`s directly into the fresh Fedora in the same boot — no redundant
   reboot. (If switch_root fails it falls back to a plain reboot.)

The image URL, release, and checksum are pinned in `lib/kexec.sh` (mirroring the
`INITRAMFS_VERSION` convention) and bumped by the maintainer per Fedora release.

**Caveat:** Fedora Cloud Base images are built for virtualized/cloud environments
and carry cloud-init assumptions. Even with a bootloader installed, first boot on
physical hardware may require minor post-boot configuration. This feature makes
the write and bootloader correct; it does not guarantee cloud-init parity on metal.

## Architecture Support

x86_64 and aarch64 are supported. The initramfs build picks the correct busybox,
Fedora image, GRUB target, and kernel candidates per architecture. On aarch64,
where Fedora ships Unified Kernel Images (UKI), kexec attempts a direct UKI load
and falls back to extracting the embedded initrd (`objcopy`) if needed.

## Requirements

- Linux with NVMe support (x86_64 or aarch64)
- Root privileges
- `nvme-cli` (for non-root drives; included in initramfs for root drives)
- `kexec-tools` (for root drive sanitization only)
- `curl` or `wget` (for downloading initramfs)
- `awk` (for `bytes_to_human` formatting)
- `--install-fedora` additionally needs network access from the kexec initramfs
  and, at build time, Docker (to build busybox/curl/xz for non-x86_64 and to
  bundle CA certs)

## Development

The project is modular for development. `wipe.sh` is built from source files:

```
lib/common.sh      - Logging, colors, cleanup, byte formatting
lib/sanity.sh      - Root check, device validation, NVMe detection
lib/unmount.sh     - Unmount, swap/LVM/MD teardown
lib/sanitize.sh    - nvme sanitize with crypto->block fallback
lib/kexec.sh       - Download initramfs, kexec into minimal env
lib/main_body.sh   - Arg parsing, usage, main flow
```

### Building

```bash
# Assemble self-contained wipe.sh from lib/*.sh modules
./build.sh

# Build the initramfs (requires Docker for static nvme-cli)
./initramfs/build.sh
```

### Releasing

1. Update `INITRAMFS_VERSION` in `lib/kexec.sh`
2. Build initramfs: `./initramfs/build.sh`
3. Build wipe.sh: `./build.sh`
4. Create a GitHub release and upload the initramfs as an asset

## Safety

- Requires root privileges
- Validates the target is a real NVMe device
- Shows device model, serial, and size before proceeding
- Requires interactive confirmation (type `YES`) before wiping
- Detects root disk and warns before kexec
- Polls sanitize progress with timeout
- Verifies sanitize completion

## Disclaimer

**THIS TOOL PERMANENTLY DESTROYS DATA.** There is no undo. Make absolutely sure you are targeting the correct device. Always double-check with `lsblk` before confirming. The authors are not responsible for any data loss.

## License

MIT
