# iiab-deploy

`iiab_deploy.py` reimages an SSH-accessible machine, installs Internet-in-a-Box
(IIAB) on first boot, and then runs the IIAB roles changed by a GitHub pull
request.

It is a single-file Python tool. The target keeps its current kernel long
enough to unpack its own initramfs, replace `/init` with a small image writer,
and `kexec` into that writer. This works even when the disk being overwritten
contains the running root filesystem.

> **This erases the target disk. There is no undo.** Use `--dry-run` first and
> verify the hostname, disk, and image in the printed plan.

## Quick start

```bash
./iiab_deploy.py 192.168.1.219 4543
```

The tool prints a plan and asks you to type the target's **current hostname**
before it changes anything. To skip the prompt:

```bash
./iiab_deploy.py xk@box 4543 --yes --hostname box --disk /dev/nvme0n1
```

A PR can be given as a number, `iiab/iiab#4543`, or a full URL. Multiple
IIAB PRs can be comma-separated; they are fetched and merged in the order
provided:

```bash
./iiab_deploy.py 192.168.1.219 https://github.com/iiab/iiab/pull/4543
./iiab_deploy.py 192.168.1.219 4543,4544
```

Before anything is written, multiple PRs are replay-merged in a temporary
repository on the control host, in the same order and with the same
merge-ref/head-ref fallback that first boot uses. If any PR conflicts with
the preceding ones, the command stops and reports the conflicting files.
The same check applies to multiple Admin Console PRs passed to
`--admin-console-pr`.
`--skip-merge-check` bypasses this. The check needs `git` on the control host
and network access to GitHub; a single PR is treated as trivially clean.

## What it does

1. Probes the target over SSH: hostname, architecture, running root disk,
   network addresses, default gateway, DNS, memory, free space, and disks.
   It refuses to continue if Secure Boot, kernel lockdown, or
   `kernel.kexec_load_disabled` would block the write stage.
2. Resolves the PR (title, head SHA, changed files, merge ref). Roles are
   detected from paths under `roles/<name>/`; a change under `modules/`
   enables the `get_curl` module test.
3. Chooses an image:
   - **Raspberry Pi:** Raspberry Pi OS Lite **arm64**.
   - **Everything else:** Ubuntu 26.04 cloud image, x86_64 or arm64.
4. Rewrites the cloud-init `network-config` to the target's real interface
   names and pins the current IPv4 address, gateway, and DNS. Both the plain
   `version: 2` form and the netplan-style `network:` wrapper are accepted; the
   output is normalized to the plain form cloud-init's NoCloud datasource
   expects, and stale `match:`/`set-name:` selectors are dropped when a
   placeholder interface is renamed. The hostname is written into `user-data`,
   `meta-data`, `/etc/hostname`, `/etc/hosts`, and IIAB's `iiab_hostname`.
5. Builds a stage containing the image (or an HTTP URL to it), the replacement
   initramfs `/init`, and the first-boot payload. The stage is uploaded to
   `/var/tmp/iiab-deploy`.
6. Runs the write stage on the target:
   - Unpacks the running initramfs with `unmkinitramfs`.
   - Embeds the image and payload, and adds the target disk's kernel modules.
   - `kexec`s the running kernel with the modified initramfs.
7. The in-memory writer wipes old signatures, writes the image, rereads the
   partition table, mounts the new root, injects the NoCloud seed and the
   first-boot systemd unit, then:
   - kexecs the new kernel on x86_64, or
   - reboots on arm64/Raspberry Pi so firmware boots the new image.
8. Waits for SSH on the new system, verifies a unique deploy ID, follows the
   first-boot log, and fetches `/var/lib/iiab-deploy/result.json`.

## Requirements

### Control host

- Python 3.9+ and PyYAML
- `ssh`, `git`, `curl`, `tar`, `gzip`, and `unmkinitramfs`-capable tooling on
  the target (the remote setup installs what it needs with `apt`)
- `qemu-img` (from `qemu-utils`) to convert the Ubuntu cloud image from qcow2
  to a raw disk image. In embedded mode the target installs `qemu-utils`
  automatically; in `--netburn` mode the conversion happens on the control
  host, so install `qemu-utils` there.
- `gh` (authenticated) or a `GITHUB_TOKEN` for PR metadata. Public PRs also
  work through the unauthenticated GitHub API.
