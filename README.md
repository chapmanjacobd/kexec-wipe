# kexec-wipe

Sanitize an NVMe device and permanently destroy its data. kexec-wipe works on a device that holds the root filesystem and on one that does not. It can also install Fedora afterward.

## Quick start

Download the script, inspect it, then run it as root.

```bash
# 1. Download
curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh

# 2. Run (type YES to confirm)
sudo bash wipe.sh /dev/nvme0n1
```

## How it works

kexec-wipe runs the NVMe `sanitize` command on the target device.

### Device that is not the root device

1. Unmount all partitions on the device.
2. Deactivate swap, LVM volumes, and MD RAID on the device.
3. Run `nvme sanitize` on the device.

### Root device

1. Build a minimal initramfs on the host (busybox + nvme-cli + the running kernel's modules), so it always matches the kernel being kexec'd.
2. Load the running kernel and the initramfs with `kexec`.
3. Boot into a minimal in-memory environment.
4. Run `nvme sanitize` with no filesystems mounted.
5. Reboot. With `--install-fedora`, write a Fedora image and make it bootable before the reboot.

## Sanitize methods

| Method | Speed | Requirement | NVMe action |
|--------|-------|-------------|-------------|
| `crypto` | Fastest | Self-encrypting drive | `crypto-erase` |
| `block` | Fast | All NVMe | `block-erase` |
| `overwrite` | Slow | All NVMe | `overwrite` |
| `auto` | — | — | Try `crypto`, then `block` (default) |

## Usage

```bash
# Sanitize with the default method (auto)
sudo bash wipe.sh /dev/nvme0n1

# Sanitize with a specific method
sudo bash wipe.sh /dev/nvme0n1 --method=block

# Sanitize the device, then install Fedora
sudo bash wipe.sh /dev/nvme0n1 --install-fedora

# Show the actions without doing them
sudo bash wipe.sh /dev/nvme0n1 --dry-run
```

## Arguments

| Argument | Description |
|----------|-------------|
| `/dev/nvmeXnY` | Target NVMe device (required) |
| `--method=METHOD` | Sanitize method: `auto`, `crypto`, `block`, `overwrite` |
| `--install-fedora` | After sanitizing, write a Fedora Cloud Base image and install a bootloader. Uses the kexec path on any device. |
| `--dry-run` | Show the actions without doing them |
| `--help` | Show the help message |

## Install Fedora afterward

`--install-fedora` turns a sanitize into a full reinstall. The host pre-downloads the pinned Fedora Cloud Base `raw.xz` image and embeds it in the initramfs. After the initramfs sanitizes the device, it:

1. Decompresses the image and writes it to the device. It never writes the compressed stream directly.
2. Detects UEFI or BIOS and the architecture, chroots into the new OS, and runs `grub2-install` and `grub2-mkconfig`.
3. Creates a user account from `$SUDO_USER`. When run as root, it provisions the root account instead.
4. Copies the account's `~/.ssh/authorized_keys`, grants sudo, and enables `sshd`.
5. Runs `switch_root` into the new Fedora in the same boot. If `switch_root` fails, it reboots.

The image URL, release, and checksum are pinned in `lib/kexec.sh`.

**Caveat:** Fedora Cloud Base images are for virtualized and cloud environments and use cloud-init. First boot on physical hardware may need configuration after boot. This feature writes the image and bootloader correctly. It does not guarantee cloud-init behavior on metal.

## Architecture support

x86_64 and aarch64 are supported. The initramfs is built on the host at run time from the running kernel, so its modules (nvme, xfs, btrfs, ext4) always match the kernel being kexec'd. On aarch64, Fedora uses Unified Kernel Images (UKI); kexec-wipe loads a UKI directly with `kexec -l --initrd` (verified by a QEMU test in CI on an arm64 runner). This requires kexec-tools >= 2.0.30 (arm64; the UKI support is newer on x86_64).

## Requirements

- Linux with NVMe support (x86_64 or aarch64)
- Root privileges
- `nvme-cli` (or Docker to build a static nvme-cli when using the kexec path)
- `kexec-tools` (for the root device only; >= 2.0.30 when booting a UKI on aarch64)
- `cpio` and `gzip` (to build the initramfs on the host, for the root device)
- `bash` (the script is a bash script)
- `awk` (to format byte sizes)
- For `--install-fedora`: network access on the host to download the Fedora image

## Development

`wipe.sh` is assembled from modules in `lib/`:

```
lib/common.sh      - Logging, colors, cleanup, byte formatting
lib/sanity.sh      - Root check, device validation, NVMe detection
lib/unmount.sh     - Unmount, swap/LVM/MD teardown
lib/sanitize.sh    - nvme sanitize with crypto -> block fallback
lib/kexec.sh       - Download initramfs, kexec into the minimal environment
lib/main_body.sh   - Argument parsing, usage, main flow
```

### Build

```bash
./build.sh            # assemble wipe.sh from lib/*.sh
./initramfs/build.sh  # build the initramfs (Docker for static nvme-cli)
```

### Release

1. Run `./build.sh` (embeds the current initramfs source into wipe.sh).
2. Push a version tag. CI assembles wipe.sh, runs the static checks, the QEMU integration tests (including the UKI kexec test), and uploads wipe.sh to the release.

## Safety

- Requires root privileges
- Validates that the target is an NVMe device
- Shows the device model, serial, and size before it continues
- Requires confirmation (type `YES`)
- Detects the root device and warns before kexec
- Polls sanitize progress with a timeout
- Verifies sanitize completion

## Disclaimer

This tool permanently destroys data. There is no undo. Verify the target device with `lsblk` before you confirm. The authors are not responsible for data loss.

## License

MIT
