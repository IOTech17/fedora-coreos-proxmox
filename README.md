# fedora-coreos-proxmox

Fedora CoreOS template for proxmox with cloudinit support

This is a fork of the Geco-IT repository

: https://git.geco-it.net/GECO-IT-PUBLIC/fedora-coreos-proxmox

## Create FCOS VM Template

### Configuration

* **vmsetup.sh**

```
TEMPLATE_VMID="1000"                     # Template Proxmox VMID 
TEMPLATE_VMSTORAGE="thin-ssd"           # Proxmox storage  
SNIPPET_STORAGE="local"                 # Snippets storage for hook and ignition file
VMDISK_OPTIONS=",discard=on"            # Add options to vmdisk
```

* **fcos-base-tmplt.yaml**

The ignition file provided is only a working basis.
For a more advanced configuration go to https://docs.fedoraproject.org/en-US/fedora-coreos/

it contains :

* Correct fstrim service with no fstab file
* Install qemu-guest-agent on first boot
* Install CloudInit wrapper
* Raise console message logging level from DEBUG (7) to WARNING (4)
* Add motd/issue
* Enable docker.service
* Reach 78+ on Lynis hardening score by tweaking sshd config, sysctl.conf and blacklisting unused drivers/protocols/file system

## Operation

Before starting an FCOS VM, we create an ignition file by merging the data from the cloudinit and the fcos-base-tmplt.yaml file.
Then we modify the configuration of the vm to add the loading of the ignition file and we reset the start of the vm.

<p align="center">
  <img src="./screenshot/fcos_proxmox_first_start.png" alt="">
</p>

During the first boot the vm will install qemu-agent and will restart.
Warning, for that the network must be operational

## CloudInit

Only these parameters are supported by our cloudinit wrapper:

* User (only one) default = admin
* Passwd
* DNS domain
* DNS Servers
* SSH public key
* IP Configuration (ipv4 only)

The settings are applied at boot