- `git` for the multi-PR merge pre-check (skipped with `--skip-merge-check`)
- Network access to GitHub and to the image host
- For `--netburn`: a TCP route from the target back to the control host
- For `--local-device`: local `lsblk`, `blkid`, `mount`, `umount`, `dd`, `cp`,
  `sync`, and the image decompressor (`xz`, `gzip`, or `zstd`) as applicable.
  The tool invokes `sudo` only for device writes and mounting the image.

### Target

- Debian, Ubuntu, Raspberry Pi OS, or another apt-based derivative
- Key-only SSH access; root or passwordless `sudo`
- `kexec` support in the running kernel (`kexec-tools` is installed if needed)
- **cloud-init**, because the new user and SSH access come from
  `user-data`/`network-config`
- A wired network connection is strongly recommended. `--netburn` uses DHCP in
  the write-stage initramfs, so it cannot use a WiFi association.
- Enough free space in `/var/tmp` for the embedded image. The default embedded
  mode needs room for the compressed download, the decompressed image, and the
  gzip copy used by the initramfs; the tool checks each step before spending
  the space and tells you to use `--netburn` if it is tight.

### Cloud-init input

The tool does not generate cloud-init data itself. It reads a `user-data` file
and a `network-config` file (`--cloudinit-userdata` and
`--cloudinit-networkconfig`, defaulting to
`~/.local/bin/cloudinit/user-data` and `~/.local/bin/cloudinit/network-config`)
and refuses to start if either file is missing.

`user-data` must create the post-boot user, install the control host's SSH
public key, and (for the log tail and result fetch) allow passwordless sudo.
`--post-user` overrides the user name that is detected from the file.

```yaml
#cloud-config
hostname: box
users:
  - name: xk
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... you@control-host
```

`network-config` is network-config version 2. Interface IDs are placeholders
(`eth0`, `wlan0`); they are renamed to the target's real NICs, so a minimal
file is enough:

```yaml
version: 2
ethernets:
  eth0:
    dhcp4: true
```

The netplan-style `network:` wrapper is also accepted and normalized to the
plain form. When IPv4 pinning is enabled (the default), the pinned address
replaces any static IPv4 in the template; with `--no-pin-ip`, static IPv4 is
removed and DHCPv4 is enabled. Static IPv6 is preserved unless IPv6 pinning is
active.

## Usage

### Dry run

```bash
./iiab_deploy.py 192.168.1.219 4543 --dry-run --keep-payload /tmp/iiab-stage
```

This probes the target, resolves the PR and image, rewrites the cloud-init
files, builds the stage, prints the plan, and exits without touching the
target. `--keep-payload` keeps the generated stage for inspection. The dry run
still needs SSH to the target, network access to GitHub and the image host, and
passes the Secure Boot/kexec checks; only the disk is left alone.

### Netburn (HTTP image delivery)

```bash
./iiab_deploy.py 192.168.1.219 4543 --netburn
```

Instead of uploading/decompressing the image on the target, the control host
serves a gzip-compressed raw image over plain HTTP. The target's initramfs
streams it to the disk. `--pxe` and `--ipxe` are aliases; no actual PXE or
iPXE server is involved.

The image is cached in `~/.cache/iiab-deploy` (override with `--cache-dir`).
The control host's address is detected from the route to the target. If that
is wrong, set `--http-address`. For an IPv6 target, bind an IPv6 address (for
example `--http-address ::`) and make sure the target can reach it.

The control host must stay running until the image is written. The tool keeps
the server alive, logs transfer progress, and waits for the image to be served
before it starts waiting for SSH on the new system. If the target makes no
transfer progress for 15 minutes, the tool reports the stall and continues
waiting for SSH, which normally ends in exit code 2. The target is wiped just
before streaming, so do not stop the tool while bytes are still flowing.

### Local USB/microSD image writing

Use `--local-device` when the USB or microSD device is attached to the machine
where this script is running. This mode is a local replacement for Raspberry
Pi Imager: it writes a raw Raspberry Pi image, mounts its root and boot
partitions, copies the cloud-init NoCloud seed and IIAB first-boot service,
then exits. It does not use SSH or kexec.

