# fedora-coreos-proxmox

Fedora CoreOS template for Proxmox with cloud-init support.

This is a fork of the [Geco-IT repository](https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox), significantly updated for FCOS 43+ and migrated from Docker to Podman.

---

## What's included

The `fcos-base-tmplt.yaml` ignition template provides a production-ready FCOS base configuration:

- **Partition resize** — root partition automatically expands to fill available disk space
- **Package setup** — removes `docker-cli` and `moby-engine` (bundled with FCOS), installs `qemu-guest-agent`, `podman-compose`, and `podman-docker`
- **Podman** — replaces Docker as the container runtime
  - System-level `podman.socket` enabled
  - Rootless `podman.socket` automatically configured for the cloud-init user
  - `docker.service` and `docker.socket` masked
- **qemu-guest-agent** — installed and running on first boot
- **fcos-cloudinit** — cloud-init wrapper script applied at every boot
- **update-hosts** — updates `/etc/hosts` with current IP and hostname at every boot
- **harden-login-defs** — patches `/etc/login.defs` with stricter password policy on first boot
- **SSH hardening** — custom port `59500`, X11 disabled, restricted options
- **Kernel hardening** — sysctl tuning, driver/protocol blacklisting
- **fstrim** — periodic TRIM enabled for SSD storage
- **Zincati** — automatic updates configured with a weekly maintenance window
- **Lynis score** — 81/100

---

## Requirements

- Proxmox VE 7+
- A storage with snippet support (e.g. `local`)
- Internet access from the Proxmox node (to download FCOS image and packages)

---

## Configuration

Edit `vmsetup.sh` before running:

```bash
TEMPLATE_VMID="10000"                        # Proxmox VMID for the template
TEMPLATE_VMSTORAGE="local-lvm"               # Storage for the VM disk
SNIPPET_STORAGE="local"                      # Storage for hook script and ignition file
VMDISK_OPTIONS=",discard=on,iothread=1"      # VM disk options
VERSION=43.20251024.3.0                      # FCOS stable version to deploy
```

To find the latest stable FCOS version, check:
https://builds.coreos.fedoraproject.org/browser?stream=stable&arch=x86_64

---

## Create the template

Run on your Proxmox node:

```bash
git clone https://github.com/IOTech17/fedora-coreos-proxmox
cd fedora-coreos-proxmox
./vmsetup.sh
```

This will:
1. Copy `hook-fcos.sh` and `fcos-base-tmplt.yaml` to the snippets storage
2. Download the FCOS QCOW2 image
3. Create and configure the Proxmox VM template

---

## Create a VM from the template

1. Right-click the template in Proxmox → **Clone**
2. In the VM **Cloud-Init** tab, set at minimum:
   - A username
   - A password and/or SSH public key
   - Network configuration
3. Start the VM

### First boot sequence

The VM goes through two automatic reboots:

| Boot | What happens |
|------|-------------|
| 1st  | Ignition applies configuration, removes Docker packages, installs Podman + qemu-guest-agent → **automatic reboot** |
| 2nd  | System fully operational — Podman rootless socket active, SSH on port 59500 |

> ⚠️ The network must be operational on first boot for package installation.

---

## Cloud-init wrapper

The `fcos-cloudinit` script applies cloud-init settings at every boot. Supported parameters:

| Parameter | Notes |
|-----------|-------|
| User | Single user, default = `admin` |
| Password | Applied via shadow file |
| SSH public key | Written to `authorized_keys.d/ignition` |
| DNS domain | Applied via NetworkManager |
| DNS servers | Applied via NetworkManager |
| IP configuration | IPv4 only (IPv6: TODO) |
| Hostname | Applied via hostnamectl |

---

## Podman

This template uses **Podman** instead of Docker:

- Daemonless and rootless by default — no daemon running as root
- Compatible with Docker images (OCI format)
- `podman-docker` provides a `docker` CLI shim for full compatibility
- `podman-compose` supports `docker-compose.yml` files

The rootless `podman.socket` is automatically enabled for the cloud-init user at first boot:

```bash
ls $XDG_RUNTIME_DIR/podman/podman.sock
# /run/user/1001/podman/podman.sock
```

---

## Hardening

This template achieves a **Lynis score of 81/100**.

### SSH
- Custom port `59500`
- `X11Forwarding no`
- Agent forwarding, TCP forwarding, compression disabled
- Strict auth limits (`MaxAuthTries 3`, `MaxSessions 2`)
- Login banner configured

