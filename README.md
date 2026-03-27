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
- **SSH hardening** — custom port `59500`, restricted options
- **Kernel hardening** — sysctl tuning, driver/protocol blacklisting
- **fstrim** — periodic TRIM enabled for SSD storage
- **Zincati** — automatic updates configured with a weekly maintenance window

---

## Requirements

- Proxmox VE 7+
- A storage with snippet support (e.g. `local`)
- Internet access from the Proxmox node (to download FCOS image and packages)

---

## Configuration

Edit `vmsetup.sh` before running:

```bash
TEMPLATE_VMID="10000"        # Proxmox VMID for the template
TEMPLATE_VMSTORAGE="local-lvm"  # Storage for the VM disk
SNIPPET_STORAGE="local"      # Storage for hook script and ignition file
VMDISK_OPTIONS=",discard=on,iothread=1"  # VM disk options
VERSION=43.20251024.3.0      # FCOS stable version to deploy
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
| 2nd  | System is fully operational — Podman rootless socket active for your user |

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
- `podman-docker` provides a `docker` CLI shim for compatibility
- `podman-compose` supports `docker-compose.yml` files

The rootless `podman.socket` is automatically enabled for the cloud-init user at first boot. You can verify with:

```bash
ls $XDG_RUNTIME_DIR/podman/podman.sock
```

---

## Hardening

This template is configured to achieve a high score on [Lynis](https://cisofy.com/lynis/) hardening assessments (~82%):

- SSH: custom port, agent forwarding disabled, X11 disabled, compression disabled, strict auth limits
- Kernel: sysctl tuning (network stack hardening, ASLR, dmesg restriction, BPF hardening)
- Modules: unused filesystems, protocols and drivers blacklisted (cramfs, hfs, tipc, rds, sctp, dccp, firewire, usb-storage)
- Core dumps disabled

---

## Advanced configuration

The `fcos-base-tmplt.yaml` is a working base. For advanced Ignition configuration, refer to the official documentation:
https://docs.fedoraproject.org/en-US/fedora-coreos/

---

## Credits

Originally based on the [Geco-IT fedora-coreos-proxmox](https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox) project.