```bash
./iiab_deploy.py \
    --local-device /dev/disk/by-path/pci-0000:00:14.0-usb-0:3:1.0-scsi-0:0:0:0 \
    --image ~/Downloads/2026-10-06-raspios-trixie-arm64-lite.img.xz \
    --disable-verify \
    https://github.com/iiab/iiab/pull/4543 \
    --cloudinit-userdata ~/.local/bin/cloudinit/user-data \
    --cloudinit-networkconfig ~/.local/bin/cloudinit/network-config \
    --skip-rpi-upgrade
```

The command refuses partitions, mounted target filesystems, and the disk
containing the running system's root filesystem. It accepts raw `.img` files
and `.xz`, `.gz`, or `.zst` compressed raw images, and requires `--yes` to
skip the confirmation prompt. The target must be a whole Raspberry Pi OS
image with a Linux root partition and a recognizable FAT boot partition. If
`<image>.sha256` (or the same basename with a `.sha256` suffix) exists, it is
used for verification; pass `--disable-verify` to skip that check.
After the device boots, cloud-init creates the configured user and
`iiab-deploy-firstboot.service` installs IIAB from the requested PR.

### Roles

By default the roles are auto-detected from the PR's changed files:

```bash
./iiab_deploy.py 192.168.1.219 4543
# changed roles: 0-init 7-edu-apps network zimantic
```

Override the list (comma or whitespace separated):

```bash
./iiab_deploy.py 192.168.1.219 4543 \
    --roles 0-init,7-edu-apps,network,zimantic
```

`0-init` is provided by `runroles-base.yml`, so it is run first and is not
added twice. Stage roles (`0-init`, `7-edu-apps`, `9-*`, and so on) do not get
`<role>_install`/`<role>_enabled` variables. Other roles are enabled by
appending those variables to `/etc/iiab/local_vars.yml` before the changed-role
play.

A change under `modules/` makes the first boot run
`modules/tests/get_curl.yml`. Disable that with `--no-module-tests`.

### Hostname and network

The new hostname defaults to the target's current hostname. To require a
specific current hostname before overwriting:

```bash
./iiab_deploy.py 192.168.1.219 4543 --expect-hostname oldbox --hostname box
```

The new system's IPv4 address, netmask, gateway, and first DNS server are
pinned by default. To leave IPv4 on DHCP:

```bash
./iiab_deploy.py 192.168.1.219 4543 --no-pin-ip
```

`--no-pin-ip` removes any static IPv4 configuration inherited from
`network-config` and enables DHCPv4; the plan notes when template addresses
were cleared.

To pin a different address, gateway, or DNS server, use explicit overrides.
`--ip` requires a CIDR prefix because netplan needs both the address and the
netmask:

```bash
./iiab_deploy.py 192.168.1.219 4543 \
    --ip 192.168.1.50/24 --gateway 192.168.1.1 --dns 1.1.1.1,9.9.9.9
```

`--no-pin-ip` wins if both it and an override are given. IPv6 is pinned only
when a global address and a non-link-local default gateway are present.
`--no-pin-ipv6` leaves the template's IPv6 configuration as-is and does not add
the current address. Virtual interfaces created by IIAB or other tooling
(`br0`, `ap0`, `tailscale0`, ...) are ignored when choosing the interface to
pin, because they do not exist on the freshly imaged system.

IIAB's tiny profile enables `network_install`. The network role may move the
box to IIAB's default `10.10.10.10`/`box.local` addresses during the install.
The tool probes the old IP, the hostname, `<hostname>.local`, and
`10.10.10.10` after the reboot, and verifies the deploy ID so it cannot attach
to a different machine that happens to use the same address. The physical
console remains the reliable fallback.

### First boot

The injected unit is `iiab-deploy-firstboot.service`. On first boot it:

1. Waits for network and cloud-init.
2. Installs base packages, grows the root partition/filesystem, and on
   Raspberry Pi OS optionally runs `apt full-upgrade` (`--skip-rpi-upgrade`
   disables that).
3. Clones the PR repository and checks out the merge ref (or head ref/SHA).
4. Copies `vars/local_vars_tiny.yml` to `/etc/iiab/local_vars.yml`, sets
   `iiab_hostname`, the pinned WAN values, and `rpi_image` on Raspberry Pi.
5. Runs `scripts/ansible` and `./iiab-install` (default `--risky`; use
   `--install-args ''` for strict mode).
