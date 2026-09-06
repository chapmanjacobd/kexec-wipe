# kexec-wipe

kexec-wipe permanently destroys the data on an NVMe device. It uses the NVMe `sanitize` command for the operation. It works on a device that holds the root filesystem of the running system and on a device that does not. The option `--install-fedora` also writes a Fedora image to the device after the sanitize.

## Quick start

```bash
curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh
sudo bash wipe.sh /dev/nvme0n1
```

## How it works

kexec-wipe runs the NVMe `sanitize` command on the target device. The target device is an NVMe namespace, for example `/dev/nvme0n1`.

The running system is the OS on which the operator runs wipe.sh. The root device is the disk that holds the root filesystem of the running system. kexec-wipe selects the operating mode from the target device and the given options.

### Device that is not the root device

This mode runs when the target device is not the root device and the option `--install-fedora` is not given.

1. kexec-wipe unmounts the partitions on the device.
2. It deactivates swap, LVM volume groups, and MD RAID arrays on the device.
3. It runs `nvme sanitize` on the running system and waits for completion.

### Root device

This mode runs when the target device is the root device or the option `--install-fedora` is given. It sanitizes the device with no filesystems mounted.

1. kexec-wipe builds an initramfs on the running system. The initramfs contains busybox, nvme-cli, and the modules of the running kernel, so the modules always match the kernel that kexec loads.
2. It loads the running kernel and the initramfs with `kexec` and boots the in-memory system.
3. The in-memory system runs `nvme sanitize` and waits for completion.
4. Without `--install-fedora`, the in-memory system reboots. With `--install-fedora`, it writes a Fedora image, makes the image bootable, and boots the new system without a separate reboot.

## Sanitize methods

The method selects the NVMe sanitize action. Method names are the values of the option `--method`.

| Method | Speed | Requirement | NVMe action |
|--------|-------|-------------|-------------|
| `auto` | — | — | crypto-erase, then block-erase (default) |
| `crypto` | Fastest | Self-encrypting device | crypto-erase |
| `block` | Fast | Any NVMe device | block-erase |
| `overwrite` | Slowest | Any NVMe device | overwrite |

With `auto`, kexec-wipe runs crypto-erase first. If the device does not support crypto-erase, it runs block-erase.

## Usage

```bash
# Sanitize with the default method (auto)
sudo bash wipe.sh /dev/nvme0n1

# Sanitize with the method block
sudo bash wipe.sh /dev/nvme0n1 --method=block

# Sanitize the device and install Fedora
sudo bash wipe.sh /dev/nvme0n1 --install-fedora

# Show the actions without making changes
sudo bash wipe.sh /dev/nvme0n1 --dry-run
```

## Arguments and options

### Arguments

| Argument | Description |
|----------|-------------|
| `/dev/nvmeXnY` | Target NVMe device to sanitize (required) |

### Options

| Option | Description |
|--------|-------------|
| `--method=METHOD` | Sanitize method (default: `auto`) |
| `--install-fedora` | After the sanitize, write a Fedora Cloud Base image and install a bootloader. Works on the root device and on any other device. |
| `--dry-run` | Show the actions without making changes |
| `--help` | Show the help message |

## Install Fedora

`--install-fedora` performs a full reinstall: it sanitizes the device and then writes Fedora to it. wipe.sh downloads a pinned Fedora Cloud Base raw image on the running system and embeds the image in the initramfs. The in-memory system then:

1. Decompresses the image and writes the uncompressed data to the device. It never writes the compressed stream directly.
2. Detects UEFI or BIOS and the architecture, chroots into the new OS, and runs `grub2-install` and `grub2-mkconfig`.
3. Creates a user account from the operator who invokes wipe.sh (`$SUDO_USER`). When wipe.sh runs directly as root, it provisions the root account instead.
4. Copies the account's `~/.ssh/authorized_keys`, grants sudo to a new user, and enables `sshd`.
5. Starts the new Fedora in the same boot with `switch_root`. If `switch_root` fails, it reboots.

The Fedora release, the image URL, and the checksum are fixed in `lib/kexec.sh`.

**Caveat:** Fedora Cloud Base images target virtual and cloud environments and use cloud-init. First boot on physical hardware may require configuration after boot. This option writes the image and the bootloader correctly. It does not guarantee cloud-init behavior on bare metal.

## Architecture support

kexec-wipe supports x86_64 and aarch64. It builds the initramfs from the running kernel, so its modules (nvme, xfs, btrfs, ext4) always match the running kernel.

Fedora uses Unified Kernel Images (UKI) on aarch64. A UKI combines the kernel and its initrd in one EFI binary. kexec-wipe loads the UKI with `kexec -l --initrd` and replaces the embedded initrd with the wipe initramfs. This requires kexec-tools >= 2.0.30 on aarch64 (UKI load support in kexec-tools is newer on x86_64).

CI exercises this mode end to end: the aarch64 job boots a Fedora Cloud aarch64 guest in QEMU, runs `--install-fedora`, and the guest loads its own UKI.

## Requirements

- A running Linux system with NVMe support (x86_64 or aarch64)
- Root privileges
- `nvme-cli` (or Docker to build a static nvme-cli when using the kexec path)
- `kexec-tools` (for the root device only; >= 2.0.30 when booting a UKI on aarch64)
- `cpio`, `gzip`, and `find` (to build the initramfs on the host, for the root device)
- `xz` (the initramfs builder decompresses the staged `.ko.xz` kernel modules with it)
- `curl` (to fetch a static busybox for the initramfs), or Docker, or a `busybox` already installed on the host, plus network access
- `bash` (the script is a bash script)
- `awk` (to format byte sizes)
- `stat` (to report the initramfs and image sizes)
- For `--install-fedora`: network access on the host to download the Fedora image, plus `curl` or `wget` and `sha256sum`

## Development

wipe.sh is a self-contained script. `build.sh` assembles it from modules in `lib/`:

```
lib/common.sh      - logging, colors, cleanup, byte formatting
lib/sanity.sh      - root check, device validation, NVMe detection
lib/unmount.sh     - unmount, swap/LVM/MD teardown
lib/sanitize.sh    - nvme sanitize with crypto -> block fallback
lib/kexec.sh       - download initramfs, kexec into the minimal environment
lib/main_body.sh   - argument parsing, usage, main flow
```

### Build

```bash
./build.sh            # assemble wipe.sh from lib/*.sh
./initramfs/build.sh  # build the initramfs (Docker for static nvme-cli)
```

### Release

1. Run `./build.sh`. It embeds the current initramfs source into wipe.sh.
2. Push a version tag. CI assembles wipe.sh, runs the static checks and the QEMU integration tests, installs real Fedora in QEMU on x86_64 and aarch64 (the aarch64 run exercises the UKI boot mode), and uploads wipe.sh to the release.

## Safety

- Requires root privileges
- Validates that the target device is an NVMe device
- Displays the device model, serial, and size before it continues
- Requires the operator to type `YES` to confirm
- Detects the root device and warns before it uses kexec
- Polls the sanitize state with a timeout
- Verifies that the sanitize completes

## Disclaimer

This tool destroys data permanently. There is no undo. Verify the target device with `lsblk` before you confirm. The authors are not responsible for data loss.

## License

MIT
