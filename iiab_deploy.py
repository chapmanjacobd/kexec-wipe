#!/usr/bin/env python3
"""
iiab-deploy - reimage a machine and install Internet-in-a-Box from a PR.

The control host (where this script runs) needs:
  * key-only SSH access to the target (passwordless sudo, or root)
  * Python 3.9+ and PyYAML
  * gh (or GITHUB_TOKEN) for PR metadata
  * curl/tar/gzip for staging

The target is expected to be Ubuntu, Raspberry Pi OS, or another
Debian/Ubuntu derivative.  The target's currently-running initramfs is
unpacked with unmkinitramfs, its /init is replaced with a small writer that
streams the new image to the target disk, and the result is kexec'd.  This
works even when the disk being overwritten contains the running root.

After the image is written, the initramfs mounts the new root, injects
cloud-init NoCloud data and a first-boot systemd unit, then kexecs the new
kernel (x86) or reboots (arm64/Raspberry Pi).  The first-boot unit installs
IIAB from the requested PR using vars/local_vars_tiny.yml and then runs the
PR's changed roles.

Examples:
  ./iiab_deploy.py 192.168.1.219 4543
  ./iiab_deploy.py xk@box 4543 --yes --hostname box --disk /dev/nvme0n1
  ./iiab_deploy.py 192.168.1.219 https://github.com/iiab/iiab/pull/4543 \\
      --roles 0-init,7-edu-apps,network,zimantic --netburn

This tool is intentionally a single file so it can be copied to another
machine.  The remote shell payloads are embedded near the bottom.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import ipaddress
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, NoReturn, Optional

DEFAULT_REPO = "iiab/iiab"
DEFAULT_SSH_PORT = 22
NETBURN_STALL_MINUTES = 15
REMOTE_STAGE = "/var/tmp/iiab-deploy"
STATE_DIR = "/var/lib/iiab-deploy"
LOG_DIR = "/var/log/iiab-deploy"
DEFAULT_CLOUDINIT_USERDATA = os.path.expanduser(
    "~/.local/bin/cloudinit/user-data"
)
DEFAULT_CLOUDINIT_NETWORKCONFIG = os.path.expanduser(
    "~/.local/bin/cloudinit/network-config"
)
CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "iiab-deploy",
)
RPI_IMAGE_BASE = "https://downloads.raspberrypi.org/raspios_lite_{arch}_latest"
UBUNTU_IMAGE_BASE = (
    "https://cloud-images.ubuntu.com/releases/26.04/release/"
    "ubuntu-26.04-server-cloudimg-{arch}.img"
)
UBUNTU_SHA256SUMS = (
    "https://cloud-images.ubuntu.com/releases/26.04/release/SHA256SUMS"
)
VIRTUAL_IFACE_PREFIXES = (
    "lo",
    "docker",
    "veth",
    "br",
    "virbr",
    "bond",
    "dummy",
    "ifb",
    "macvlan",
    "vlan",
    "tun",
    "tap",
    "wg",
    "ap",
    "tailscale",
    "zt",
)


class DeployError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(f"[iiab-deploy] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[iiab-deploy] WARNING: {msg}", file=sys.stderr, flush=True)


def die(msg: str, code: int = 1) -> NoReturn:
    print(f"[iiab-deploy] ERROR: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def run(
    cmd: list[str],
    *,
    input_text: Optional[str] = None,
    input_bytes: Optional[bytes] = None,
    check: bool = True,
    capture: bool = True,
    timeout: Optional[float] = None,
    env: Optional[dict[str, str]] = None,
    die_on_timeout: bool = True,
) -> subprocess.CompletedProcess:
    """Run a local command, dying with a useful message on failure."""
    try:
        p = subprocess.run(
            cmd,
            input=input_bytes if input_bytes is not None else input_text,
            text=input_bytes is None,
            capture_output=capture,
            timeout=timeout,
            env=env,
        )
    except FileNotFoundError:
        die(f"command not found: {cmd[0]}")
    except subprocess.TimeoutExpired:
        if die_on_timeout:
            die(f"command timed out after {timeout}s: {' '.join(cmd)}")
        return subprocess.CompletedProcess(
            cmd, 124, "", f"command timed out after {timeout}s"
        )
    if check and p.returncode != 0:
        stderr = (p.stderr or "").strip() if capture else ""
        die(
            "command failed (exit {})\n  {}\n{}".format(
                p.returncode, " ".join(shlex.quote(c) for c in cmd), stderr
            )
        )
    return p


def http_get_text(url: str, timeout: float = 60.0) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "iiab-deploy/1.0",
            "Accept": "*/*",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        # Fall back to curl, which handles more redirect/proxy setups.
        if shutil.which("curl"):
            p = run(
                ["curl", "-fsSL", "--retry", "3", "--max-time", str(int(timeout)), url],
                check=False,
                die_on_timeout=False,
            )
            if p.returncode == 0:
                return p.stdout
        raise DeployError(f"failed to fetch {url}: {e}") from e


def resolve_url(url: str, timeout: float = 60.0) -> str:
    """Follow redirects without downloading the body, if possible.

    Returns the final URL, or "" when it could not be determined.  Returning
    the original URL here would silently break callers that append a suffix
    (for example a ``.sha256`` checksum URL).
    """
    req = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "iiab-deploy/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.geturl()
    except Exception:
        if shutil.which("curl"):
            p = run(
                [
                    "curl",
                    "-fsSIL",
                    "--max-time",
                    str(int(timeout)),
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{url_effective}",
                    url,
                ],
                check=False,
                die_on_timeout=False,
            )
            if p.returncode == 0 and p.stdout.strip():
                return p.stdout.strip()
    return ""


@dataclass
class Remote:
    host: str
    user: Optional[str] = None
    port: Optional[int] = None
    identity: Optional[str] = None
    is_root: bool = False
    can_sudo: bool = False

    @property
    def target(self) -> str:
        if self.user:
            return f"{self.user}@{self.host}"
        return self.host


def parse_address(s: str) -> Remote:
    user: Optional[str] = None
    hostport = s
    if "@" in s:
        user, hostport = s.rsplit("@", 1)
    host = hostport
    port: Optional[int] = None
    if hostport.startswith("["):
        m = re.match(r"^\[([^\]]+)\](?::(\d+))?$", hostport)
        if m:
            host = m.group(1)
            port = int(m.group(2)) if m.group(2) else None
    elif hostport.count(":") == 1:
        h, p = hostport.rsplit(":", 1)
        if p.isdigit():
            host, port = h, int(p)
    return Remote(host=host, user=user, port=port)


def ssh_base(
    remote: Remote,
    *,
    tty: bool = False,
    connect_timeout: int = 15,
    insecure: bool = False,
) -> list[str]:
    cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={connect_timeout}",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=4",
    ]
    if insecure:
        cmd += [
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
        ]
    else:
        cmd += ["-o", "StrictHostKeyChecking=accept-new"]
    if remote.identity:
        cmd += ["-i", remote.identity]
    if remote.port:
        cmd += ["-p", str(remote.port)]
    if tty:
        cmd += ["-tt"]
    cmd.append(remote.target)
    return cmd


def ssh_run(
    remote: Remote,
    script: str,
    *,
    sudo: bool = False,
    check: bool = False,
    timeout: Optional[float] = None,
    insecure: bool = False,
    tty: bool = False,
) -> subprocess.CompletedProcess:
    remote_cmd = "bash -s"
    if sudo and not remote.is_root:
        remote_cmd = "sudo -n bash -s"
    cmd = ssh_base(
        remote, tty=tty, insecure=insecure
    ) + [remote_cmd]
    try:
        p = subprocess.run(
            cmd,
            input=script,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        if check:
            die(f"SSH command timed out: {remote.target}")
        return subprocess.CompletedProcess(
            cmd, 124, "", f"SSH command timed out: {remote.target}"
        )
    if check and p.returncode != 0:
        die(
            "SSH command failed on {} (exit {})\n{}\n{}".format(
                remote.target,
                p.returncode,
                (p.stdout or "").strip(),
                (p.stderr or "").strip(),
            )
        )
    return p


# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

PROBE_SH = r'''
set -u
line() { printf '%s=%s\n' "$1" "$2"; }
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_disk=""
if [ -n "$root_src" ]; then
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)
fi
line HOSTNAME "$(hostname 2>/dev/null || true)"
line ARCH "$(uname -m 2>/dev/null || true)"
line KERNEL "$(uname -r 2>/dev/null || true)"
line OS_ID "$( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" )"
line OS_VERSION "$( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}" )"
line OS_PRETTY "$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}" )"
line MODEL "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
line RPI_COMPAT "$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
line ROOT_SOURCE "$root_src"
line ROOT_DISK "$root_disk"
line ROOT_FSTYPE "$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
line EFI "$([ -d /sys/firmware/efi ] && echo 1 || echo 0)"
secureboot=$(mokutil --sb-state 2>/dev/null | tr '\n' ' ' || true)
if [ -z "$secureboot" ] && [ -d /sys/firmware/efi ]; then
    for v in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -f "$v" ] || continue
        # efivar data starts after the 4-byte attributes field.
        if [ "$(od -An -t u1 -j 4 -N 1 "$v" 2>/dev/null | tr -d ' ')" = "1" ]; then
            secureboot="SecureBoot enabled"
        else
            secureboot="SecureBoot disabled"
        fi
        break
    done
fi
line SECUREBOOT "$secureboot"
line LOCKDOWN "$(cat /sys/kernel/security/lockdown 2>/dev/null || true)"
line KEXEC "$(command -v kexec 2>/dev/null || true)"
line KEXEC_DISABLED "$(cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || true)"
line MEM_MB "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
line FREE_MB "$(df -Pm /var/tmp 2>/dev/null | awk 'NR==2 {print $4}' || true)"
line IP4 "$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2" "$4}' | tr '\n' ';' || true)"
line IP6 "$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $2" "$4}' | tr '\n' ';' || true)"
line GATEWAY4 "$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)"
line GATEWAY6 "$(ip -6 route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)"
line DEFAULT_IFACE "$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
line NICS "$(ls /sys/class/net 2>/dev/null | tr '\n' ' ' || true)"
line WIFI_NICS "$(for n in /sys/class/net/*; do [ -d "$n/wireless" ] && basename "$n"; done 2>/dev/null | tr '\n' ' ' || true)"
line DNS4 "$( (resolvectl dns 2>/dev/null | sed 's/.*: //' | tr ' ' '\n'; awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null) | grep -vE '^(127\.|::1$)' | sort -u | tr '\n' ' ' || true)"
line CLOUD_INIT "$(command -v cloud-init 2>/dev/null || true)"
line GIT "$(command -v git 2>/dev/null || true)"
echo DISKS_BEGIN
lsblk -P -b -o NAME,TYPE,SIZE,MODEL,SERIAL,ROTA,TRAN 2>/dev/null \
    || lsblk -P -b -o NAME,TYPE,SIZE,MODEL,SERIAL,ROTA 2>/dev/null \
    || true
echo DISKS_END
'''


def parse_probe(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {"disks": []}
    section = "kv"
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line == "DISKS_BEGIN":
            section = "disks"
            continue
        if line == "DISKS_END":
            section = "kv"
            continue
        if section == "disks":
            fields = dict(re.findall(r'(\w+)="([^"]*)"', line))
            if fields:
                data["disks"].append(fields)
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v
    return data


def probe_remote(remote: Remote) -> dict[str, Any]:
    boot = r'''
set -u
if [ "$(id -u)" -eq 0 ]; then
    echo IS_ROOT=1
    echo CAN_SUDO=1
else
    echo IS_ROOT=0
    if sudo -n true 2>/dev/null; then echo CAN_SUDO=1; else echo CAN_SUDO=0; fi
fi
'''
    p = ssh_run(remote, boot, check=False, timeout=60)
    if p.returncode != 0:
        msg = (p.stderr or p.stdout or "").strip()
        die(
            f"cannot SSH to {remote.target}. Check key-only access.\n{msg}"
        )
    info: dict[str, str] = {}
    for line in (p.stdout or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    remote.is_root = info.get("IS_ROOT") == "1"
    remote.can_sudo = info.get("CAN_SUDO") == "1"
    if not remote.is_root and not remote.can_sudo:
        die(
            f"{remote.target} needs root or passwordless sudo for this operation."
        )
    p = ssh_run(
        remote,
        PROBE_SH,
        sudo=not remote.is_root,
        check=False,
        timeout=120,
    )
    if p.returncode != 0:
        die(
            "failed to probe {} (exit {})\n{}".format(
                remote.target, p.returncode, (p.stderr or "").strip()
            )
        )
    data = parse_probe(p.stdout or "")
    data["_remote_is_root"] = remote.is_root
    data["_remote_can_sudo"] = remote.can_sudo
    return data


def parse_ip_map(value: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in value.split(";"):
        item = item.strip()
        if not item:
            continue
        parts = item.split(None, 1)
        if len(parts) == 2:
            out.setdefault(parts[0], parts[1])
    return out


def prefix_to_netmask(cidr: str) -> str:
    if "/" not in cidr:
        return ""
    prefix = cidr.rsplit("/", 1)[1]
    if not prefix.isdigit():
        return ""
    n = int(prefix)
    if not 0 <= n <= 32:
        return ""
    mask = (0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF if n else 0
    return ".".join(str((mask >> shift) & 0xFF) for shift in (24, 16, 8, 0))


def is_raspberry_pi(probe: dict[str, Any]) -> bool:
    model = str(probe.get("MODEL", "")).lower()
    return "raspberry pi" in model or "bcm2" in model


def rpi_arm64_capability(probe: dict[str, Any]) -> Optional[bool]:
    """Return whether the Raspberry Pi hardware can boot arm64, if known."""
    compat = str(probe.get("RPI_COMPAT", "")).lower()
    if any(
        soc in compat
        for soc in ("bcm2837", "bcm2710", "bcm2711", "bcm2712")
    ):
        return True
    if any(soc in compat for soc in ("bcm2835", "bcm2836")):
        return False

    model = str(probe.get("MODEL", "")).lower()
    if re.search(r"raspberry pi (3|4|5|zero 2|400|cm4|cm5)\b", model):
        return True
    if re.search(r"raspberry pi 2 model b rev 1\.2\b", model):
        return True
    return None


# ---------------------------------------------------------------------------
# PR resolution
# ---------------------------------------------------------------------------


@dataclass
class PRInfo:
    repo: str
    number: int
    title: str
    url: str
    state: str
    draft: bool
    head_ref: str
    head_sha: str
    merge_ref: str
    changed_files: list[str] = field(default_factory=list)
    auto_roles: list[str] = field(default_factory=list)
    modules_changed: bool = False
    cross_repo: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "repo": self.repo,
            "number": self.number,
            "title": self.title,
            "url": self.url,
            "state": self.state,
            "draft": self.draft,
            "head_ref": self.head_ref,
            "head_sha": self.head_sha,
            "merge_ref": self.merge_ref,
            "changed_files": self.changed_files,
            "auto_roles": self.auto_roles,
            "modules_changed": self.modules_changed,
            "cross_repo": self.cross_repo,
        }


def parse_pr_arg(arg: str) -> tuple[str, int]:
    """Accept 4543, iiab/iiab#4543, or a full GitHub pull URL."""
    m = re.match(
        r"^https?://(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/(\d+)(?:/.*)?$",
        arg.strip(),
    )
    if m:
        return f"{m.group(1)}/{m.group(2)}", int(m.group(3))
    m = re.match(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#(\d+)$", arg.strip())
    if m:
        return f"{m.group(1)}/{m.group(2)}", int(m.group(3))
    if arg.strip().isdigit():
        return DEFAULT_REPO, int(arg.strip())
    die(f"could not parse PR {arg!r} (use 4543 or a github.com/.../pull/4543 URL)")


def _gh_available() -> bool:
    return shutil.which("gh") is not None


def _github_api_json(url: str) -> Any:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "iiab-deploy/1.0",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception as e:
        raise DeployError(f"GitHub API request failed: {url}: {e}") from e


def _gh_pr_files(repo: str, number: int) -> Optional[list[str]]:
    """List every changed path, past gh's 100-file limit for ``pr view``."""
    if not _gh_available():
        return None
    p = run(
        [
            "gh",
            "api",
            "--paginate",
            f"repos/{repo}/pulls/{number}/files?per_page=100",
            "--jq",
            ".[].filename",
        ],
        check=False,
        timeout=120,
        die_on_timeout=False,
    )
    if p.returncode != 0:
        return None
    return [line.strip() for line in (p.stdout or "").splitlines() if line.strip()]


def resolve_pr(repo: str, number: int) -> PRInfo:
    fields: dict[str, Any] = {
        "number": number,
        "title": "",
        "url": f"https://github.com/{repo}/pull/{number}",
        "state": "UNKNOWN",
        "isDraft": False,
        "headRefName": "",
        "headRefOid": "",
        "isCrossRepository": False,
        "files": [],
    }
    if _gh_available():
        p = run(
            [
                "gh",
                "pr",
                "view",
                str(number),
                "--repo",
                repo,
                "--json",
                "number,title,url,state,isDraft,headRefName,headRefOid,"
                "isCrossRepository,files",
            ],
            check=False,
            timeout=120,
            die_on_timeout=False,
        )
        if p.returncode == 0:
            try:
                parsed = json.loads(p.stdout)
            except json.JSONDecodeError:
                warn("gh returned non-JSON PR metadata; falling back to the API")
            else:
                fields.update(parsed)
                # gh pr view caps its file list; fetch every page instead.
                all_files = _gh_pr_files(repo, number)
                if all_files is None:
                    warn(
                        "could not list every changed file with gh; "
                        "changed-role detection may be incomplete"
                    )
                else:
                    fields["files"] = [{"path": path} for path in all_files]
        else:
            warn("gh pr view failed; falling back to the GitHub API")
    if not fields.get("title") and fields.get("state") == "UNKNOWN":
        meta = _github_api_json(f"https://api.github.com/repos/{repo}/pulls/{number}")
        fields.update(
            {
                "number": meta.get("number", number),
                "title": meta.get("title", ""),
                "url": meta.get("html_url", fields["url"]),
                "state": meta.get("state", "UNKNOWN").upper(),
                "isDraft": meta.get("draft", False),
                "headRefName": (meta.get("head") or {}).get("ref", ""),
                "headRefOid": (meta.get("head") or {}).get("sha", ""),
                "isCrossRepository": meta.get("head", {}).get("repo", {}).get(
                    "full_name", repo
                )
                != repo,
            }
        )
        files: list[dict[str, Any]] = []
        page = 1
        while True:
            chunk = _github_api_json(
                f"https://api.github.com/repos/{repo}/pulls/{number}/files"
                f"?per_page=100&page={page}"
            )
            if not chunk:
                break
            files.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
        fields["files"] = files

    changed = [
        str(f.get("path", ""))
        for f in (fields.get("files") or [])
        if f.get("path")
    ]
    auto_roles = sorted(
        {
            m.group(1)
            for path in changed
            if (m := re.match(r"^roles/([^/]+)/", path))
        }
    )
    modules_changed = any(p.startswith("modules/") for p in changed)

    # Prefer the merge ref (what GitHub would test), then the PR head.
    merge_ref = ""
    head_ref = f"refs/pull/{number}/head"
    if shutil.which("git"):
        p = run(
            [
                "git",
                "ls-remote",
                f"https://github.com/{repo}.git",
                f"refs/pull/{number}/merge",
                f"refs/pull/{number}/head",
            ],
            check=False,
            timeout=120,
            die_on_timeout=False,
        )
        if p.returncode == 0:
            for line in p.stdout.splitlines():
                parts = line.split()
                if len(parts) == 2 and parts[1] == f"refs/pull/{number}/merge":
                    merge_ref = parts[1]
    if not merge_ref:
        warn(
            f"no merge ref for {repo}#{number}; the first boot will fetch "
            f"{head_ref} instead"
        )

    return PRInfo(
        repo=repo,
        number=number,
        title=str(fields.get("title", "")),
        url=str(fields.get("url", "")),
        state=str(fields.get("state", "UNKNOWN")),
        draft=bool(fields.get("isDraft", False)),
        head_ref=head_ref,
        head_sha=str(fields.get("headRefOid", "")),
        merge_ref=merge_ref,
        changed_files=changed,
        auto_roles=auto_roles,
        modules_changed=modules_changed,
        cross_repo=bool(fields.get("isCrossRepository", False)),
    )


# ---------------------------------------------------------------------------
# Image selection
# ---------------------------------------------------------------------------


@dataclass
class ImageInfo:
    label: str
    url: str
    sha256: str
    compression: str  # xz | gzip | zstd | qcow2 | none


def choose_image(profile: str, arch: str) -> ImageInfo:
    if profile == "rpi":
        if arch in ("aarch64", "arm64", "armv7l"):
            rpi_arch = "arm64"
        elif arch == "armv6l":
            die(
                "the Raspberry Pi reports armv6l (Pi 1/Zero); the required "
                "Raspberry Pi OS Lite arm64 image cannot boot on it"
            )
        else:
            die(f"cannot pick a Raspberry Pi image for architecture {arch}")
        final = resolve_url(RPI_IMAGE_BASE.format(arch=rpi_arch))
        if not final or final.rstrip("/").endswith("_latest"):
            die(
                "could not resolve "
                + RPI_IMAGE_BASE.format(arch=rpi_arch)
                + " to a dated image URL; check network access to "
                "downloads.raspberrypi.org"
            )
        sha_text = http_get_text(final + ".sha256")
        first = sha_text.split()
        if not first:
            die(f"could not parse checksum from {final}.sha256")
        label = final.rsplit("/", 1)[-1]
        return ImageInfo(label=label, url=final, sha256=first[0], compression="xz")

    if arch in ("x86_64", "amd64"):
        u_arch = "amd64"
    elif arch in ("aarch64", "arm64"):
        u_arch = "arm64"
    else:
        die(f"Ubuntu 26.04 cloud images are not available for {arch}")
    url = UBUNTU_IMAGE_BASE.format(arch=u_arch)
    filename = url.rsplit("/", 1)[-1]
    sums = http_get_text(UBUNTU_SHA256SUMS)
    sha = ""
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == filename:
            sha = parts[0]
            break
    if not sha:
        die(f"could not find {filename} in {UBUNTU_SHA256SUMS}")
    return ImageInfo(
        label=filename, url=url, sha256=sha, compression="qcow2"
    )


# ---------------------------------------------------------------------------
# cloud-init / network rewriting
# ---------------------------------------------------------------------------


def _load_yaml():
    try:
        import yaml  # type: ignore
    except ImportError:
        return None
    return yaml


def parse_post_user(user_data: str, profile: str) -> str:
    yaml = _load_yaml()
    if yaml:
        try:
            data = yaml.safe_load(user_data) or {}
            users = data.get("users") or []
            for user in users:
                if isinstance(user, dict) and user.get("name"):
                    # "default" is cloud-init's reserved placeholder, not a
                    # real login name.
                    if str(user["name"]) != "default":
                        return str(user["name"])
        except Exception:
            pass
    m = re.search(
        r"^\s*-\s*name:\s*['\"]?([A-Za-z0-9_.-]+)", user_data, re.MULTILINE
    )
    if m and m.group(1) != "default":
        return m.group(1)
    return "pi" if profile == "rpi" else "ubuntu"


def rewrite_user_data(text: str, hostname: str) -> str:
    lines = text.splitlines()
    found = False
    for i, line in enumerate(lines):
        if re.match(r"^\s*hostname\s*:", line):
            lines[i] = f"hostname: {hostname}"
            found = True
            break
    if not found:
        lines.insert(0, f"hostname: {hostname}")
    return "\n".join(lines) + "\n"


def _remap_section(
    section: Any, candidates: list[str]
) -> dict[str, Any]:
    if not isinstance(section, dict):
        return {}
    out: dict[str, Any] = {}
    used: set[str] = set()
    # Pass 1: keys that already name a real candidate keep their name, so
    # placeholders in pass 2 cannot claim their slot.
    for key, cfg in section.items():
        if key in candidates:
            used.add(key)
            out[key] = dict(cfg) if isinstance(cfg, dict) else {}
    # Pass 2: remaining keys (placeholders) take the next unused candidate.
    for key, cfg in section.items():
        if key in candidates:
            continue
        new_key = next((c for c in candidates if c not in used), "")
        if not new_key:
            continue
        used.add(new_key)
        config = dict(cfg) if isinstance(cfg, dict) else {}
        # The template selected the device by a placeholder name (or by
        # match rules for the old hardware).  The ID now names the real
        # interface, so stale selectors would stop this config from
        # applying at all.
        config.pop("match", None)
        config.pop("set-name", None)
        out[new_key] = config
    return out


def physical_nics(probe: dict[str, Any]) -> list[str]:
    """Return the NICs that should exist on a freshly imaged system.

    IIAB (and container/VPN tooling) adds virtual interfaces such as ``br0``,
    ``ap0`` and ``tailscale0`` to the running system.  They must not be used as
    pin targets or as stand-ins for the new system's physical NICs.
    """
    all_nics = str(probe.get("NICS", "")).split()
    physical = [
        n for n in all_nics if not n.startswith(VIRTUAL_IFACE_PREFIXES)
    ]
    return physical or all_nics


def primary_interface(probe: dict[str, Any]) -> str:
    nics = physical_nics(probe)
    wifi = set(str(probe.get("WIFI_NICS", "")).split()) & set(nics)
    eth = [n for n in nics if n not in wifi]
    default_iface = str(probe.get("DEFAULT_IFACE", ""))
    if default_iface in nics:
        return default_iface
    if eth:
        return eth[0]
    if wifi:
        return sorted(wifi)[0]
    return ""


def apply_network_overrides(
    probe: dict[str, Any],
    *,
    ip: Optional[str] = None,
    gateway: Optional[str] = None,
    dns: Optional[str] = None,
) -> dict[str, Any]:
    """Return a probe copy with user-supplied network values.

    The IPv4 override must include a prefix, e.g. 192.168.1.50/24, because the
    netplan address and IIAB's netmask are both derived from it.
    """
    if not ip and not gateway and not dns:
        return probe
    out = dict(probe)
    if ip:
        if "/" not in ip:
            die("--ip must include a prefix, for example --ip 192.168.1.50/24")
        try:
            iface = ipaddress.ip_interface(ip)
        except ValueError as e:
            die(f"invalid --ip {ip!r}: {e}")
        if iface.version != 4:
            die("--ip must be an IPv4 address")
        primary = primary_interface(out)
        if not primary:
            die("could not determine the primary interface for --ip")
        out["DEFAULT_IFACE"] = primary
        out["IP4"] = f"{primary} {iface};"
    if gateway:
        try:
            gw = ipaddress.ip_address(gateway)
        except ValueError as e:
            die(f"invalid --gateway {gateway!r}: {e}")
        if gw.version != 4:
            die("--gateway must be an IPv4 address")
        out["GATEWAY4"] = str(gw)
    if dns:
        servers = [s for s in re.split(r"[\s,]+", dns) if s]
        for server in servers:
            try:
                ipaddress.ip_address(server)
            except ValueError as e:
                die(f"invalid --dns address {server!r}: {e}")
        out["DNS4"] = " ".join(servers)
    return out


def _ip_family(value: Any) -> int:
    """Return 4 or 6 for an address/CIDR/route string, 0 when unknown."""
    if not isinstance(value, str):
        return 0
    try:
        return ipaddress.ip_network(value, strict=False).version
    except ValueError:
        return 0


def _strip_ipv4_static(cfg: dict[str, Any]) -> bool:
    """Remove static IPv4 addressing so DHCPv4 can take over."""
    changed = False
    addresses = cfg.get("addresses")
    if isinstance(addresses, list):
        kept = [a for a in addresses if _ip_family(a) != 4]
        changed = changed or kept != addresses
        if kept:
            cfg["addresses"] = kept
        else:
            cfg.pop("addresses", None)
    routes = cfg.get("routes")
    if isinstance(routes, list):
        kept = [
            r
            for r in routes
            if not (
                isinstance(r, dict)
                and (
                    _ip_family(str(r.get("to", ""))) == 4
                    or _ip_family(str(r.get("via", ""))) == 4
                )
            )
        ]
        changed = changed or kept != routes
        if kept:
            cfg["routes"] = kept
        else:
            cfg.pop("routes", None)
    if "gateway4" in cfg:
        cfg.pop("gateway4", None)
        changed = True
    return changed


def rewrite_network_config(
    text: str,
    probe: dict[str, Any],
    *,
    pin_ip: bool = True,
    pin_ipv6: bool = True,
) -> tuple[str, list[str]]:
    """Rename placeholder interfaces and pin the current addresses.

    Both the plain network-config v2 form (``version: 2`` at the top level, as
    NoCloud documents) and the netplan-style ``network:`` wrapper are accepted.
    The output is always the plain form: cloud-init's NoCloud datasource reads
    ``version`` from the top level and only then hands the config to netplan.
    Stale ``match:``/``set-name:`` selectors are dropped when a placeholder ID
    is renamed, so the config applies to the probed NICs.

    Returns (yaml_text, notes).  Unknown/unmanaged interface names are dropped,
    because netplan refuses to apply a config that references a missing NIC.
    """
    notes: list[str] = []
    nics = physical_nics(probe)
    wifi = set(str(probe.get("WIFI_NICS", "")).split()) & set(nics)
    eth = [n for n in nics if n not in wifi]
    primary = primary_interface(probe)

    yaml = _load_yaml()
    if yaml is None:
        warn("PyYAML is not installed; only placeholder interface names are rewritten")
        out = text
        if eth:
            out = re.sub(r"(?m)^(\s*)eth0:", rf"\1{eth[0]}:", out)
        if wifi:
            out = re.sub(
                r"(?m)^(\s*)wlan0:", rf"\1{sorted(wifi)[0]}:", out
            )
        elif "wifis:" in out:
            notes.append("target has no WiFi NIC; review/remove the wifis section")
        return out, notes

    try:
        data = yaml.safe_load(text) or {}
    except Exception as e:
        die(f"failed to parse network-config as YAML: {e}")
    if not isinstance(data, dict):
        die("network-config must be a YAML mapping")

    wrapped = isinstance(data.get("network"), dict)
    if wrapped:
        outer = data
        data = dict(outer["network"])
        extra = sorted(set(outer) - {"network"})
        if extra:
            warn(
                "network-config: ignoring top-level keys outside network: "
                + ", ".join(extra)
            )
        if "version" not in data:
            die("network-config: the network: mapping has no version")

    version = data.get("version")
    if version is not None and version != 2:
        die(
            "network-config must be version 2 "
            f"(found version {version!r}); convert it before deploying"
        )

    ethernets = _remap_section(data.get("ethernets"), eth)
    wifis = _remap_section(data.get("wifis"), sorted(wifi))
    if not wifis and "wifis" in data:
        notes.append("target has no WiFi NIC; dropped the wifis section")
    if not ethernets and "ethernets" in data:
        notes.append("target has no matching Ethernet NIC; dropped ethernets")

    target_cfg: dict[str, Any] = {}
    section_name = ""
    if primary in eth:
        section_name = "ethernets"
        target_cfg = ethernets.setdefault(primary, {})
        if not target_cfg:
            target_cfg["dhcp4"] = True
    elif primary in wifi:
        section_name = "wifis"
        target_cfg = wifis.setdefault(primary, {})
        if not target_cfg:
            target_cfg["dhcp4"] = True
        if "access-points" not in target_cfg:
            notes.append(
                f"target uses WiFi ({primary}) but the network-config has no "
                "access-points for it; WiFi may not associate"
            )
    elif eth or wifi:
        notes.append(
            "could not determine the primary interface; leaving DHCP as-is"
        )

    ip4 = parse_ip_map(str(probe.get("IP4", "")))
    ip6 = parse_ip_map(str(probe.get("IP6", "")))
    gw4 = str(probe.get("GATEWAY4", "")).strip()
    gw6 = str(probe.get("GATEWAY6", "")).strip()
    dns = str(probe.get("DNS4", "")).split() or ["1.1.1.1", "8.8.8.8"]

    if section_name:
        pin4 = (
            pin_ip
            and primary in ip4
            and not ip4[primary].startswith("169.254.")
        )
        pin6 = (
            pin_ipv6
            and primary in ip6
            and bool(gw6)
            and not gw6.startswith("fe80:")
        )

        # Keep static addressing for families we are not pinning.  IPv4 is
        # special: it falls back to DHCP below, so stale IPv4 config is
        # dropped rather than preserved.
        addresses: list[str] = []
        template_addresses = target_cfg.get("addresses")
        if isinstance(template_addresses, list):
            addresses.extend(
                str(a)
                for a in template_addresses
                if _ip_family(a) != 4 and not (pin6 and _ip_family(a) == 6)
            )
        routes: list[dict[str, Any]] = []
        template_routes = target_cfg.get("routes")
        if isinstance(template_routes, list):
            for route in template_routes:
                if not isinstance(route, dict):
                    continue
                family = _ip_family(str(route.get("to", ""))) or _ip_family(
                    str(route.get("via", ""))
                )
                if family == 4:
                    continue  # rebuilt from the pinned gateway, or DHCPv4
                if family == 6 and pin6:
                    continue  # rebuilt from the pinned gateway
                routes.append(route)

        pinned: list[str] = []
        if pin4:
            addresses.insert(0, ip4[primary])
            target_cfg["dhcp4"] = False
            target_cfg.pop("dhcp4-overrides", None)
            target_cfg.pop("gateway4", None)
            pinned.append(f"IPv4 {ip4[primary]}")
            if gw4:
                routes.insert(0, {"to": "default", "via": gw4})
                pinned.append(f"gateway {gw4}")
            else:
                notes.append(
                    f"no default IPv4 gateway was found; {primary} will have "
                    "a static address but no route"
                )
        else:
            cleared = _strip_ipv4_static(target_cfg)
            target_cfg["dhcp4"] = True
            if pin_ip:
                notes.append(f"no usable IPv4 on {primary}; using DHCP")
            elif cleared:
                notes.append(
                    f"cleared static IPv4 config on {primary}; using DHCP"
                )
        if pin6:
            addresses.append(ip6[primary])
            target_cfg["dhcp6"] = False
            target_cfg["accept-ra"] = False
            target_cfg.pop("dhcp6-overrides", None)
            target_cfg.pop("gateway6", None)
            if gw6:
                routes.append({"to": "::/0", "via": gw6})
                pinned.append(f"gateway {gw6}")
            pinned.append(f"IPv6 {ip6[primary]}")
        if addresses:
            target_cfg["addresses"] = addresses
        else:
            target_cfg.pop("addresses", None)
        if routes:
            target_cfg["routes"] = routes
        else:
            target_cfg.pop("routes", None)
        if pin4 or pin6:
            target_cfg["nameservers"] = {"addresses": dns}
        if pinned:
            notes.append(f"pinned {'; '.join(pinned)} on {primary}")

    if ethernets:
        data["ethernets"] = ethernets
    else:
        data.pop("ethernets", None)
    if wifis:
        data["wifis"] = wifis
    else:
        data.pop("wifis", None)
    data["version"] = 2

    out = yaml.safe_dump(
        data,
        sort_keys=False,
        default_flow_style=False,
        width=1000,
    )
    return out, notes


def choose_disk(
    probe: dict[str, Any], requested: Optional[str]
) -> tuple[str, dict[str, Any], bool]:
    """Return (device, lsblk fields, is_root_disk)."""
    disks = [
        d
        for d in probe.get("disks", [])
        if d.get("TYPE") == "disk"
        and not d.get("NAME", "").startswith(
            ("loop", "zram", "ram", "sr", "fd", "dm-")
        )
    ]
    if not disks:
        die("no block devices found on the target")
    root_disk = str(probe.get("ROOT_DISK", ""))
    by_name = {d["NAME"]: d for d in disks}

    if requested:
        name = requested
        if name.startswith("/dev/"):
            name = name[len("/dev/") :]
        name = name.split("/")[-1]
        if name not in by_name:
            die(
                f"{requested} is not a whole disk on the target. Candidates: "
                + ", ".join(f"/dev/{n}" for n in sorted(by_name))
            )
        return f"/dev/{name}", by_name[name], name == root_disk

    if len(disks) == 1:
        name = disks[0]["NAME"]
        return f"/dev/{name}", disks[0], name == root_disk

    die(
        "multiple disks found; pass --disk with one of:\n"
        + "\n".join(
            "  /dev/{:<12} {:>10}  {}  {}".format(
                d["NAME"],
                d.get("SIZE", "?"),
                "ROOT" if d["NAME"] == root_disk else "    ",
                d.get("MODEL", ""),
            )
            for d in sorted(disks, key=lambda x: x["NAME"])
        )
    )


# ---------------------------------------------------------------------------
# Embedded remote payloads
# ---------------------------------------------------------------------------

FIRSTBOOT_UNIT = r'''[Unit]
Description=IIAB deploy first-boot install
Wants=network-online.target
After=cloud-final.service network-online.target
ConditionPathExists=!/var/lib/iiab-deploy/attempted
ConditionPathExists=!/var/lib/iiab-deploy/done
ConditionPathExists=!/var/lib/iiab-deploy/failed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/iiab-deploy-firstboot
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'''

FIRSTBOOT_SH = r'''#!/bin/bash
# IIAB deploy first-boot installer.
#
# This runs from iiab-deploy-firstboot.service after cloud-init and installs
# IIAB from the requested PR, then runs the PR's changed roles.
set -uo pipefail

CONF=/var/lib/iiab-deploy/config.env
STATE_DIR=/var/lib/iiab-deploy
LOG_DIR=/var/log/iiab-deploy
mkdir -p "$STATE_DIR" "$LOG_DIR"
touch "$STATE_DIR/attempted"
LOG="$LOG_DIR/firstboot.log"

# systemd sends our output to the journal and the console (tty0/serial).
# tee adds a file that can be followed over SSH.
if command -v stdbuf >/dev/null 2>&1; then
    exec > >(stdbuf -oL -eL tee -a "$LOG") 2>&1
else
    exec > >(tee -a "$LOG") 2>&1
fi

if [ ! -f "$CONF" ]; then
    echo "FATAL: missing $CONF"
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

START=$(date -Is)
export START
INSTALL_RC=""
ROLES_RC=""
MODULE_RC=""
RESULT="$STATE_DIR/result.json"
STATE_DIFF=""
FAILED=0

section() { echo; echo "===== IIAB_DEPLOY: $* ====="; }

fail() {
    FAILED=1
    echo "ERROR: $*"
}

write_result() {
    STATUS="$1"
    FINISHED=$(date -Is)
    export START STATUS FINISHED PR_REPO PR_NUMBER PR_TITLE PR_URL PR_REF PR_HEAD_SHA
    export PROFILE HOSTNAME ROLES ROLES_AUTO ROLES_OVERRIDE INSTALL_RC
    export ROLES_RC MODULE_RC LOG FAILED STATE_DIFF
    python3 - "$RESULT" <<'PY' || true
import json, os, sys

def as_int(name):
    value = os.environ.get(name, "").strip()
    try:
        return int(value)
    except ValueError:
        return None

data = {
    "status": os.environ.get("STATUS"),
    "started": os.environ.get("START", ""),
    "finished": os.environ.get("FINISHED", ""),
    "pr_repo": os.environ.get("PR_REPO"),
    "pr_number": os.environ.get("PR_NUMBER"),
    "pr_title": os.environ.get("PR_TITLE"),
    "pr_url": os.environ.get("PR_URL"),
    "pr_ref": os.environ.get("PR_REF"),
    "pr_sha": os.environ.get("PR_HEAD_SHA"),
    "profile": os.environ.get("PROFILE"),
    "hostname": os.environ.get("HOSTNAME"),
    "roles": os.environ.get("ROLES", "").split(),
    "roles_auto": os.environ.get("ROLES_AUTO", "").split(),
    "roles_override": os.environ.get("ROLES_OVERRIDE") == "1",
    "install_rc": as_int("INSTALL_RC"),
    "roles_rc": as_int("ROLES_RC"),
    "module_tests_rc": as_int("MODULE_RC"),
    "log": os.environ.get("LOG"),
    "state_diff": os.environ.get("STATE_DIFF", ""),
}
with open(sys.argv[1], "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
PY
    sync
}

finish() {
    status="$1"
    write_result "$status"
    if [ "$status" = "success" ]; then
        : > "$STATE_DIR/done"
    else
        : > "$STATE_DIR/failed"
    fi
    sync
    echo "IIAB_DEPLOY_DONE status=$status"
}

on_exit() {
    rc=$?
    if [ ! -f "$STATE_DIR/done" ] && [ ! -f "$STATE_DIR/failed" ]; then
        finish failed
    fi
    exit "$rc"
}
trap on_exit EXIT

section "Starting IIAB deploy"
echo "PR:          $PR_URL"
echo "Ref:         $PR_REF"
echo "Profile:     $PROFILE"
echo "Hostname:    $HOSTNAME"
echo "Roles:       ${ROLES:-<none>}"
echo "Auto roles:  ${ROLES_AUTO:-<none>}"
echo "Override:    $ROLES_OVERRIDE"
echo "Started:     $START"

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

section "Waiting for the network"
for _ in $(seq 1 60); do
    getent hosts github.com >/dev/null 2>&1 && break
    sleep 5
done
if ! getent hosts github.com >/dev/null 2>&1; then
    echo "WARNING: github.com is not resolvable; the install may fail"
fi

if command -v cloud-init >/dev/null 2>&1; then
    timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
fi

section "Installing base packages"
apt-get update -y || fail "apt-get update failed"
apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip tmux e2fsprogs \
    cloud-guest-utils || \
    fail "some base packages could not be installed"

# An attachable read-only viewer over SSH, after tmux is installed.  The
# install itself stays in the systemd unit, so losing SSH never interrupts it.
if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t iiab-deploy 2>/dev/null || true
    tmux new-session -d -s iiab-deploy "tail -n +1 -F '$LOG'" 2>/dev/null || true
elif command -v screen >/dev/null 2>&1; then
    screen -dmS iiab-deploy tail -n +1 -F "$LOG" 2>/dev/null || true
elif command -v abduco >/dev/null 2>&1; then
    abduco -n iiab-deploy tail -n +1 -F "$LOG" 2>/dev/null || true
fi

section "Growing the root filesystem"
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$ROOT_SRC" ]; then
    DISK_NAME=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)
    PARTNUM=$(cat "/sys/class/block/$(basename "$ROOT_SRC")/partition" 2>/dev/null || true)
    if [ -n "$DISK_NAME" ] && [ -n "$PARTNUM" ]; then
        growpart "/dev/$DISK_NAME" "$PARTNUM" 2>/dev/null || true
        resize2fs "$ROOT_SRC" 2>/dev/null || true
    fi
fi
df -h / /var 2>/dev/null || true

if [ "$PROFILE" = "rpi" ] && [ "${RPI_UPGRADE:-0}" = "1" ]; then
    section "Raspberry Pi OS preparation"
    apt-get -y full-upgrade || fail "apt-get full-upgrade failed"
    apt-get -y remove 'libcamera*' || true
    apt-get -y autoremove || true
fi

section "Cloning $PR_REPO"
rm -rf /opt/iiab/iiab
mkdir -p /opt/iiab
if ! git clone --progress "https://github.com/$PR_REPO.git" /opt/iiab/iiab; then
    fail "git clone failed"
    finish failed
    exit 1
fi
cd /opt/iiab/iiab || {
    fail "cannot cd to /opt/iiab/iiab"
    finish failed
    exit 1
}

FETCHED=0
for ref in "$PR_REF" "$PR_REF_HEAD" "$PR_HEAD_SHA"; do
    [ -n "$ref" ] || continue
    if git fetch --progress origin "$ref"; then
        FETCHED=1
        break
    fi
done
if [ "$FETCHED" != "1" ]; then
    fail "could not fetch any ref for PR $PR_NUMBER"
    finish failed
    exit 1
fi
if ! git checkout --detach FETCH_HEAD; then
    fail "git checkout failed"
    finish failed
    exit 1
fi
git log -1 --oneline

section "Configuring local_vars.yml (tiny profile)"
mkdir -p /etc/iiab
cp vars/local_vars_tiny.yml /etc/iiab/local_vars.yml
sed -i "s|^iiab_hostname:.*|iiab_hostname: $HOSTNAME|" /etc/iiab/local_vars.yml
if [ "$PROFILE" = "rpi" ]; then
    if grep -qE '^rpi_image:' /etc/iiab/local_vars.yml; then
        sed -i -E 's|^rpi_image:.*|rpi_image: True|' /etc/iiab/local_vars.yml
    else
        echo 'rpi_image: True' >> /etc/iiab/local_vars.yml
    fi
fi
if [ -n "${PIN_IP:-}" ]; then
    sed -i "s|^wan_ip:.*|wan_ip: $PIN_IP|" /etc/iiab/local_vars.yml
    [ -n "${PIN_NETMASK:-}" ] && sed -i "s|^wan_netmask:.*|wan_netmask: $PIN_NETMASK|" /etc/iiab/local_vars.yml
    [ -n "${PIN_GATEWAY:-}" ] && sed -i "s|^wan_gateway:.*|wan_gateway: $PIN_GATEWAY|" /etc/iiab/local_vars.yml
    [ -n "${PIN_DNS:-}" ] && sed -i "s|^wan_nameserver:.*|wan_nameserver: $PIN_DNS|" /etc/iiab/local_vars.yml
    echo "Pinned IIAB WAN address: $PIN_IP $PIN_NETMASK via ${PIN_GATEWAY:-?}"
fi
grep -E '^(iiab_hostname|wan_ip|wan_netmask|wan_gateway):' /etc/iiab/local_vars.yml || true

section "Installing Ansible"
if ! scripts/ansible; then
    if command -v ansible-playbook >/dev/null 2>&1; then
        echo "WARNING: scripts/ansible failed but ansible-playbook exists; continuing"
    else
        fail "scripts/ansible failed"
        finish failed
        exit 1
    fi
fi

section "Running iiab-install $IIAB_INSTALL_ARGS"
# shellcheck disable=SC2086  # IIAB_INSTALL_ARGS is a deliberate argument list
./iiab-install $IIAB_INSTALL_ARGS
INSTALL_RC=$?
echo "iiab-install exit code: $INSTALL_RC"
if [ "$INSTALL_RC" -ne 0 ]; then
    fail "iiab-install failed"
fi

if [ -n "$(printf '%s' "${ROLES:-}" | tr -d '[:space:]')" ]; then
    section "Running changed roles: $ROLES"
    for role in $ROLES; do
        case "$role" in
            [0-9]-*) continue ;;
        esac
        case "$role" in
            iiab-admin) var=iiab_admin ;;
            calibre-web) var=calibreweb ;;
            osm-vector-maps) var=osm_vector_maps ;;
            *) var=$(printf '%s' "$role" | tr '-' '_') ;;
        esac
        for suffix in install enabled; do
            key="${var}_${suffix}"
            if grep -qE "^${key}:" /etc/iiab/local_vars.yml; then
                sed -i -E "s|^${key}:.*|${key}: True|" /etc/iiab/local_vars.yml
            else
                echo "${key}: True" >> /etc/iiab/local_vars.yml
            fi
        done
    done

    TMP_PLAY=/opt/iiab/iiab/iiab-deploy-runroles.yml
    cp runroles-base.yml "$TMP_PLAY"
    for role in $ROLES; do
        [ "$role" = "0-init" ] && continue
        printf '    - { role: %s }\n' "$role" >> "$TMP_PLAY"
    done
    export ANSIBLE_LOG_PATH="$LOG_DIR/ansible-roles.log"
    ansible-playbook -i ansible_hosts "$TMP_PLAY" --connection=local
    ROLES_RC=$?
    echo "changed-role exit code: $ROLES_RC"
    [ "$ROLES_RC" -eq 0 ] || fail "changed roles failed"
    rm -f "$TMP_PLAY"
fi

if [ "${RUN_MODULE_TESTS:-0}" = "1" ] && [ -f modules/tests/get_curl.yml ]; then
    section "Running changed module tests"
    ANSIBLE_LIBRARY=modules ansible-playbook -i localhost, modules/tests/get_curl.yml
    MODULE_RC=$?
    echo "module test exit code: $MODULE_RC"
    [ "$MODULE_RC" -eq 0 ] || fail "module tests failed"
fi

EXPECTED=".github/workflows/tests/expected_state_tiny_image.yml"
if [ -f "$EXPECTED" ] && [ -f /etc/iiab/iiab_state.yml ]; then
    section "Comparing IIAB state"
    sort "$EXPECTED" > /tmp/iiab-deploy-expected.sorted
    sort /etc/iiab/iiab_state.yml > /tmp/iiab-deploy-state.sorted
    diff -u /tmp/iiab-deploy-expected.sorted /tmp/iiab-deploy-state.sorted > "$LOG_DIR/state.diff" || true
    STATE_DIFF="$LOG_DIR/state.diff"
    echo "State diff: $STATE_DIFF ($(wc -l < "$STATE_DIFF") lines)"
    head -60 "$STATE_DIFF" || true
fi

section "IIAB summary"
if command -v iiab-summary >/dev/null 2>&1; then
    iiab-summary || true
fi

if [ "$FAILED" -eq 0 ]; then
    finish success
else
    finish failed
fi
'''

REMOTE_SETUP_SH = r'''#!/bin/bash
# Runs on the target as root, before kexec.  It prepares an initramfs that
# writes the new image and injects the first-boot payload.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./config.env

log() { printf '\n[iiab-deploy] %s\n' "$*"; }
die() { printf '\n[iiab-deploy] FATAL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "remote setup must run as root"
[ -b "$TARGET_DISK" ] || die "target disk $TARGET_DISK not found"

export DEBIAN_FRONTEND=noninteractive
missing=0
for c in curl gzip xz zstd cpio tar sha256sum kexec blockdev blkid depmod wget; do
    command -v "$c" >/dev/null 2>&1 || missing=1
done
command -v unmkinitramfs >/dev/null 2>&1 || missing=1
if [ "${NETBURN:-0}" = "0" ] && [ "${IMAGE_COMPRESSION:-none}" = "qcow2" ]; then
    command -v qemu-img >/dev/null 2>&1 || missing=1
fi
if [ "$missing" -eq 1 ]; then
    log "Installing host-side dependencies"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        kexec-tools initramfs-tools cpio gzip xz-utils zstd curl wget \
        iproute2 ca-certificates util-linux kmod || die "apt-get install failed"
    if [ "${NETBURN:-0}" = "0" ] && [ "${IMAGE_COMPRESSION:-none}" = "qcow2" ]; then
        apt-get install -y --no-install-recommends qemu-utils || \
            die "apt-get install qemu-utils failed"
    fi
fi
command -v unmkinitramfs >/dev/null 2>&1 || \
    die "unmkinitramfs is required (install initramfs-tools)"

KVER=$(uname -r)
MACHINE=$(uname -m)
RPI_KERNEL_PREF=""
case "$MACHINE" in
    aarch64|arm64)
        if grep -qa 'bcm2712' /proc/device-tree/compatible 2>/dev/null; then
            RPI_KERNEL_PREF="/boot/firmware/kernel_2712.img /boot/kernel_2712.img /boot/firmware/kernel8.img /boot/kernel8.img"
        else
            RPI_KERNEL_PREF="/boot/firmware/kernel8.img /boot/kernel8.img /boot/firmware/kernel_2712.img /boot/kernel_2712.img"
        fi
        ;;
    armv7l)
        RPI_KERNEL_PREF="/boot/firmware/kernel7l.img /boot/kernel7l.img /boot/firmware/kernel7.img /boot/kernel7.img"
        ;;
    armv6l)
        RPI_KERNEL_PREF="/boot/firmware/kernel.img /boot/kernel.img"
        ;;
esac
KERNEL=""
for c in "/boot/vmlinuz-$KVER" "/boot/kernel-$KVER" "/boot/bzImage-$KVER" \
         "/boot/firmware/vmlinuz-$KVER" "/boot/firmware/kernel-$KVER" \
         $RPI_KERNEL_PREF; do
    [ -f "$c" ] && { KERNEL=$c; break; }
done
[ -n "$KERNEL" ] || die "kernel image for $KVER not found"
INITRD=""
for c in "/boot/initrd.img-$KVER" "/boot/initrd-$KVER" \
         "/boot/firmware/initrd.img-$KVER" "/boot/initramfs-$KVER" \
         "/boot/firmware/initramfs8" "/boot/firmware/initramfs_2712" \
         "/boot/firmware/initramfs7l" "/boot/firmware/initramfs7" \
         "/boot/firmware/initrd.img" "/boot/initramfs8" \
         "/boot/initramfs_2712" "/boot/initramfs7l" "/boot/initramfs7"; do
    [ -f "$c" ] && { INITRD=$c; break; }
done
[ -n "$INITRD" ] || die "initramfs for $KVER not found (UKI-only systems are not supported)"
log "kernel: $KERNEL"
log "initramfs: $INITRD"

# ---- image ----
free_mb() {
    local mb
    mb=$(df -Pm /var/tmp 2>/dev/null | awk 'NR==2 {print $4}')
    case "$mb" in
        ''|*[!0-9]*) die "could not determine free space in /var/tmp" ;;
    esac
    printf '%s' "$mb"
}

image_uncompressed_size() {
    # Best-effort size of the decompressed image, before decompressing it.
    case "${IMAGE_COMPRESSION:-none}" in
        qcow2)
            qemu-img info "$1" 2>/dev/null | \
                awk -F'[()]' '/virtual size/ {print $2}' | awk '{print $1}'
            ;;
        xz)
            xz --robot --list "$1" 2>/dev/null | \
                awk '$1 == "totals" {print $5}'
            ;;
        gzip|gz)
            gzip -l "$1" 2>/dev/null | awk 'NR==2 {print $2}'
            ;;
        none|raw)
            stat -c '%s' "$1"
            ;;
    esac
}

if [ "$NETBURN" = "0" ]; then
    mkdir -p image
    if [ ! -s image/base.img ]; then
        FREE_MB=$(free_mb)
        DL_BYTES=$(curl -fsSIL --retry 2 --connect-timeout 30 "$IMAGE_URL" 2>/dev/null | \
            awk 'tolower($1) == "content-length:" {gsub("\r", "", $2); print $2}' | \
            tail -1) || true
        case "$DL_BYTES" in
            ''|*[!0-9]*) DL_BYTES=0 ;;
        esac
        if [ "$DL_BYTES" -gt 0 ]; then
            NEED_MB=$((DL_BYTES / 1024 / 1024 + 512))
        else
            NEED_MB=1024
        fi
        if [ "$FREE_MB" -lt "$NEED_MB" ]; then
            die "only ${FREE_MB} MiB free in /var/tmp; downloading needs ~${NEED_MB} MiB. Use --netburn."
        fi
        log "Downloading base image: $IMAGE_URL"
        rm -f image/download
        curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 \
            -o image/download "$IMAGE_URL" || die "download failed"
        if [ -n "${IMAGE_SHA256:-}" ]; then
            echo "$IMAGE_SHA256  image/download" | sha256sum -c - || \
                die "checksum mismatch"
        fi
        RAW_BYTES=$(image_uncompressed_size image/download) || true
        if [ -n "$RAW_BYTES" ] && [ "$RAW_BYTES" -gt 0 ] 2>/dev/null; then
            RAW_MB=$((RAW_BYTES / 1024 / 1024))
            FREE_MB=$(free_mb)
            NEED_MB=$((RAW_MB + 512))
            log "decompressed image: ~${RAW_MB} MiB; /var/tmp free: ${FREE_MB} MiB"
            if [ "$FREE_MB" -lt "$NEED_MB" ]; then
                rm -f image/download
                die "not enough free space to decompress the image (need ~${NEED_MB} MiB); use --netburn"
            fi
        fi
        case "${IMAGE_COMPRESSION:-none}" in
            xz) xz -dc image/download > image/base.img ;;
            gzip|gz) gzip -dc image/download > image/base.img ;;
            zstd|zst) zstd -dc image/download > image/base.img ;;
            qcow2) qemu-img convert -f qcow2 -O raw image/download image/base.img ;;
            none|raw) mv image/download image/base.img ;;
            *) die "unknown image compression: $IMAGE_COMPRESSION" ;;
        esac
        rm -f image/download
    fi
    RAW_SIZE=$(stat -c '%s' image/base.img)
    RAW_MB=$((RAW_SIZE / 1024 / 1024))
    DISK_SIZE=$(blockdev --getsize64 "$TARGET_DISK")
    [ "$RAW_SIZE" -le "$DISK_SIZE" ] || \
        die "image ($RAW_SIZE bytes) is larger than $TARGET_DISK ($DISK_SIZE bytes)"
    # gzip -1 of an OS image is much smaller than the raw image; this keeps a
    # wide margin over the usual ~30% while still failing before the disk is
    # completely full.
    FREE_MB=$(free_mb)
    NEED_MB=$((RAW_MB / 2 + 512))
    log "image: ${RAW_MB} MiB raw; /var/tmp free: ${FREE_MB} MiB"
    if [ "$FREE_MB" -lt "$NEED_MB" ]; then
        die "not enough free space in /var/tmp to compress the image (need ~${NEED_MB} MiB); use --netburn"
    fi
    log "Compressing image for the initramfs (gzip -1)"
    gzip -1 -c image/base.img > image/base.img.gz
    EMBED=image/base.img.gz
else
    log "Netburn mode: the initramfs will stream $NETBURN_URL"
    if [ -n "${IMAGE_RAW_SIZE:-}" ] && [ "${IMAGE_RAW_SIZE:-0}" -gt 0 ]; then
        DISK_SIZE=$(blockdev --getsize64 "$TARGET_DISK")
        [ "$IMAGE_RAW_SIZE" -le "$DISK_SIZE" ] || \
            die "image is larger than $TARGET_DISK"
    fi
fi

# A 1.2 GiB compressed image inside the initramfs needs room in RAM.
if [ "$NETBURN" = "0" ] && [ -n "${MEM_MB:-}" ]; then
    IMG_MB=$(( $(stat -c '%s' "$EMBED") / 1024 / 1024 ))
    if [ "$MEM_MB" -lt $((IMG_MB + 768)) ]; then
        die "only ${MEM_MB} MiB RAM; the embedded initramfs needs ~$((IMG_MB + 768)) MiB. Use --netburn."
    fi
fi

# ---- unpack the running initramfs ----
rm -rf initrd
mkdir -p initrd
log "Unpacking $INITRD"
unmkinitramfs "$INITRD" initrd >/dev/null 2>&1 || die "unmkinitramfs failed"
if [ -d initrd/main ]; then
    MAIN=initrd/main
else
    MAIN=initrd
fi
[ -f "$MAIN/init" ] || die "no /init found in $INITRD (unexpected initramfs layout)"
cp -a "$MAIN/init" "$MAIN/init.iiab-deploy-orig"
rm -f "$MAIN/init"
cp initramfs-init.sh "$MAIN/init"
chmod 755 "$MAIN/init"

# ---- payload ----
rm -rf "$MAIN/payload"
mkdir -p "$MAIN/payload"
tar -xzf payload.tar.gz -C "$MAIN/payload" || die "failed to extract payload"

# ---- embed image ----
if [ "$NETBURN" = "0" ]; then
    cp "$EMBED" "$MAIN/iiab-image.img.gz"
    rm -f image/base.img image/base.img.gz
fi

# ---- make sure target-disk modules are present ----
stage_module() {
    local mod="$1" line f rel dest
    command -v modprobe >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        case "$line" in
            insmod\ *) f=${line#insmod } ;;
            *) continue ;;
        esac
        [ -f "$f" ] || continue
        case "$f" in
            /lib/modules/"$KVER"/*) rel=${f#/lib/modules/"$KVER"/} ;;
            *) continue ;;
        esac
        dest="$MAIN/lib/modules/$KVER/$rel"
        mkdir -p "$(dirname "$dest")"
        cp -L "$f" "$dest" 2>/dev/null || true
    done < <(modprobe --show-depends "$mod" 2>/dev/null || true)
}

DEP_BACKUP=""
if [ -f "$MAIN/lib/modules/$KVER/modules.dep" ]; then
    DEP_BACKUP="$MAIN/lib/modules/$KVER/modules.dep.iiab-deploy-bak"
    cp -a "$MAIN/lib/modules/$KVER/modules.dep" "$DEP_BACKUP"
fi
for m in nvme nvme-core ahci libahci sd_mod mmc_block sdhci sdhci_pci \
         sdhci_iproc sdhci_of_dwcmshc usb-storage uas xhci_pci xhci_hcd \
         virtio virtio_ring virtio_pci virtio_blk virtio_net dm_mod ext4 vfat; do
    stage_module "$m"
done
if command -v depmod >/dev/null 2>&1; then
    if ! depmod -b "$MAIN" "$KVER" >/dev/null 2>&1; then
        log "WARNING: depmod failed; keeping the original modules.dep"
        if [ -n "$DEP_BACKUP" ]; then
            cp -a "$DEP_BACKUP" "$MAIN/lib/modules/$KVER/modules.dep"
        fi
    fi
fi

# ---- copy kexec + shared libraries ----
copy_bin_with_libs() {
    local bin="$1" root="$2" line lib
    [ -f "$bin" ] || return 0
    mkdir -p "$root$(dirname "$bin")"
    rm -f "$root$bin"
    cp -L "$bin" "$root$bin"
    chmod 755 "$root$bin"
    command -v ldd >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        case "$line" in
            *'=> not found'*) continue ;;
            *'=>'*) lib=$(printf '%s\n' "$line" | awk '{print $3}') ;;
            /*) lib=$(printf '%s\n' "$line" | awk '{print $1}') ;;
            *) continue ;;
        esac
        [ -n "$lib" ] && [ -f "$lib" ] || continue
        mkdir -p "$root$(dirname "$lib")"
        rm -f "$root$lib"
        cp -L "$lib" "$root$lib" 2>/dev/null || true
    done < <(ldd "$bin" 2>/dev/null || true)
}
if command -v kexec >/dev/null 2>&1; then
    copy_bin_with_libs "$(command -v kexec)" "$MAIN"
fi
if command -v gzip >/dev/null 2>&1; then
    copy_bin_with_libs "$(command -v gzip)" "$MAIN"
fi
for b in wipefs blockdev blkid; do
    if command -v "$b" >/dev/null 2>&1; then
        copy_bin_with_libs "$(command -v "$b")" "$MAIN"
    fi
done
if [ "$NETBURN" = "1" ]; then
    for b in wget ip; do
        if command -v "$b" >/dev/null 2>&1; then
            copy_bin_with_libs "$(command -v "$b")" "$MAIN"
        fi
    done
fi

# ---- busybox applets for netburn ----
if [ -x "$MAIN/bin/busybox" ]; then
    for app in ip udhcpc wget gunzip gzip zcat insmod modprobe; do
        if [ ! -e "$MAIN/bin/$app" ] && [ ! -e "$MAIN/usr/bin/$app" ] && \
           [ ! -e "$MAIN/sbin/$app" ] && [ ! -e "$MAIN/usr/sbin/$app" ]; then
            ln -sf busybox "$MAIN/bin/$app" 2>/dev/null || true
        fi
    done
fi

# ---- repack ----
log "Repacking initramfs"
( cd "$MAIN" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null ) \
    | gzip -1 > initramfs.cpio.gz || die "repack failed"
[ -s initramfs.cpio.gz ] || die "repacked initramfs is empty"
log "initramfs size: $(du -h initramfs.cpio.gz | awk '{print $1}')"

# ---- kexec ----
CMDLINE="root=/dev/ram rw quiet panic=10 console=tty0 console=ttyS0,115200 iiab_deploy=1 iiab_deploy_disk=$TARGET_DISK iiab_deploy_profile=$PROFILE iiab_deploy_netburn=$NETBURN iiab_deploy_reboot=$FINAL_REBOOT"
if [ "$NETBURN" = "1" ]; then
    CMDLINE="$CMDLINE iiab_deploy_url=$NETBURN_URL"
fi
log "Loading kexec kernel"
kexec -l "$KERNEL" --initrd=initramfs.cpio.gz --command-line="$CMDLINE" \
    || die "kexec -l failed; the running system was not touched"
sync
echo "IIAB_DEPLOY_KEXEC_READY"
log "Executing kexec"
kexec -e || die "kexec -e failed"
'''

INITRAMFS_INIT_SH = r'''#!/bin/sh
# IIAB deploy initramfs init: write the new image and inject first-boot data.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG() { echo "[iiab-deploy-init] $*"; }
FATAL() {
    LOG "FATAL: $*"
    sync
    sleep 30
    reboot -f
    exit 1
}

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

for app in ip udhcpc wget gunzip gzip zcat insmod modprobe; do
    if ! command -v "$app" >/dev/null 2>&1 && [ -x /bin/busybox ]; then
        ln -sf /bin/busybox "/bin/$app" 2>/dev/null || true
    fi
done

DISK=""
NETBURN="0"
URL=""
PROFILE=""
REBOOT_AFTER="0"
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        iiab_deploy_disk=*) DISK=${arg#*=} ;;
        iiab_deploy_netburn=*) NETBURN=${arg#*=} ;;
        iiab_deploy_url=*) URL=${arg#*=} ;;
        iiab_deploy_profile=*) PROFILE=${arg#*=} ;;
        iiab_deploy_reboot=*) REBOOT_AFTER=${arg#*=} ;;
    esac
done
[ -n "$DISK" ] || FATAL "iiab_deploy_disk missing"

CONF=/payload/var/lib/iiab-deploy/config.env
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi
HOSTNAME=${HOSTNAME:-box}
LOG_DIR=${LOG_DIR:-/var/log/iiab-deploy}
STATE_DIR=${STATE_DIR:-/var/lib/iiab-deploy}

# Wait for the target disk and load storage drivers.
i=0
while [ "$i" -lt 30 ]; do
    [ -b "$DISK" ] && break
    for m in nvme nvme-core ahci libahci sd_mod mmc_block sdhci sdhci_pci \
             usb-storage uas xhci_pci xhci_hcd virtio virtio_ring virtio_pci \
             virtio_blk dm_mod; do
        modprobe "$m" 2>/dev/null || true
    done
    for m in nvme-core nvme libahci ahci sd_mod mmc_block sdhci sdhci_pci \
             virtio virtio_ring virtio_pci virtio_blk dm_mod; do
        for f in /lib/modules/*/kernel/*/"$m".ko* /lib/modules/*/kernel/*/*/"$m".ko*; do
            [ -f "$f" ] && insmod "$f" 2>/dev/null || true
        done
    done
    sleep 1
    i=$((i + 1))
done
[ -b "$DISK" ] || FATAL "target disk $DISK not found"
LOG "target disk: $DISK"

# Remove stale signatures only when we are ready to write.  This is not a
# secure erase.  Delaying it until after the netburn network is up avoids
# making the old system unbootable if DHCP fails first.
wipe_target() {
    command -v wipefs >/dev/null 2>&1 && wipefs -a "$DISK" 2>/dev/null || true
}

if [ "$NETBURN" = "1" ]; then
    [ -n "$URL" ] || FATAL "iiab_deploy_url missing"
    cat > /udhcpc.script <<'EOS'
#!/bin/sh
case "$1" in
    bound|renew)
        ip addr flush dev "$interface" 2>/dev/null || true
        ip addr add "$ip/${subnet:-255.255.255.0}" dev "$interface" 2>/dev/null || true
        [ -n "${router:-}" ] && ip route add default via "$router" dev "$interface" 2>/dev/null || true
        [ -n "${dns:-}" ] && echo "nameserver ${dns%% *}" > /etc/resolv.conf 2>/dev/null || true
        ;;
esac
EOS
    chmod +x /udhcpc.script
    LOG "bringing up the network for netburn"
    for n in /sys/class/net/*; do
        n=$(basename "$n")
        [ "$n" = "lo" ] && continue
        ip link set "$n" up 2>/dev/null || true
        udhcpc -i "$n" -q -n -t 8 -T 3 -s /udhcpc.script >/dev/null 2>&1 || true
    done
    i=0
    while [ "$i" -lt 30 ]; do
        ip addr show 2>/dev/null | awk '/inet / {print $2}' | \
            grep -qvE '^(127\.|169\.254\.)' && break
        sleep 1
        i=$((i + 1))
    done
    if ! ip addr show 2>/dev/null | awk '/inet / {print $2}' | \
        grep -qvE '^(127\.|169\.254\.)'; then
        FATAL "netburn needs a routable IPv4 address, but none was configured"
    fi
    ip addr show 2>/dev/null || true
    wipe_target
    LOG "streaming image from $URL"
    mkdir -p /tmp
    rm -f /tmp/wget.ok /tmp/gunzip.ok
    ( wget -T 30 -O - "$URL"; [ $? -eq 0 ] && : > /tmp/wget.ok ) | \
        ( gzip -dc; [ $? -eq 0 ] && : > /tmp/gunzip.ok ) | \
        dd of="$DISK" bs=1048576
    DD_RC=$?
    if [ "$DD_RC" -ne 0 ] || [ ! -f /tmp/wget.ok ] || [ ! -f /tmp/gunzip.ok ]; then
        FATAL "netburn image write failed (dd=$DD_RC; incomplete download or gzip stream)"
    fi
else
    wipe_target
    LOG "writing embedded image"
    mkdir -p /tmp
    rm -f /tmp/gunzip.ok
    ( gzip -dc /iiab-image.img.gz; [ $? -eq 0 ] && : > /tmp/gunzip.ok ) | \
        dd of="$DISK" bs=1048576
    DD_RC=$?
    if [ "$DD_RC" -ne 0 ] || [ ! -f /tmp/gunzip.ok ]; then
        FATAL "embedded image write failed (dd=$DD_RC; incomplete gzip stream)"
    fi
fi
sync
sleep 1

DEVNAME=$(basename "$DISK")
case "$DISK" in
    *[0-9]) PART_GLOB="${DISK}p*" ;;
    *) PART_GLOB="${DISK}[0-9]*" ;;
esac
for p in $PART_GLOB; do
    [ -b "$p" ] && rm -f "$p" 2>/dev/null || true
done
blockdev --rereadpt "$DISK" 2>/dev/null || true
i=0
while [ "$i" -lt 20 ]; do
    set -- $PART_GLOB
    [ -b "$1" ] && break
    blockdev --rereadpt "$DISK" 2>/dev/null || true
    sleep 1
    i=$((i + 1))
done
if ! ls $PART_GLOB >/dev/null 2>&1; then
    for part in /sys/block/"$DEVNAME"/"$DEVNAME"*; do
        [ -e "$part/dev" ] || continue
        name=$(basename "$part")
        dev=$(cat "$part/dev" 2>/dev/null) || continue
        major=${dev%:*}
        minor=${dev#*:}
        [ -b "/dev/$name" ] || mknod "/dev/$name" b "$major" "$minor" 2>/dev/null || true
    done
fi

mkdir -p /newroot
ROOT_PART=""
for p in $PART_GLOB; do
    [ -b "$p" ] || continue
    fs=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
    case "$fs" in
        ext4|ext3|ext2|xfs|btrfs) ;;
        *) continue ;;
    esac
    if mount -t "$fs" -o ro "$p" /newroot 2>/dev/null; then
        if [ -e /newroot/etc/os-release ] || [ -e /newroot/sbin/init ] || \
           [ -e /newroot/usr/lib/systemd/systemd ]; then
            ROOT_PART=$p
            break
        fi
        umount /newroot 2>/dev/null || true
    fi
done
[ -n "$ROOT_PART" ] || FATAL "could not find the new root filesystem"
mount -o remount,rw /newroot 2>/dev/null || true
LOG "new root: $ROOT_PART"

mkdir -p /newroot/boot/firmware /newroot/boot/efi
BOOT_MOUNT=""
for p in $PART_GLOB; do
    [ "$p" = "$ROOT_PART" ] && continue
    [ -b "$p" ] || continue
    fs=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
    [ "$fs" = "vfat" ] || continue
    # Probe for a Raspberry Pi boot partition first.  Some RPi images also
    # carry an EFI/ directory, so checking the RPi markers first avoids
    # misclassifying them as an x86 ESP.
    if mount -t vfat -o rw "$p" /newroot/boot/firmware 2>/dev/null; then
        if [ -e /newroot/boot/firmware/cmdline.txt ] || \
           [ -e /newroot/boot/firmware/start4.elf ] || \
           [ -e /newroot/boot/firmware/start.elf ]; then
            BOOT_MOUNT=/newroot/boot/firmware
            break
        fi
        umount /newroot/boot/firmware 2>/dev/null || true
    fi
    # Older Raspbian images keep the firmware files directly in /boot.
    if mount -t vfat -o rw "$p" /newroot/boot 2>/dev/null; then
        if [ -e /newroot/boot/cmdline.txt ] || \
           [ -e /newroot/boot/start4.elf ] || \
           [ -e /newroot/boot/start.elf ]; then
            BOOT_MOUNT=/newroot/boot
            break
        fi
        umount /newroot/boot 2>/dev/null || true
    fi
    if mount -t vfat -o rw "$p" /newroot/boot/efi 2>/dev/null; then
        if [ -e /newroot/boot/efi/EFI ]; then
            BOOT_MOUNT=/newroot/boot/efi
            break
        fi
        umount /newroot/boot/efi 2>/dev/null || true
    fi
done
[ -n "$BOOT_MOUNT" ] && LOG "boot partition: $BOOT_MOUNT" || \
    LOG "WARNING: boot partition not mounted"

cp -a /payload/. /newroot/ || FATAL "copying payload failed"
chmod 755 /newroot/usr/local/sbin/iiab-deploy-firstboot 2>/dev/null || true
chmod 600 /newroot/var/lib/iiab-deploy/config.env 2>/dev/null || true

SEED=/newroot/var/lib/cloud/seed/nocloud
mkdir -p "$SEED"
for f in user-data meta-data network-config; do
    if [ -f "/payload/var/lib/iiab-deploy/cloudinit/$f" ]; then
        cp "/payload/var/lib/iiab-deploy/cloudinit/$f" "$SEED/$f"
    fi
done
if [ -n "$BOOT_MOUNT" ]; then
    for f in user-data meta-data network-config; do
        [ -f "/payload/var/lib/iiab-deploy/cloudinit/$f" ] && \
            cp "/payload/var/lib/iiab-deploy/cloudinit/$f" "$BOOT_MOUNT/$f" 2>/dev/null || true
    done
fi
if [ -f /newroot/boot/cmdline.txt ]; then
    for f in user-data meta-data network-config; do
        [ -f "/payload/var/lib/iiab-deploy/cloudinit/$f" ] && \
            cp "/payload/var/lib/iiab-deploy/cloudinit/$f" "/newroot/boot/$f" 2>/dev/null || true
    done
fi

echo "$HOSTNAME" > /newroot/etc/hostname
if [ -f /newroot/etc/hosts ]; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" /newroot/etc/hosts 2>/dev/null || true
    grep -q '^127\.0\.1\.1' /newroot/etc/hosts 2>/dev/null || \
        echo "127.0.1.1 $HOSTNAME" >> /newroot/etc/hosts
fi
: > /newroot/etc/machine-id 2>/dev/null || true
rm -f /newroot/var/lib/dbus/machine-id 2>/dev/null || true

for svc in /lib/systemd/system/ssh.service /usr/lib/systemd/system/ssh.service; do
    if [ -e "/newroot$svc" ]; then
        mkdir -p /newroot/etc/systemd/system/multi-user.target.wants
        ln -sf "$svc" /newroot/etc/systemd/system/multi-user.target.wants/ssh.service
        break
    fi
done
touch /newroot/boot/ssh 2>/dev/null || true
[ -n "$BOOT_MOUNT" ] && touch "$BOOT_MOUNT/ssh" 2>/dev/null || true

CMD=""
if [ -f /newroot/boot/firmware/cmdline.txt ]; then
    CMD=/newroot/boot/firmware/cmdline.txt
elif [ -f /newroot/boot/cmdline.txt ]; then
    CMD=/newroot/boot/cmdline.txt
fi
if [ -n "$CMD" ]; then
    sed -i 's/console=tty1/console=tty0/g' "$CMD" 2>/dev/null || true
    grep -q 'console=tty0' "$CMD" || sed -i 's/$/ console=tty0/' "$CMD"
    grep -q 'console=ttyS0' "$CMD" || sed -i 's/$/ console=ttyS0,115200/' "$CMD"
fi
if [ -f /newroot/etc/default/grub ]; then
    grep -q 'console=tty0' /newroot/etc/default/grub || \
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0,115200"/' \
        /newroot/etc/default/grub 2>/dev/null || true
fi
for f in /newroot/boot/grub/grub.cfg /newroot/boot/efi/EFI/*/grub.cfg; do
    [ -f "$f" ] || continue
    grep -q 'console=tty0' "$f" && continue
    sed -i -E '/^[[:space:]]*linux(e?fi)?[[:space:]]/ s/$/ console=tty0 console=ttyS0,115200/' "$f" 2>/dev/null || true
done

sync

if [ "$REBOOT_AFTER" = "1" ] || [ "$PROFILE" = "rpi" ]; then
    LOG "rebooting into the new system"
    reboot -f
    exit 0
fi

# x86: boot the new kernel directly if possible.
K=$(ls -1t /newroot/boot/vmlinuz-* 2>/dev/null | head -1)
if [ -n "$K" ]; then
    NEWVER=${K##*/vmlinuz-}
    I="/newroot/boot/initrd.img-$NEWVER"
    [ -f "$I" ] || I=$(ls -1t /newroot/boot/initrd.img-* 2>/dev/null | head -1)
else
    I=""
fi
UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)
if [ -n "$K" ] && [ -n "$I" ] && [ -n "$UUID" ] && \
   command -v kexec >/dev/null 2>&1; then
    LOG "kexec into new kernel $K"
    if kexec -l "$K" --initrd="$I" \
        --command-line="root=UUID=$UUID ro quiet console=tty0 console=ttyS0,115200" \
        2>/dev/null; then
        umount "$BOOT_MOUNT" 2>/dev/null || true
        umount /newroot 2>/dev/null || true
        sync
        kexec -e && exit 0
        LOG "new-kernel kexec failed; rebooting"
    fi
fi
LOG "rebooting into the new system"
reboot -f
'''

# ---------------------------------------------------------------------------
# Staging, upload, and post-boot follow-up
# ---------------------------------------------------------------------------


def shell_env(values: dict[str, Any]) -> str:
    lines: list[str] = []
    for key, value in values.items():
        if value is None:
            value = ""
        lines.append(f"{key}={shlex.quote(str(value))}")
    return "\n".join(lines) + "\n"


def pin_values(
    probe: dict[str, Any], pin_ip: bool
) -> tuple[str, str, str, str]:
    if not pin_ip:
        return "", "", "", ""
    ip4 = parse_ip_map(str(probe.get("IP4", "")))
    iface = primary_interface(probe)
    cidr = ip4.get(iface) or (next(iter(ip4.values())) if ip4 else "")
    if not cidr or cidr.startswith("169.254."):
        return "", "", "", ""
    addr = cidr.split("/", 1)[0]
    netmask = prefix_to_netmask(cidr)
    gateway = str(probe.get("GATEWAY4", "")).strip()
    dns = str(probe.get("DNS4", "")).split()
    return addr, netmask, gateway, (dns[0] if dns else "")


def make_tar_gz(
    root: Path, out: Any, *, exclude: tuple[str, ...] = ()
) -> None:
    close = False
    if isinstance(out, (str, Path)):
        fh = open(out, "wb")
        close = True
    else:
        fh = out
    try:
        with tarfile.open(fileobj=fh, mode="w:gz") as tar:
            for path in sorted(root.rglob("*")):
                relative = path.relative_to(root)
                if exclude and relative.parts and relative.parts[0] in exclude:
                    continue
                arc = relative.as_posix()
                info = tar.gettarinfo(str(path), arcname=arc)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                if info.isfile():
                    with open(path, "rb") as src:
                        tar.addfile(info, src)
                else:
                    tar.addfile(info)
    finally:
        if close:
            fh.close()


def make_stage(
    *,
    args: argparse.Namespace,
    probe: dict[str, Any],
    pr: PRInfo,
    image: ImageInfo,
    hostname: str,
    post_user: str,
    disk_dev: str,
    is_root_disk: bool,
    roles: list[str],
    roles_override: bool,
    user_data: str,
    network_config: str,
    meta_data: str,
    profile: str,
    netburn_url: str,
    netburn_image_size: int,
) -> Path:
    if args.keep_payload:
        stage = Path(args.keep_payload).expanduser().resolve()
        if stage.exists() and (not stage.is_dir() or any(stage.iterdir())):
            die(f"--keep-payload directory is not empty: {stage}")
        stage.mkdir(parents=True, exist_ok=True)
    else:
        stage = Path(tempfile.mkdtemp(prefix="iiab-deploy."))

    payload = stage / "payload"
    (payload / "etc/systemd/system/multi-user.target.wants").mkdir(parents=True)
    (payload / "usr/local/sbin").mkdir(parents=True)
    (payload / "var/lib/iiab-deploy/cloudinit").mkdir(parents=True)

    pin_ip, pin_netmask, pin_gateway, pin_dns = pin_values(
        probe, not args.no_pin_ip
    )
    current_hostname = str(probe.get("HOSTNAME", ""))
    arch = str(probe.get("ARCH", ""))
    final_reboot = "1" if (profile == "rpi" or arch not in ("x86_64", "amd64")) else "0"
    roles_text = " ".join(roles)
    roles_auto_text = " ".join(pr.auto_roles)
    env_values: dict[str, Any] = {
        "PR_REPO": pr.repo,
        "PR_NUMBER": pr.number,
        "PR_TITLE": pr.title,
        "PR_URL": pr.url,
        "PR_REF": pr.merge_ref or pr.head_ref,
        "PR_REF_HEAD": pr.head_ref,
        "PR_HEAD_SHA": pr.head_sha,
        "PR_MERGE_REF": pr.merge_ref,
        "PROFILE": profile,
        "ARCH": arch,
        "OLD_HOSTNAME": current_hostname,
        "HOSTNAME": hostname,
        "TARGET_DISK": disk_dev,
        "ROOT_DISK": str(probe.get("ROOT_DISK", "")),
        "IS_ROOT_DISK": "1" if is_root_disk else "0",
        "IMAGE_URL": image.url,
        "IMAGE_SHA256": image.sha256,
        "IMAGE_COMPRESSION": image.compression,
        "IMAGE_LABEL": image.label,
        "IMAGE_RAW_SIZE": netburn_image_size,
        "NETBURN": "1" if netburn_url else "0",
        "NETBURN_URL": netburn_url,
        "ROLES": roles_text,
        "ROLES_AUTO": roles_auto_text,
        "ROLES_OVERRIDE": "1" if roles_override else "0",
        "RUN_MODULE_TESTS": (
            "1" if pr.modules_changed and not args.no_module_tests else "0"
        ),
        "IIAB_INSTALL_ARGS": args.install_args,
        "RPI_UPGRADE": "0" if args.skip_rpi_upgrade else "1",
        "PIN_IP": pin_ip,
        "PIN_NETMASK": pin_netmask,
        "PIN_GATEWAY": pin_gateway,
        "PIN_DNS": pin_dns,
        "FINAL_REBOOT": final_reboot,
        "MEM_MB": str(probe.get("MEM_MB", "")),
        "FREE_MB": str(probe.get("FREE_MB", "")),
        "POST_USER": post_user,
    }
    env_text = shell_env(env_values)
    (stage / "config.env").write_text(env_text, encoding="utf-8")
    (payload / "var/lib/iiab-deploy/config.env").write_text(
        env_text, encoding="utf-8"
    )
    os.chmod(payload / "var/lib/iiab-deploy/config.env", 0o600)

    (payload / "etc/systemd/system/iiab-deploy-firstboot.service").write_text(
        FIRSTBOOT_UNIT, encoding="utf-8"
    )
    firstboot = payload / "usr/local/sbin/iiab-deploy-firstboot"
    firstboot.write_text(FIRSTBOOT_SH, encoding="utf-8")
    os.chmod(firstboot, 0o755)
    link = (
        payload
        / "etc/systemd/system/multi-user.target.wants/"
        "iiab-deploy-firstboot.service"
    )
    link.symlink_to("../iiab-deploy-firstboot.service")

    cloud = payload / "var/lib/iiab-deploy/cloudinit"
    (cloud / "user-data").write_text(user_data, encoding="utf-8")
    (cloud / "network-config").write_text(network_config, encoding="utf-8")
    (cloud / "meta-data").write_text(meta_data, encoding="utf-8")
    os.chmod(cloud / "user-data", 0o600)

    deploy_id = uuid.uuid4().hex
    (payload / "var/lib/iiab-deploy/deploy-id").write_text(
        deploy_id + "\n", encoding="utf-8"
    )
    (stage / "deploy-id").write_text(deploy_id + "\n", encoding="utf-8")

    (payload / "var/lib/iiab-deploy/pr.json").write_text(
        json.dumps(pr.as_dict(), indent=2), encoding="utf-8"
    )

    (stage / "remote-setup.sh").write_text(REMOTE_SETUP_SH, encoding="utf-8")
    (stage / "initramfs-init.sh").write_text(
        INITRAMFS_INIT_SH, encoding="utf-8"
    )
    os.chmod(stage / "remote-setup.sh", 0o755)
    os.chmod(stage / "initramfs-init.sh", 0o755)
    make_tar_gz(payload, stage / "payload.tar.gz")
    return stage


def upload_stage(remote: Remote, stage: Path) -> None:
    log(f"uploading stage to {remote.target}:{REMOTE_STAGE}")
    ssh_run(
        remote,
        f"rm -rf {shlex.quote(REMOTE_STAGE)}; mkdir -p {shlex.quote(REMOTE_STAGE)}",
        sudo=True,
        check=True,
        timeout=120,
    )
    buf = io.BytesIO()
    # payload.tar.gz is what the remote setup extracts; do not ship the
    # uncompressed copy of the same tree as well.
    make_tar_gz(stage, buf, exclude=("payload",))
    tar_cmd = f"tar -xzf - -C {shlex.quote(REMOTE_STAGE)}"
    if not remote.is_root:
        tar_cmd = "sudo -n " + tar_cmd
    p = subprocess.run(
        ssh_base(remote) + [tar_cmd],
        input=buf.getvalue(),
        capture_output=True,
    )
    if p.returncode != 0:
        die(
            "failed to upload stage: " + (p.stderr or b"").decode("utf-8", "replace")
        )
    ssh_run(
        remote,
        f"chmod +x {shlex.quote(REMOTE_STAGE)}/*.sh",
        sudo=True,
        check=True,
        timeout=60,
    )
    log("stage uploaded")


def run_remote_setup(remote: Remote) -> bool:
    script = f"bash {shlex.quote(REMOTE_STAGE + '/remote-setup.sh')}"
    remote_cmd = script if remote.is_root else "sudo -n " + script
    cmd = ssh_base(remote) + [remote_cmd]
    log("preparing the initramfs on the target (this can take a while)")
    p = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert p.stdout is not None
    seen_ready = False
    lines: list[str] = []
    after_ready: list[str] = []
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line)
        if "IIAB_DEPLOY_KEXEC_READY" in line:
            seen_ready = True
        elif seen_ready:
            after_ready.append(line)
    rc = p.wait()
    if not seen_ready:
        if any("FATAL" in line for line in lines):
            die(
                "remote setup failed; the target was not modified.  See the "
                "FATAL message above."
            )
        if rc not in (0, 255):
            die(f"remote setup failed (exit {rc}); the target was not modified")
        # The kexec syscall can kill the SSH connection before its last
        # output reaches us.  The deploy-id check in wait_for_ssh will tell
        # us whether the handoff actually happened.
        warn(
            "did not see the kexec handoff marker, but the connection closed "
            "cleanly; assuming the target is rebooting"
        )
    if any("FATAL" in line or "kexec -e failed" in line for line in after_ready):
        die("kexec -e failed on the target; it is still running the old system")
    return True


