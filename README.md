# fedora-coreos-proxmox

Fedora CoreOS (FCOS) VM template for Proxmox VE, configured from the Proxmox **Cloud-Init** tab, with **rootless Podman** and a hardened base system.

Fork of the [Geco-IT project](https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox), migrated from Docker to Podman. Requires FCOS 43.20260301 or later (Ignition 2.26+); `vmsetup.sh` downloads the latest stable release.

---

## Features

- **Cloud-Init** from Proxmox: user, password, SSH keys, hostname, DNS, IPv4 (static or DHCP) and IPv6 (static, SLAAC or DHCPv6) — changes are applied at the next boot.
- **Rootless Podman** under a dedicated, locked `podman` account (no sudo); `docker.service`/`docker.socket` masked.
- **Safe hook**: once a VM is installed, the Proxmox hook never regenerates its Ignition config, so a template change can never prevent an existing VM from starting.
- **Hardening**: SSH (key only, port `59500`, modern algorithms), sysctl, module blacklist, audit rules, no LLMNR/mDNS, unused services disabled.
- **Verified downloads**: FCOS image (SHA-256 of the stable stream), `butane` and `yq` (pinned versions, SHA-256 checked before installation).
- **Automatic updates**: Zincati (OS, weekly window), `podman auto-update` (container images).
- **QA workflow**: static checks, `butane --strict`, end-to-end test on a throw-away clone.

## Requirements

- Proxmox VE with a storage that accepts **Snippets** (e.g. `local`) — tested on Proxmox VE 9.2.
- Internet access from the node (FCOS image, `butane`, `yq`) and from the VMs on first boot (packages).
- `python3` on the node (installed with Proxmox VE).

---

## Create the template

On the Proxmox node:

```bash
git clone https://github.com/IOTech17/fedora-coreos-proxmox
cd fedora-coreos-proxmox
./vmsetup.sh
```

The script asks for the **template VMID** (default: next free VMID), the **storage** of the VM disk and the **network bridge**, and detects the snippets storage. It then:

1. copies `hook-fcos.sh`, `fcos-base-tmplt.yaml` and `scripts/` (as `fcos-base-tmplt.d/`) to the snippets storage;
2. downloads the **latest stable** FCOS `qemu` image and checks its SHA-256;
3. creates the VM (`virtio0` disk, cloud-init drive, resources below) and converts it to a template.

Options at the top of `vmsetup.sh`:

```bash
VMDISK_OPTIONS=",discard=on,iothread=1"   # VM disk options
TEMPLATE_CORES=8                          # vCPUs, memory (MB) and start with the node:
TEMPLATE_MEMORY=8192                      #   inherited by the clones, adjustable per clone
TEMPLATE_ONBOOT=1
VERSION=                                  # empty = latest stable, or pin a release (e.g. 44.20260829.3.1)
```

## Create a VM

1. **Clone** the template, adjust CPU/RAM/disk.
2. In the **Cloud-Init** tab, set a user, an **SSH public key** (required to log in, password login is disabled), and the network (static IP or DHCP).
3. **Start** the VM.

| Start | What happens |
|-------|--------------|
| First start | The hook generates the Ignition config and starts the VM again with it (the first start attempt is reported as failed: expected). |
| Boot 1 | Ignition configures the system; Docker packages are replaced (`qemu-guest-agent`, `podman-compose`, `podman-docker`); automatic reboot. |
| Boot 2 | Ready: SSH on port `59500`, `podman` account and its socket active. |

> The network must work on boot 1 (package installation).

```bash
ssh -p 59500 <user>@<vm-ip>
```

## Cloud-Init settings

Applied by `fcos-cloudinit` at every boot when the Cloud-Init configuration changes:

| Setting | Notes |
|---------|-------|
| User | Created if missing (default `admin`), groups `sudo adm wheel systemd-journal` |
| Password | Hash written to `/etc/shadow` |
| SSH keys | `~/.ssh/authorized_keys.d/ignition` |
| Hostname | Also written to `/etc/hosts` (`<ip> <name>.local <name>`) |
| IPv4 | Static or DHCP |
| IPv6 | Static, SLAAC (`auto`) or DHCPv6; disabled on the interface when not set |
| DNS servers / domain | Static: used; DHCP: added to those of the lease |