6. Clones and installs IIAB's separate Admin Console repository by default.
   Use `--no-admin-console` to skip it, or `--admin-console-pr 677` to
   install a specific Admin Console pull request instead of its default
   branch. Multiple Admin Console PRs can be comma-separated; they are
   merge-checked, then fetched and merged in the order provided.
7. Runs the changed-role play (`runroles-base.yml` plus the selected roles),
   then the module tests if applicable, and writes a state diff.
8. Writes `result.json` and a `done` or `failed` marker.
9. Reboots after a successful install so newly installed services, including
   the IIAB Wi-Fi hotspot, activate.

Logs and state are under:

```
/var/log/iiab-deploy/firstboot.log
/var/log/iiab-deploy/ansible-roles.log
/var/log/iiab-deploy/state.diff
/var/lib/iiab-deploy/result.json
/var/lib/iiab-deploy/{attempted,done,failed}
```

The unit does not retry automatically after a failed attempt. To retry:
remove `/var/lib/iiab-deploy/{attempted,failed}` and reboot or start
`iiab-deploy-firstboot.service` again.

## Watching the install

The unit sends stdout/stderr to the journal and the system console. On a
physical machine or a serial console, watch `tty0` or `ttyS0,115200`.

The first boot also starts a read-only `tmux`, `screen`, or `abduco` session
when one is available. It runs as root, so attach with `sudo`:

```bash
ssh -t xk@box 'sudo tmux attach -t iiab-deploy'
# or: ssh -t xk@box 'sudo screen -r iiab-deploy'
# or: ssh -t xk@box 'sudo abduco -a iiab-deploy'
```

Follow the log directly:

```bash
ssh xk@box 'sudo tail -F /var/log/iiab-deploy/firstboot.log'
ssh xk@box 'sudo journalctl -u iiab-deploy-firstboot -f'
```

The target gets new SSH host keys after reimaging. Remove the old key when
`ssh` warns:

```bash
ssh-keygen -R 192.168.1.219
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | First boot completed and `result.json` reports `success` |
| 1 | The deploy ran but the first boot, a role, or a module test failed |
| 2 | SSH did not return on the new system, or no result was fetched |

A missing `result.json` usually means the box is still installing, moved to a
different address, or stopped on the console. Check `tty0` and the log before
retrying.

## Caveats

- **Secure Boot and kernel lockdown:** kexec is blocked under Secure Boot and
  under integrity/confidentiality lockdown. Disable Secure Boot or use another
  install method.
- **Raspberry Pi:** The RPi profile always installs the **arm64** image. A
  32-bit kernel can report `armv7l` even when the Pi hardware is 64-bit
  capable; the tool checks the device-tree SoC and warns before continuing
  for known-capable hardware. Known 32-bit-only or unverifiable `armv7l`
  hardware is rejected, as are `armv6l` targets.
- **Raspberry Pi OS and cloud-init:** The current Raspberry Pi OS Lite arm64
  image ships cloud-init with the NoCloud datasource enabled
  (`datasource_list: [NoCloud, None]`), so the injected `user-data` and
  `network-config` create the post-boot user and configure SSH. If you
  substitute a custom or older image, verify that it still includes cloud-init;
  without it the new system may not be reachable over SSH. Raspberry Pi OS
  reads the NoCloud seed from `/boot/firmware`
  (`seedfrom: file:///boot/firmware`), and the tool writes the seed there as
  well as to `/var/lib/cloud/seed/nocloud`.
- **Boot order:** After writing, the firmware must boot the target disk. Check
  the BIOS/EFI boot order or the Raspberry Pi boot device if the old system
  comes back.
- **No sanitize:** This tool only writes `wipefs` signatures and the new image.
  It does not run an NVMe sanitize or secure erase.
- **First boot needs internet:** The IIAB install clones from GitHub and runs
  `apt`. The netburn server only delivers the OS image.
- **Network role changes:** IIAB's network role can change the address during
  the install. The deploy-ID check avoids connecting to the wrong host, but
  console access is still the fallback.
- **One disk:** If the target has more than one whole disk, pass `--disk`.
- **Embedded mode uses disk and RAM:** It downloads and decompresses the image
  on the target, embeds a gzip copy in the initramfs, and loads that initramfs
  with kexec. Use `--netburn` when space or RAM is tight.