def detect_local_ip(target: str) -> str:
    ip = target
    try:
        ip = socket.gethostbyname(target)
    except OSError:
        pass
    if shutil.which("ip"):
        p = run(["ip", "route", "get", ip], check=False)
        m = re.search(r"\bsrc\s+(\S+)", p.stdout or "")
        if m:
            return m.group(1)
    if shutil.which("hostname"):
        p = run(["hostname", "-I"], check=False)
        if (p.stdout or "").split():
            return p.stdout.split()[0]
    return "127.0.0.1"


class ImageServer:
    """A tiny read-only HTTP server for the netburn image."""

    def __init__(self, image_path: Path, bind: str, port: int):
        self.image_path = image_path
        self.size = image_path.stat().st_size
        self.filename = image_path.name
        self._lock = threading.Lock()
        self.bytes_sent = 0
        self.completed = 0
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def do_GET(self) -> None:  # noqa: N802
                path = self.path.split("?", 1)[0]
                if path not in ("/", "/" + outer.filename, "/image.img.gz"):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/gzip")
                self.send_header("Content-Length", str(outer.size))
                self.end_headers()
                sent = 0
                try:
                    with open(outer.image_path, "rb") as fh:
                        while True:
                            chunk = fh.read(1024 * 1024)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            sent += len(chunk)
                            with outer._lock:
                                outer.bytes_sent += len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                if sent == outer.size:
                    with outer._lock:
                        outer.completed += 1

            def log_message(self, fmt: str, *args: Any) -> None:
                log("http: " + (fmt % args))

        self.server: ThreadingHTTPServer
        if ":" in bind:
            class V6Server(ThreadingHTTPServer):
                address_family = socket.AF_INET6

            self.server = V6Server((bind, port), Handler)
        else:
            self.server = ThreadingHTTPServer((bind, port), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(
            target=self.server.serve_forever, daemon=True
        )

    def start(self) -> int:
        self.thread.start()
        return int(self.server.server_address[1])

    def wait_for_transfer(self, stall_minutes: int = NETBURN_STALL_MINUTES) -> bool:
        """Block until the image has been served once.

        The image is streamed by the target's initramfs, which runs *before*
        the new system boots.  Stopping the server while bytes are still
        flowing would leave the target with a half-written disk, so wait for
        the transfer (or for a long stall) before the SSH wait begins.
        """
        total_mb = self.size / (1024 * 1024)
        last_bytes = -1
        last_change = time.time()
        last_log = last_change
        while True:
            with self._lock:
                done = self.completed > 0
                sent = self.bytes_sent
            if done:
                log(f"netburn: image served ({total_mb:.0f} MiB)")
                return True
            now = time.time()
            if sent != last_bytes:
                last_bytes = sent
                last_change = now
                if now - last_log >= 10:
                    last_log = now
                    log(
                        "netburn: served {:.0f}/{:.0f} MiB".format(
                            min(sent / (1024 * 1024), total_mb), total_mb
                        )
                    )
            elif now - last_change > stall_minutes * 60:
                warn(
                    f"netburn: no transfer progress for {stall_minutes} minutes"
                )
                return False
            time.sleep(2)

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def verify_sha256(path: Path, expected: str) -> None:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    actual = h.hexdigest()
    if actual.lower() != expected.lower():
        die(
            f"checksum mismatch for {path.name}: expected {expected}, got {actual}"
        )


def prepare_netburn_image(
    image: ImageInfo, cache_dir: Path
) -> tuple[Path, Path]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    raw = cache_dir / (image.label + ".raw")
    gz = cache_dir / (image.label + ".raw.gz")
    stamp = cache_dir / (image.label + ".raw.sha256")
    trusted = (
        raw.is_file()
        and raw.stat().st_size > 0
        and stamp.is_file()
        and stamp.read_text(encoding="utf-8").strip().lower()
        == image.sha256.lower()
    )
    if not trusted:
        if raw.exists():
            raw.unlink()
        download = cache_dir / (image.label + ".download")
        if download.exists():
            download.unlink()
        log(f"downloading {image.url}")
        run(
            [
                "curl",
                "-fL",
                "--retry",
                "3",
                "--retry-delay",
                "5",
                "--connect-timeout",
                "30",
                "--progress-bar",
                "-o",
                str(download),
                image.url,
            ],
            capture=False,
        )
        verify_sha256(download, image.sha256)
        log("preparing the raw image")
        try:
            if image.compression == "qcow2":
                if not shutil.which("qemu-img"):
                    die(
                        "qemu-img is required to convert the Ubuntu cloud "
                        "image (install qemu-utils)"
                    )
                subprocess.run(
                    [
                        "qemu-img",
                        "convert",
                        "-f",
                        "qcow2",
                        "-O",
                        "raw",
                        str(download),
                        str(raw),
                    ],
                    check=True,
                )
            else:
                with open(raw, "wb") as out:
                    if image.compression == "xz":
                        if not shutil.which("xz"):
                            die(
                                "xz is required to decompress the "
                                "Raspberry Pi image"
                            )
                        subprocess.run(
                            ["xz", "-dc", str(download)], stdout=out, check=True
                        )
                    elif image.compression in ("gzip", "gz"):
                        subprocess.run(
                            ["gzip", "-dc", str(download)], stdout=out, check=True
                        )
                    elif image.compression in ("zstd", "zst"):
                        if not shutil.which("zstd"):
                            die("zstd is required to decompress the image")
                        subprocess.run(
                            ["zstd", "-dc", str(download)], stdout=out, check=True
                        )
                    else:
                        out.close()
                        shutil.move(str(download), str(raw))
        except Exception:
            raw.unlink(missing_ok=True)
            raise
        if download.exists():
            download.unlink()
        stamp.write_text(image.sha256 + "\n", encoding="utf-8")
    else:
        log(f"using cached {raw}")
    if not gz.is_file() or gz.stat().st_mtime < raw.stat().st_mtime:
        if not shutil.which("gzip"):
            die("gzip is required to prepare the netburn image")
        log("compressing image for the netburn server (gzip -1)")
        tmp_gz = gz.with_name(gz.name + ".tmp")
        try:
            with open(tmp_gz, "wb") as out:
                subprocess.run(
                    ["gzip", "-1", "-c", str(raw)], stdout=out, check=True
                )
            tmp_gz.replace(gz)
        except Exception:
            tmp_gz.unlink(missing_ok=True)
            raise
    return raw, gz


def wait_for_ssh(
    candidates: list[Remote], timeout_minutes: int, deploy_id: str
) -> Optional[Remote]:
    deadline = time.time() + timeout_minutes * 60
    check = (
        f"test \"$(cat {shlex.quote(STATE_DIR + '/deploy-id')} 2>/dev/null)\" "
        f"= {shlex.quote(deploy_id)} && echo IIAB_DEPLOY_SSH_OK"
    )
    log(
        "waiting for SSH on the new system: "
        + ", ".join(c.target for c in candidates)
    )
    while time.time() < deadline:
        for cand in candidates:
            p = ssh_run(
                cand,
                check,
                check=False,
                timeout=15,
                insecure=True,
            )
            if p.returncode == 0 and "IIAB_DEPLOY_SSH_OK" in (p.stdout or ""):
                log(f"connected to {cand.target}")
                return cand
        time.sleep(5)
    return None


def follow_firstboot(
    candidates: list[Remote],
    *,
    timeout_minutes: int,
    show: bool,
    deploy_id: str,
) -> tuple[Optional[dict[str, Any]], Optional[Remote]]:
    log_path = f"{LOG_DIR}/firstboot.log"
    result_path = f"{STATE_DIR}/result.json"
    deadline = time.time() + timeout_minutes * 60
    offset = 0
    done = False
    active: Optional[Remote] = candidates[0] if candidates else None

    while active is not None and time.time() < deadline:
        marker = f"IIAB_DEPLOY_MARKER_{os.getpid()}_{int(time.time() * 1000)}"
        script = f"""
DEV={shlex.quote(STATE_DIR + '/deploy-id')}
[ "$(cat "$DEV" 2>/dev/null)" = {shlex.quote(deploy_id)} ] || exit 3
LOG={shlex.quote(log_path)}
if [ -f "$LOG" ]; then tail -c +{offset + 1} "$LOG"; fi
echo
echo {marker}_SIZE
stat -c %s "$LOG" 2>/dev/null || echo 0
echo {marker}_STATUS
[ -f {STATE_DIR}/done ] && echo done
[ -f {STATE_DIR}/failed ] && echo failed
exit 0
"""
        p = ssh_run(
            active, script, check=False, timeout=45, insecure=True
        )
        if p.returncode != 0:
            p = ssh_run(
                active,
                script,
                sudo=True,
                check=False,
                timeout=45,
                insecure=True,
            )
        if p.returncode != 0:
            for cand in candidates:
                if cand.target == active.target:
                    continue
                p = ssh_run(
                    cand, script, check=False, timeout=20, insecure=True
                )
                if p.returncode != 0:
                    p = ssh_run(
                        cand,
                        script,
                        sudo=True,
                        check=False,
                        timeout=20,
                        insecure=True,
                    )
                if p.returncode == 0:
                    log(f"following the install on {cand.target}")
                    active = cand
                    break
        if p.returncode == 0:
            out = p.stdout or ""
            size_marker = marker + "_SIZE"
            status_marker = marker + "_STATUS"
            if size_marker in out and status_marker in out:
                chunk, rest = out.split(size_marker, 1)
                size_text, status_text = rest.split(status_marker, 1)
                if show and chunk:
                    sys.stdout.write(chunk)
                    sys.stdout.flush()
                size_lines = size_text.strip().splitlines()
                try:
                    size = int(size_lines[0]) if size_lines else 0
                except ValueError:
                    size = 0
                if size < offset:
                    offset = 0
                else:
                    offset = size
                status = status_text.strip()
                if "done" in status or "failed" in status:
                    done = True
                    break
        time.sleep(5)

    if not done:
        warn(
            "timed out waiting for the first-boot result; the install may still "
            "be running on tty0"
        )

    raw = ""
    for cand in candidates:
        for use_sudo in (False, True):
            p = ssh_run(
                cand,
                (
                    f"test \"$(cat {shlex.quote(STATE_DIR + '/deploy-id')} "
                    f"2>/dev/null)\" = {shlex.quote(deploy_id)} && "
                    f"cat {shlex.quote(result_path)} 2>/dev/null"
                ),
                sudo=use_sudo,
                check=False,
                timeout=30,
                insecure=True,
            )
            if p.returncode == 0 and (p.stdout or "").strip().startswith("{"):
                raw = (p.stdout or "").strip()
                active = cand
                break
        if raw:
            break
    if not raw:
        return None, active
    try:
        return json.loads(raw), active
    except json.JSONDecodeError:
        warn("could not parse the remote result.json")
        return None, active


def print_result(result: Optional[dict[str, Any]], remote: Remote) -> None:
    print()
    print("=" * 70)
    if result:
        print(f"IIAB deploy finished: {result.get('status', 'unknown')}")
        print(f"  PR:           {result.get('pr_url', '')}")
        print(f"  Profile:      {result.get('profile', '')}")
        print(f"  Hostname:     {result.get('hostname', '')}")
        print(f"  Roles:        {' '.join(result.get('roles') or []) or '<none>'}")
        print(f"  iiab-install: {result.get('install_rc')}")
        print(f"  roles:        {result.get('roles_rc')}")
        print(f"  modules:      {result.get('module_tests_rc')}")
        print(f"  Log:          {result.get('log', '')}")
        if result.get("state_diff"):
            print(f"  State diff:   {result['state_diff']}")
    else:
        print("No result.json was found; the install may still be running.")
    print("=" * 70)
    print(f"Follow live:  ssh {remote.target} 'sudo tail -n +1 -F {LOG_DIR}/firstboot.log'")
    print(f"Attach:       ssh -t {remote.target} 'sudo tmux attach -t iiab-deploy'")
    print(f"              (or: ssh -t {remote.target} 'sudo screen -r iiab-deploy')")
    print(f"Journal:      ssh {remote.target} 'sudo journalctl -u iiab-deploy-firstboot -b --no-pager'")
    print(f"Old host key: ssh-keygen -R {remote.host}")
    print()


def format_bytes(value: Any) -> str:
    try:
        n = float(value)
    except (TypeError, ValueError):
        return str(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def print_plan(
    *,
    remote: Remote,
    probe: dict[str, Any],
    pr: PRInfo,
    image: ImageInfo,
    hostname: str,
    disk_dev: str,
    disk_info: dict[str, Any],
    is_root_disk: bool,
    profile: str,
    roles: list[str],
    roles_override: bool,
    network_notes: list[str],
    netburn_url: str,
    post_user: str,
) -> None:
    print()
    print("=" * 70)
    print("IIAB reimage plan")
    print("=" * 70)
    print(f"Target:        {remote.target}")
    print(f"Current host:  {probe.get('HOSTNAME', '?')} ({probe.get('OS_PRETTY', '?')})")
    print(f"New hostname:  {hostname}")
    print(f"Profile:       {profile}  ({probe.get('MODEL') or probe.get('ARCH', '?')})")
    print(f"Architecture:  {probe.get('ARCH', '?')}")
    print(f"Target disk:   {disk_dev}  {format_bytes(disk_info.get('SIZE', 0))}  "
          f"{disk_info.get('MODEL', '')}  "
          f"{'(contains the running root)' if is_root_disk else ''}")
    print(f"Image:         {image.label}")
    print(f"               {image.url}")
    print(f"Checksum:      {image.sha256}")
    print(f"Target RAM:    {probe.get('MEM_MB', '?')} MiB; "
          f"/var/tmp free: {probe.get('FREE_MB', '?')} MiB")
    print(f"PR:            {pr.url}  [{pr.state}{', draft' if pr.draft else ''}]")
    print(f"PR ref:        {pr.merge_ref or pr.head_ref}")
    print(f"Changed roles: {' '.join(pr.auto_roles) or '<none>'}")
    print(f"Roles to run:  {' '.join(roles) or '<none>'}"
          f"{' (override)' if roles_override else ' (auto)'}"
          f"  [0-init runs first via runroles-base.yml]")
    print(f"Post-boot SSH: {post_user}@{remote.host}")
    print("Console:       tty0 and ttyS0,115200")
    if not is_root_disk:
        print(
            "WARNING:      the selected disk is not the disk that holds the "
            "running root.\n"
            "              After the write, the firmware may still boot the "
            "old disk; fix the boot order/entry."
        )
    if netburn_url:
        print(f"Netburn:       {netburn_url}")
    for note in network_notes:
        print(f"Network:       {note}")
    print("=" * 70)
    print("This will overwrite the target disk.  There is no undo.")
    print("=" * 70)

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

__version__ = "0.1.0"


def valid_hostname(name: str) -> bool:
    if not name or len(name) > 253:
        return False
    label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    return bool(re.fullmatch(rf"{label}(?:\.{label})*", name))


def check_kexec_safety(probe: dict[str, Any]) -> None:
    secure = str(probe.get("SECUREBOOT", "")).lower()
    if "enabled" in secure:
        die(
            "Secure Boot is enabled on the target.  kexec of the prepared "
            "kernel/initramfs would be blocked.  Disable Secure Boot first."
        )
    lockdown = str(probe.get("LOCKDOWN", ""))
    if "[integrity]" in lockdown or "[confidentiality]" in lockdown:
        die(
            "kernel lockdown is active ({}); kexec is restricted.  "
            "Disable lockdown/Secure Boot first.".format(lockdown)
        )
    if str(probe.get("KEXEC_DISABLED", "0")).strip() == "1":
        die("kernel.kexec_load_disabled=1 on the target; kexec is disabled.")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    epilog = textwrap.dedent(
        """\
        Examples:
          %(prog)s 192.168.1.219 4543
          %(prog)s xk@box 4543 --yes --hostname box --disk /dev/nvme0n1
          %(prog)s 192.168.1.219 https://github.com/iiab/iiab/pull/4543 \\
              --roles 0-init,7-edu-apps,network,zimantic --netburn

        The target is reimaged with Raspberry Pi OS Lite arm64 when it is a
        Raspberry Pi, otherwise with the Ubuntu 26.04 cloud image.  Both use
        IIAB's tiny profile.  The PR's changed roles are detected from its
        changed files; --roles overrides that list.

        --netburn (aliases: --pxe, --ipxe) serves the image from this host over
        plain HTTP and is the safest option for small disks, low-RAM systems,
        and Raspberry Pis.
        """
    )
    p = argparse.ArgumentParser(
        description=(
            "Reimage an SSH-accessible machine and install IIAB from a PR."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=epilog,
    )
    p.add_argument("address", help="[user@]host[:port] of the target")
    p.add_argument(
        "pr", help="PR number (4543) or full github.com/.../pull/4543 URL"
    )
    p.add_argument(
        "--yes", action="store_true", help="do not ask for hostname confirmation"
    )
    p.add_argument(
        "--hostname", help="hostname for the new system (default: current)"
    )
    p.add_argument(
        "--expect-hostname",
        help="abort unless the target's current hostname matches this",
    )
    p.add_argument(
        "--disk",
        help="whole target disk (default: the only whole disk)",
    )
    p.add_argument(
        "--profile",
        choices=("auto", "rpi", "ubuntu"),
        default="auto",
        help="image profile (default: auto-detect Raspberry Pi)",
    )
    p.add_argument(
        "--roles",
        help="comma/space-separated roles to run after install (default: auto-detect from the PR)",
    )
    p.add_argument(
        "--cloudinit-userdata",
        default=DEFAULT_CLOUDINIT_USERDATA,
        help=f"user-data file (default: {DEFAULT_CLOUDINIT_USERDATA})",
    )
    p.add_argument(
        "--cloudinit-networkconfig",
        default=DEFAULT_CLOUDINIT_NETWORKCONFIG,
        help=f"network-config file (default: {DEFAULT_CLOUDINIT_NETWORKCONFIG})",
    )
    p.add_argument(
        "--post-user",
        help="user created by cloud-init for post-boot SSH (default: from user-data)",
    )
    p.add_argument("--identity", "-i", help="SSH private key")
    p.add_argument("--port", type=int, help="SSH port (or use host:port)")
    p.add_argument(
        "--netburn",
        "--pxe",
        "--ipxe",
        action="store_true",
        dest="netburn",
        help="serve the image over HTTP from this host instead of embedding it",
    )
    p.add_argument(
        "--http-address",
        default="0.0.0.0",
        help="address for the netburn HTTP server to bind (default: 0.0.0.0)",
    )
    p.add_argument(
        "--http-port",
        type=int,
        default=0,
        help="port for the netburn HTTP server (default: choose a free port)",
    )
    p.add_argument(
        "--cache-dir",
        default=CACHE_DIR,
        help=f"netburn image cache (default: {CACHE_DIR})",
    )
    p.add_argument(
        "--install-args",
        default="--risky",
        help="arguments for iiab-install (default: --risky; use '' for strict)",
    )
    p.add_argument(
        "--skip-rpi-upgrade",
        action="store_true",
        help="skip apt full-upgrade on the new Raspberry Pi OS",
    )
    p.add_argument(
        "--ip",
        metavar="CIDR",
        help="override the pinned IPv4 address, e.g. 192.168.1.50/24",
    )
    p.add_argument(
        "--gateway",
        help="override the pinned IPv4 default gateway",
    )
    p.add_argument(
        "--dns",
        help="override the pinned DNS servers (comma/space separated)",
    )
    p.add_argument(
        "--no-pin-ip",
        action="store_true",
        help="leave the new system on DHCP instead of pinning the current IPv4",
    )
    p.add_argument(
        "--no-pin-ipv6",
        action="store_true",
        help="do not pin the current global IPv6 address",
    )
    p.add_argument(
        "--no-module-tests",
        action="store_true",
        help="do not run modules/tests/get_curl.yml when modules/ changed",
    )
    p.add_argument(
        "--no-follow",
        action="store_true",
        help="wait for the result without tailing the first-boot log",
    )
    p.add_argument(
        "--boot-timeout",
        type=int,
        default=30,
        help="minutes to wait for SSH on the new system (default: 30)",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=360,
        help="minutes to wait for the first-boot result (default: 360)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="probe, resolve, and validate everything, but do not touch the target",
    )
    p.add_argument(
        "--keep-payload",
        metavar="DIR",
        help="write the generated stage to DIR and keep it",
    )
    p.add_argument("--debug", action="store_true", help="show tracebacks")
    p.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args: Optional[argparse.Namespace] = None
    stage: Optional[Path] = None
    server: Optional[ImageServer] = None
    args = parse_args(argv)
    try:
        remote = parse_address(args.address)
        if args.identity:
            remote.identity = args.identity
        if args.port:
            remote.port = args.port

        log(f"probing {remote.target}")
        probe = probe_remote(remote)
        check_kexec_safety(probe)
        if args.no_pin_ip and (args.ip or args.gateway or args.dns):
            warn("--no-pin-ip is set; ignoring --ip/--gateway/--dns")
        elif args.ip or args.gateway or args.dns:
            probe = apply_network_overrides(
                probe,
                ip=args.ip,
                gateway=args.gateway,
                dns=args.dns,
            )

        arch = str(probe.get("ARCH", ""))
        os_id = str(probe.get("OS_ID", "")).lower()
        if os_id and os_id not in (
            "ubuntu",
            "debian",
            "raspbian",
            "linuxmint",
            "pop",
            "neon",
        ):
            die(
                f"unsupported target OS: {probe.get('OS_PRETTY') or os_id}.  "
                "This tool expects an apt-based Debian/Ubuntu derivative."
            )
        profile = args.profile
        if profile == "auto":
            profile = "rpi" if is_raspberry_pi(probe) else "ubuntu"
        if profile == "rpi":
            if arch == "armv7l":
                capability = rpi_arm64_capability(probe)
                if capability is True:
                    warn(
                        "the target is running a 32-bit armv7l kernel, but "
                        "its hardware identifies as arm64-capable; continuing"
                    )
                elif capability is False:
                    die(
                        "the target reports armv7l and its hardware is not "
                        "arm64-capable"
                    )
                else:
                    die(
                        "the target reports armv7l; cannot verify that its "
                        "hardware is arm64-capable"
                    )
            if arch not in ("aarch64", "arm64", "armv6l", "armv7l"):
                die(f"Raspberry Pi profile does not support architecture {arch}")
        else:
            if arch not in ("x86_64", "amd64", "aarch64", "arm64"):
                die(f"Ubuntu 26.04 cloud images do not support architecture {arch}")

        disk_dev, disk_info, is_root_disk = choose_disk(probe, args.disk)

        repo, pr_number = parse_pr_arg(args.pr)
        log(f"resolving {repo}#{pr_number}")
        pr = resolve_pr(repo, pr_number)
        log(
            f"PR: {pr.title} [{pr.state}{', draft' if pr.draft else ''}]"
        )
        log(f"changed roles: {' '.join(pr.auto_roles) or '<none>'}")
        if pr.modules_changed:
            log("PR also changes modules/; get_curl tests will run on first boot")
        if not (pr.merge_ref or pr.head_ref):
            die("could not determine a ref to fetch for the PR")

        log("resolving the image")
        image = choose_image(profile, arch)
        log(f"image: {image.label}")

        current_hostname = str(probe.get("HOSTNAME", "")).strip()
        if args.expect_hostname and current_hostname != args.expect_hostname:
            die(
                f"target hostname is {current_hostname!r}, expected "
                f"{args.expect_hostname!r}; refusing to overwrite it"
            )
        hostname = (args.hostname or current_hostname or "box").strip()
        if not valid_hostname(hostname):
            die(f"invalid hostname: {hostname!r}")

        user_data_path = Path(args.cloudinit_userdata).expanduser()
        network_path = Path(args.cloudinit_networkconfig).expanduser()
        if not user_data_path.is_file():
            die(f"missing {user_data_path}")
        if not network_path.is_file():
            die(f"missing {network_path}")
        user_data = user_data_path.read_text(encoding="utf-8")
        network_config = network_path.read_text(encoding="utf-8")
        post_user = args.post_user or parse_post_user(user_data, profile)
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_.-]*$", post_user):
            die(f"invalid post-boot user name: {post_user!r}")

        user_data = rewrite_user_data(user_data, hostname)
        network_config, network_notes = rewrite_network_config(
            network_config,
            probe,
            pin_ip=not args.no_pin_ip,
            pin_ipv6=not args.no_pin_ipv6,
        )
        meta_data = (
            f"instance-id: iiab-deploy-{hostname}-{int(time.time())}\n"
            f"local-hostname: {hostname}\n"
        )

        if args.roles is not None:
            raw_roles = [r for r in re.split(r"[\s,]+", args.roles) if r]
            roles_override = True
        else:
            raw_roles = list(pr.auto_roles)
            roles_override = False
        roles: list[str] = []
        seen: set[str] = set()
        for role in raw_roles:
            if not re.match(r"^[A-Za-z0-9_.-]+$", role) or ".." in role:
                die(f"invalid role name: {role!r}")
            if role not in seen:
                seen.add(role)
                roles.append(role)

        pin_ip, _, _, _ = pin_values(probe, not args.no_pin_ip)

        netburn_url = ""
        netburn_image_size = 0

        print_plan(
            remote=remote,
            probe=probe,
            pr=pr,
            image=image,
            hostname=hostname,
            disk_dev=disk_dev,
            disk_info=disk_info,
            is_root_disk=is_root_disk,
            profile=profile,
            roles=roles,
            roles_override=roles_override,
            network_notes=network_notes,
            netburn_url=(
                "(not downloaded in --dry-run; would be served over HTTP)"
                if args.netburn and args.dry_run
                else "(will be served over HTTP after confirmation)"
                if args.netburn
                else ""
            ),
            post_user=post_user,
        )

        if not args.yes and not args.dry_run:
            if not sys.stdin.isatty():
                die("refusing to overwrite without --yes (stdin is not a TTY)")
            answer = input(
                f"Type the current hostname ({current_hostname}) to confirm: "
            )
            if answer.strip() != current_hostname:
                die("confirmation did not match; aborted")

        if args.dry_run:
            log("dry run: building the payload locally for validation")
            stage = make_stage(
                args=args,
                probe=probe,
                pr=pr,
                image=image,
                hostname=hostname,
                post_user=post_user,
                disk_dev=disk_dev,
                is_root_disk=is_root_disk,
                roles=roles,
                roles_override=roles_override,
                user_data=user_data,
                network_config=network_config,
                meta_data=meta_data,
                profile=profile,
                netburn_url="",
                netburn_image_size=0,
            )
            log(f"stage: {stage}")
            if args.keep_payload:
                log("kept the stage")
            else:
                shutil.rmtree(stage, ignore_errors=True)
                stage = None
            log("dry run: no changes made to the target")
            return 0

        if args.netburn:
            raw, gz = prepare_netburn_image(
                image, Path(args.cache_dir).expanduser()
            )
            netburn_image_size = raw.stat().st_size
            bind = args.http_address
            host = bind
            if bind in ("0.0.0.0", "::", ""):
                host = detect_local_ip(remote.host)
            server = ImageServer(gz, bind, args.http_port)
            port = server.start()
            url_host = f"[{host}]" if ":" in host else host
            netburn_url = f"http://{url_host}:{port}/{gz.name}"
            log(f"netburn server: {netburn_url}")

        stage = make_stage(
            args=args,
            probe=probe,
            pr=pr,
            image=image,
            hostname=hostname,
            post_user=post_user,
            disk_dev=disk_dev,
            is_root_disk=is_root_disk,
            roles=roles,
            roles_override=roles_override,
            user_data=user_data,
            network_config=network_config,
            meta_data=meta_data,
            profile=profile,
            netburn_url=netburn_url,
            netburn_image_size=netburn_image_size,
        )
        log(f"stage: {stage}")
        deploy_id = (stage / "deploy-id").read_text(encoding="utf-8").strip()
        if not deploy_id:
            die("internal error: empty deploy id")

        upload_stage(remote, stage)
        run_remote_setup(remote)
        log("the target is now writing the new image; SSH will drop")
        if args.netburn and server is not None:
            log("waiting for the netburn image transfer to finish")
            if not server.wait_for_transfer():
                warn(
                    "the target did not finish downloading the image; it may "
                    "have lost the network or already rebooted"
                )

        hosts: list[str] = []
        for candidate in (
            pin_ip,
            remote.host,
            f"{hostname}.local",
            hostname,
            "10.10.10.10",
        ):
            if candidate and candidate not in hosts:
                hosts.append(candidate)
        # The reimaged system uses the image's default SSH port, so also try
        # 22 when the old system was reached on a custom port.
        old_port = remote.port or DEFAULT_SSH_PORT
        ports = [old_port]
        if old_port != DEFAULT_SSH_PORT:
            ports.append(DEFAULT_SSH_PORT)
        candidates = [
            Remote(
                host=h,
                user=post_user,
                port=p,
                identity=remote.identity,
            )
            for h in hosts
            for p in ports
        ]

        live = wait_for_ssh(candidates, args.boot_timeout, deploy_id)
        if not live:
            warn(
                "SSH did not come back.  The machine may be on tty0, on a "
                "different DHCP address, or still writing the image."
            )
            print(
                "Check the physical/serial console (tty0), or try:\n"
                f"  ssh {post_user}@{hostname}.local\n"
                f"  ssh {post_user}@{hostname}\n"
                "The install may still be running in iiab-deploy-firstboot.service."
            )
            return 2

        result, active = follow_firstboot(
            candidates,
            timeout_minutes=args.timeout,
            show=not args.no_follow,
            deploy_id=deploy_id,
        )
        print_result(result, active or live)
        if not result:
            return 2
        if result.get("status") != "success":
            return 1
        return 0
    except SystemExit:
        raise
    except KeyboardInterrupt:
        die("interrupted")
    except DeployError as e:
        die(str(e))
    except Exception as e:  # noqa: BLE001
        if getattr(args, "debug", False):
            raise
        die(f"unexpected error: {e}")
    finally:
        if server is not None:
            try:
                server.stop()
            except Exception:
                pass
        if stage is not None and not getattr(args, "keep_payload", None):
            shutil.rmtree(stage, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
