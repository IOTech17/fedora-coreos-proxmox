#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars (inherited by the clones, adjustable per clone)
VMDISK_OPTIONS=",discard=on,iothread=1"
TEMPLATE_CORES=8
TEMPLATE_MEMORY=8192   # MB
TEMPLATE_ONBOOT=1      # 1 = clones start with the Proxmox node
# template vmid, vm storage, snippet storage and network bridge are detected / asked at runtime

TEMPLATE_IGNITION="fcos-base-tmplt.yaml"

# fcos version (empty = latest release of the stream)
STREAMS=stable
VERSION=
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# =============================================================================================
# functions

# print the values of key $1 from a pvesh json list read on stdin
pve_list() {
	python3 -c 'import json, sys; [print(v) for v in sorted(i[sys.argv[1]] for i in json.load(sys.stdin))]' "$1"
}

# ask the user to pick one of $2..$n (prompt $1), result in CHOICE
choose() {
	local prompt="$1"; shift
	echo "${prompt}:"
	PS3="> "
	select CHOICE in "$@"; do [[ -n "${CHOICE}" ]] && break; done
	[[ -n "${CHOICE}" ]] || exit 1
}

# =============================================================================================
# main()

# latest fcos version ?
if [[ -z "${VERSION}" ]]
then
	echo -n "Get latest fedora coreos ${STREAMS} version... "
	read -r VERSION VERSION_SHA256 < <(curl -fsSL ${BASEURL}/streams/${STREAMS}.json | python3 -c '
import json, sys
artifact = json.load(sys.stdin)["architectures"]["x86_64"]["artifacts"][sys.argv[1]]
print(artifact["release"], artifact["formats"]["qcow2.xz"]["disk"]["sha256"])
' ${PLATFORM}) || true
	[[ -n "${VERSION}" && -n "${VERSION_SHA256}" ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[${VERSION}]"
fi

PVE_NODE="$(hostname)"

# template vmid (default: next free vmid)
next_vmid="$(pvesh get /cluster/nextid)"
while true
do
	read -r -p "Template VMID [${next_vmid}]: " TEMPLATE_VMID || exit 1
	TEMPLATE_VMID="${TEMPLATE_VMID:-${next_vmid}}"
	pvesh get /cluster/nextid --vmid "${TEMPLATE_VMID}" &> /dev/null && break
	echo "VMID ${TEMPLATE_VMID} is invalid or already in use"
done

# vm storage (content "images")
mapfile -t vm_storages < <(pvesh get /nodes/${PVE_NODE}/storage --content images --enabled 1 --output-format json | pve_list storage)
[[ ${#vm_storages[@]} -gt 0 ]] || {
	echo "No storage with content \"Disk image\" found"
	exit 1
}
choose "Storage for the template vm disk" "${vm_storages[@]}"
TEMPLATE_VMSTORAGE="${CHOICE}"

# snippet storage (content "snippets")
mapfile -t snippet_storages < <(pvesh get /nodes/${PVE_NODE}/storage --content snippets --enabled 1 --output-format json | pve_list storage)
case ${#snippet_storages[@]} in
	0)
		echo "No storage with content \"Snippets\" found: you must activate content snippets on a storage (e.g. local)"
		exit 1
	;;
	1)
		SNIPPET_STORAGE="${snippet_storages[0]}"
	;;
	*)
		choose "Storage for the hook-script and ignition config" "${snippet_storages[@]}"
		SNIPPET_STORAGE="${CHOICE}"
	;;
esac
echo "Snippet storage: ${SNIPPET_STORAGE}"

# network bridge
mapfile -t bridges < <(pvesh get /nodes/${PVE_NODE}/network --type any_bridge --output-format json | pve_list iface)
[[ ${#bridges[@]} -gt 0 ]] || {
	echo "No network bridge found"
	exit 1
}
choose "Network bridge for the template vm" "${bridges[@]}"
VMNET="${CHOICE}"

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
rm -rf ${snippet_storage}/snippets/${TEMPLATE_IGNITION%.yaml}.d # scripts included by the template
cp -av scripts ${snippet_storage}/snippets/${TEMPLATE_IGNITION%.yaml}.d
sed -e "/^COREOS_TMPLT=/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
        btrfs|dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]"; ;;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]" ;;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

# download fcos vdisk
[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]]&& {
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
    [[ -n "${VERSION_SHA256}" ]] && {
        echo "${VERSION_SHA256}  fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz" | sha256sum -c - || {
            rm -f fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
            exit 1
        }
    }
    xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
}

# create a new VM
echo "Create fedora coreos vm ${TEMPLATE_VMID}"
qm create ${TEMPLATE_VMID} --name fedora-coreos-template
qm set ${TEMPLATE_VMID} --memory ${TEMPLATE_MEMORY} \
			--cpu host \
			--cores ${TEMPLATE_CORES} \
			--agent enabled=1 \
			--autostart 1 \
			--onboot ${TEMPLATE_ONBOOT} \
			--ostype l26 \
			--tablet 0 \
			--boot c --bootdisk virtio0 \
   			--serial0 socket

template_vmcreated=$(date +%Y-%m-%d)
qm set ${TEMPLATE_VMID} --description "Fedora CoreOS - Template

 - Version             : ${VERSION}
 - Cloud-init          : true

Creation date : ${template_vmcreated}
"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=${VMNET}
#qm set ${TEMPLATE_VMID} --net1 virtio,bridge=vmbr1

echo -e "\nCreate Cloud-init vmdisk..."
qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

# import fedora disk
if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
then
	vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.raw"
	vmdisk_format="--format raw"
else
	vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi
qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --virtio0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}
rm -f fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 # imported, ~2 GB

# set hook-script
qm set ${TEMPLATE_VMID} -hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh


# convert vm template
echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
qm template ${TEMPLATE_VMID} > /dev/null
echo "[done]"