The network settings are written as one NetworkManager profile per interface (`/etc/NetworkManager/system-connections/net<N>.nmconnection`), rewritten only when the Cloud-Init configuration changes them: any change (static ↔ DHCP, DNS, IPv6) is applied at the next boot.

---

## Accounts

| Account | Role |
|---------|------|
| Cloud-Init user | Administration. Member of `sudo`: **sudo without password** (FCOS default). Only members of `wheel` may log in over SSH. |
| `podman` | Runs the containers (rootless). Locked, no password, no sudo, lingering, process limit `65536`. |
| `core` | FCOS default account, locked, unused. |

## Podman

Everything runs **rootless** under `podman`; the root Podman socket is disabled.

- API socket (Docker-compatible): `/run/user/<uid of podman>/podman/podman.sock`
- User services: `podman.socket`, `podman-restart.service` (restarts containers with a restart policy after a reboot), `podman-auto-update.timer`
- `docker` and `podman-compose` commands are available (`podman-docker`, `podman-compose`)

Run commands as `podman` from the admin account:

```bash
U=$(id -u podman)
AS="sudo -u podman XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus"
cd /tmp   # the current directory must be readable by podman
$AS podman ps
$AS systemctl --user status podman.socket
```

### Management container with Quadlet (example: Dockhand)

Quadlet runs a container as a systemd service (restart, `podman auto-update`, logs). Create `/var/home/podman/.config/containers/systemd/dockhand.container` with `sudo` (the directory belongs to `podman`):