### Kernel (sysctl)
- Network stack hardening (redirects, source routing, martians logging)
- ASLR enabled (`kernel.randomize_va_space = 2`)
- dmesg restricted, BPF hardening, ptrace scope
- TCP hardening (syncookies, timestamps, fin timeout, keepalive tuning)

### Modules
Unused filesystems, protocols and drivers blacklisted: `cramfs`, `hfs`, `hfsplus`, `jffs2`, `squashfs`, `udf`, `firewire-core`, `usb-storage`, `tipc`, `rds`, `sctp`, `dccp`

### Password policy (`/etc/login.defs`)
- `PASS_MAX_DAYS 365`
- `PASS_MIN_DAYS 1`
- `PASS_MIN_LEN 12`
- `UMASK 027`
- Encryption: YESCRYPT (FCOS default, stronger than SHA512)

### Core dumps
Disabled via `/etc/security/limits.d/disablecoredumps.conf`

### Known acceptable findings
| Finding | Reason |
|---------|--------|
| `kernel.modules_disabled = 1` | Would break Podman and FCOS updates |
| `FIRE-4590` firewall | Architectural choice, use external firewall |
| `FINT-4350` file integrity tool | Out of scope for base template |
| `HRDN-7230` malware scanner | Out of scope for base template |
| `ACCT-9622/9626` process accounting | Overhead not justified |
| `AUTH-9216/9228` grpck/pwck errors | Inherent to FCOS immutable OS design |
| `FILE-6310` /home symlink | FCOS uses `/var/home` by design |

---

## Advanced configuration

The `fcos-base-tmplt.yaml` is a working base. For advanced Ignition configuration, refer to the official documentation:
https://docs.fedoraproject.org/en-US/fedora-coreos/

---

---

## Container management with Quadlet

For management containers like Dockhand, Portainer, or similar tools that need to survive reboots and auto-update, use **Quadlet** instead of `podman-compose`. Quadlet integrates containers directly into systemd, giving you native restart handling and automatic image updates.

### Why Quadlet for management containers

- `Restart=always` is handled by systemd — no dependency on `podman-restart.service`
- `podman auto-update` works natively — no more errors with `podman-compose`
- Automatic rollback if a new image fails to start
- Standard `systemctl` commands to manage the container lifecycle

### Setup

Create the Quadlet directory:

```bash
mkdir -p ~/.config/containers/systemd/
```

Create `~/.config/containers/systemd/dockhand.container`:

```ini
[Unit]
Description=Dockhand container
After=network-online.target local-fs.target
Wants=network-online.target

[Container]
Image=docker.io/fnsys/dockhand:latest
ContainerName=dockhand

# Ports
PublishPort=3000:3000

# Volumes — replace <your_volume_name> with your actual volume name (podman volume ls)
Volume=<your_volume_name>:/app/data

# Socket access (rootless podman)
Volume=%t/podman/podman.sock:/var/run/docker.sock:z

# Privileges required for container management tools
# Risk is limited on a single-user dedicated VM
PodmanArgs=--privileged

# Auto-update label
Label=io.containers.autoupdate=registry

# Healthcheck
HealthCmd=curl -f http://localhost:3000/
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=5s

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

Reload systemd and start the container:

```bash
systemctl --user daemon-reload
systemctl --user start dockhand.service
systemctl --user status dockhand.service
```

### Useful commands

```bash
# View logs
journalctl --user -u dockhand.service -f

# Stop / start / restart
systemctl --user stop dockhand.service
systemctl --user start dockhand.service
systemctl --user restart dockhand.service

# Manual image update
podman pull docker.io/fnsys/dockhand:latest
systemctl --user restart dockhand.service
```

### Automatic image updates

The `podman-auto-update.timer` is enabled automatically on every new VM by the `setup-user-podman` service in the template.

For `podman auto-update` to update a container, it must have the label `io.containers.autoupdate=registry` — already included in the example above.

To trigger an immediate update check:

```bash
podman auto-update
```

To check when the next automatic update is scheduled:

```bash
systemctl --user list-timers podman-auto-update.timer
```

### Other containers

Containers managed by Dockhand (or Portainer) restart automatically after a reboot via `podman-restart.service`, which is enabled by the template. Only the management container itself needs to be defined as a Quadlet unit.

## Credits

Originally based on the [Geco-IT fedora-coreos-proxmox](https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox) project.