```ini
[Unit]
Description=Dockhand
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/fnsys/dockhand:latest
ContainerName=dockhand
PublishPort=3000:3000
Volume=dockhand_data:/app/data
# Podman API as the Docker socket
Volume=%t/podman/podman.sock:/var/run/docker.sock:z
# Required for the socket access (SELinux); no --privileged
SecurityLabelDisable=true
Label=io.containers.autoupdate=registry
HealthCmd=curl -f http://localhost:3000/
HealthInterval=30s

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

```bash
sudo chown podman:podman /var/home/podman/.config/containers/systemd/dockhand.container
$AS systemctl --user daemon-reload
$AS systemctl --user start dockhand.service
```

> A tool with access to the Podman socket controls all the containers: **enable its authentication** (Dockhand: *Settings → Authentication*) and do not publish it without an authentication layer in front (e.g. Cloudflare Access).

Containers created by such a tool restart after a reboot through `podman-restart.service`; only the tool itself needs a Quadlet unit.

---

## Hardening

| Area | Settings |
|------|----------|
| SSH | Key only, port `59500`, `AllowGroups wheel`, `MaxAuthTries 3`, `MaxSessions 2`, dead sessions closed (`ClientAliveInterval 300`), no forwarding/X11/compression, banner. Algorithms: ML-KEM/sntrup/curve25519 key exchange, ChaCha20/AES-GCM ciphers, ETM MACs. |
| Kernel (sysctl) | Network hardening (redirects, source routing, martians, syncookies), ASLR, restricted dmesg/ptrace/BPF. Default ephemeral port range with the SSH port reserved; default `fs.file-max`. |
| Modules | Blacklisted: `cramfs hfs hfsplus jffs2 squashfs udf firewire-core usb-storage tipc rds sctp dccp` |
| Audit | `auditd` watches `sudoers`, accounts (`passwd`, `shadow`, `group`, `subuid`…), SSH config, systemd units, sysctl/modprobe, `/usr/local/bin`, Podman configuration and Quadlets. |
| Services | LLMNR/mDNS off, root Podman socket off, NFS client and `systemd-homed` off, core dumps disabled. |
| Passwords | `/etc/login.defs`: `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`, `PASS_MIN_LEN 12`, `UMASK 027`, YESCRYPT. |

Lynis 3.1.7 hardening index: **83**. Remaining findings, accepted by design:

| Finding | Reason |
|---------|--------|
| `KRNL-6000` `kernel.modules_disabled` | Would block kernel modules needed by Podman |
| `AUTH-9216/9228` grpck/pwck | FCOS keeps system accounts in `/usr/lib/passwd` and `/usr/lib/group`: do **not** "fix" |
| `AUTH-9229/9230` hashing rounds | YESCRYPT (FCOS default) has no rounds setting |
| `AUTH-9284` locked accounts | `core` and `podman` are locked on purpose |
| `FILE-6310` `/home` symlink | FCOS uses `/var/home` |
| `PKGS-7420` automatic updates | Handled by Zincati (not detected by Lynis) |
| `FINT-4350`, `HRDN-7230` | File integrity / malware scanner: `/usr` is read-only and verified by ostree |
| `BOOT-5264` service sandboxing | Distribution units, not modified |
| `LOGG-2154`, `ACCT-9622/9626` | Remote logging and process accounting: optional |

The template has no host firewall: filter at the network level.

---

## Maintenance

**Existing VMs are not updated by template changes**: Ignition runs only on the first boot. Apply a change to an existing VM by hand (the scripts are in `/usr/local/bin`, the units in `/etc/systemd/system`).

**Clone a configured VM**: run `sysprep`, then convert the VM to a template or clone it. The VM is powered off at the end; on the next boot the Cloud-Init configuration is applied again and the `podman` account is recreated.

```bash
sudo fcos-cloudinit sysprep   # runs as fcos-sysprep.service: follow with journalctl -u fcos-sysprep -f
```

It removes: SSH host keys, local users and their containers, lingering, per-user systemd settings, network profiles, `/etc/hosts` entries, machine-id and logs.

**Hook logs** (Proxmox node): `journalctl -t hook-fcos` for the first start of a VM (Ignition passed to QEMU, VM started again).

**Update `butane` or `yq`**: change `*_VERSION` and `*_SHA256` in `hook-fcos.sh` (both tools) and in `scripts/fcos-cloudinit.sh` (`yq`), then run the QA. `BUTANE_SPEC_VERSION` (`1.7.0`, Ignition 3.6.0) needs Ignition 2.26 or later in the FCOS image.

---

## Quality assurance

Every change to `hook-fcos.sh`, `fcos-base-tmplt.yaml`, `scripts/` or `vmsetup.sh` must pass the QA **before** being copied to the snippets of a node:

```bash
cp qa/qa.env.example qa/qa.env   # node, template, reference VM, free test VMID and IP (not versioned)
qa/qa.sh all                     # static + validate + e2e
qa/qa.sh e2e --dhcp              # same end-to-end test with a first boot in DHCP
qa/qa.sh promote                 # after "QA OK": backup, copy to the production snippets, validate again
```

| Stage | Where | Checks |
|-------|-------|--------|
| `static` | local, CI | `bash -n` and `shellcheck` (no warning) on all scripts |
| `validate` | node | `butane --strict` with a test header and with the real header of every VM using the hook |
| `e2e` | node | Clone of the template with the Cloud-Init of a reference VM (other IP): both boots and ~50 checks (`qa/vm-checks.sh`); restart with a **broken fragment** and the network switched static ↔ DHCP (the VM must start and apply it); switch back and add a static IPv6; `sysprep` and restart; clone destroyed (`--keep` to keep it) |
| `promote` | node | Timestamped backup, copy, validation; previous files restored on failure; only the last `KEEP_BACKUPS` (default 3) backups are kept |

GitHub Actions (`.github/workflows/qa.yml`) runs `static` and `butane --strict` on every push.

## Files

| File | Role |
|------|------|
| `vmsetup.sh` | Creates the template (run once on the node) |
| `hook-fcos.sh` | Proxmox hookscript: generates the Ignition config on the first start of a VM |
| `fcos-base-tmplt.yaml` | Butane fragment appended by the hook (files, systemd units) — not a standalone Butane file |
| `scripts/` | Scripts installed in `/usr/local/bin` of the VMs, included by the fragment (`local:`); copied next to it as `fcos-base-tmplt.d/` in the snippets storage |
| `qa/` | QA workflow |

## Credits

Originally based on the [Geco-IT fedora-coreos-proxmox](https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox) project.
