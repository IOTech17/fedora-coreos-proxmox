#!/bin/bash

#set -e
 
vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_TMPLT_FILES="${COREOS_TMPLT%.yaml}.d" # scripts included by the template ("local:" entries)
COREOS_FILES_PATH=/etc/pve/coreos-pve/coreos
# Butane spec version (variant fcos) -> Ignition config spec read by the VM on its first boot:
#   fcos 1.6.0 -> Ignition 3.5.0
#   fcos 1.7.0 -> Ignition 3.6.0  (Ignition >= 2.26.0: FCOS 43.20260301 and later)  <-- current
BUTANE_SPEC_VERSION="1.7.0"

# Tools downloaded on the node, pinned and verified (sha256) before being installed
BUTANE_VERSION="0.29.0" # signature checked with the Fedora key (butane-x86_64-unknown-linux-gnu.asc)
BUTANE_SHA256="53a20d820fbaa7fda4f1afd1814974badc8e448db4c151d3f1ba005dc29bc4c9"
YQ_VERSION="v4.53.6"    # sha256 from the release "checksums" file
YQ_SHA256="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"

# ==================================================================================================================================================================
# functions()
#
# install $1 (url) as $2 (path) if its sha256 is $3; keeps the current file on any failure
install_verified()
{
	curl -fsSL --max-time 120 "$1" -o "$2.new" && echo "$3  $2.new" | sha256sum --check --quiet - || {
		rm -f "$2.new"
		echo "[failed]: $1 (download or sha256)"
		return 1
	}
	chmod 755 "$2.new" && mv -f "$2.new" "$2"
}

setup_butane()
{
	[[ -x /usr/local/bin/butane ]]&& [[ "$(/usr/local/bin/butane --version | awk '{print $NF}')" == "${BUTANE_VERSION}" ]]&& return 0
	echo "Setup Fedora CoreOS config transpiler butane ${BUTANE_VERSION}..."
	install_verified "https://github.com/coreos/butane/releases/download/v${BUTANE_VERSION}/butane-x86_64-unknown-linux-gnu" \
		/usr/local/bin/butane "${BUTANE_SHA256}"
}

setup_yq()
{
	[[ -x /usr/local/bin/yq ]]&& [[ "$(/usr/local/bin/yq --version | awk '{print $NF}')" == "${YQ_VERSION}" ]]&& return 0
	echo "Setup yaml parser yq ${YQ_VERSION}..."
	install_verified "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
		/usr/local/bin/yq "${YQ_SHA256}"
}

# print the NetworkManager profile of the physical nic $2 described in the cloud-init network-config $1
# (same function in fcos-cloudinit: the profile it computes at every boot is identical, no network restart)
nm_profile()
{
	local nic="[.config[] | select(.type == \"physical\")][$2]" mac ipv4 netmask gw mode6 ipv6 gw6 dns search
	mac="$(/usr/local/bin/yq "${nic}.mac_address // \"\"" "$1")"
	ipv4="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static\") | .address) // \"\"" "$1")"
	netmask="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static\") | .netmask) // \"\"" "$1")"
	gw="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static\") | .gateway) // \"\"" "$1")"
	mode6="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static6\" or .type == \"ipv6_slaac\" or .type == \"dhcp6\") | .type) // \"\"" "$1")"
	ipv6="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static6\") | .address) // \"\"" "$1")"
	gw6="$(/usr/local/bin/yq "(${nic}.subnets[] | select(.type == \"static6\") | .gateway) // \"\"" "$1")"
	dns="$(/usr/local/bin/yq '.config[] | select(.type == "nameserver") | .address[]' "$1" | paste -s -d ";" -)"
	search="$(/usr/local/bin/yq '.config[] | select(.type == "nameserver") | .search[]' "$1" | paste -s -d ";" -)"

	printf '[connection]\ntype=ethernet\nid=net%s\n\n[ethernet]\nmac-address=%s\n\n[ipv4]\n' "$2" "${mac}"
	if [[ -n "${ipv4}" ]]; then
		printf 'method=manual\naddresses=%s/%s\n' "${ipv4}" "${netmask}"
		if [[ -n "${gw}" ]]; then printf 'gateway=%s\n' "${gw}"; fi
	else
		printf 'method=auto\n' # dhcp
	fi
	if [[ -n "${dns}" ]]; then printf 'dns=%s\n' "${dns}"; fi
	if [[ -n "${search}" ]]; then printf 'dns-search=%s\n' "${search}"; fi
	printf '\n[ipv6]\n'
	case "${mode6}" in
		static6)    printf 'method=manual\naddresses=%s\n' "${ipv6}"
		            if [[ -n "${gw6}" ]]; then printf 'gateway=%s\n' "${gw6}"; fi ;;
		ipv6_slaac) printf 'method=auto\n' ;;
		dhcp6)      printf 'method=dhcp\n' ;;
		*)          printf 'method=disabled\n' ;; # no ipv6 in the cloud-init
	esac
}

# args (ignition passed to qemu) can not be changed while this start task holds the vm lock: abort this
# start, then a detached job sets args once the lock is released (normal locking) and starts the vm again
start_again_with_ignition()
{
	echo -e "\nWARNING: New generated Fedora CoreOS ignition settings, the vm is started again with them..."
	setsid bash -c "
		for _ in \$(seq 1 60); do
			if qm set ${vmid} --args '-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign' &> /dev/null
			then
				logger -t hook-fcos 'VM${vmid}: ignition args set, starting the vm'
				qm start ${vmid} 2>&1 | logger -t hook-fcos
				exit 0
			fi
			sleep 2
		done
		logger -t hook-fcos 'VM${vmid}: could not set the ignition args (vm locked for 120s)'" &> /dev/null < /dev/null &
	exit 1
}

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
	# no download here: a provisioned vm must start even without network (yq may be missing or older)
	instance_id="$(qm cloudinit dump ${vmid} meta | /usr/local/bin/yq '.["instance-id"] // ""' 2> /dev/null)"
	# vm already provisioned (ignition generated and passed with args): never regenerate.
	# Ignition only runs at the first boot and cloud-init changes are applied at every boot by
	# fcos-cloudinit inside the vm: regenerating is useless and a failure would prevent the vm from starting.
	if [[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]] && qm config ${vmid} --current | grep -q ^args
	then
		[[ -n $instance_id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id 2> /dev/null)" ]]&& \
			echo "Fedora CoreOS: cloud-init changed, applied by fcos-cloudinit inside the vm (ignition kept)"
		exit 0
	fi
	# not provisioned yet: tools needed to generate the ignition
	setup_butane || exit 1
	setup_yq || exit 1
	instance_id="$(qm cloudinit dump ${vmid} meta | /usr/local/bin/yq '.["instance-id"] // ""' 2> /dev/null)"
	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ -n $instance_id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]&& {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	# ignition already generated but args not set (e.g. the args job failed): set them, never boot without ignition
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]&& start_again_with_ignition

	mkdir -p ${COREOS_FILES_PATH} || exit 1

	# check config
	cipasswd="$(qm cloudinit dump ${vmid} user | /usr/local/bin/yq '.password // ""')" # can be empty
	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ "x$(qm cloudinit dump ${vmid} user | /usr/local/bin/yq '.ssh_authorized_keys[]')" == "x" ]]|| VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
		exit 1
	}

	# ==========================================================================
	# YAML generation
	# Structure must be:
	#   variant / version
	#   passwd:
	#     users: [...]
	#   storage:
	#     disks: [...]      <- resize root partition
	#     files: [...]      <- hostname, network
	# All top-level keys appear exactly once - no duplicates allowed by butane.
	# ==========================================================================

	# --- Header ---
	echo -e "# This file is managed by hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "variant: fcos" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "version: ${BUTANE_SPEC_VERSION}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml

	# --- passwd block ---
	echo -n "Fedora CoreOS: Generate yaml users block... "
	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
	echo -e "passwd:\n  users:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      gecos: \"CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      groups: [ "sudo", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	qm cloudinit dump ${vmid} user | /usr/local/bin/yq '.ssh_authorized_keys[]' \
		| sed -e 's/^/        - "/' -e 's/$/"/' >> ${COREOS_FILES_PATH}/${vmid}.yaml || true
	echo "" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	# --- storage block ---
	# disks: resize root partition (partition 4) to fill available disk space.
	# size_mib: 0 = no size constraint, works for both FCOS 42 and FCOS 43.
	# files: hostname + network config, listed under the same storage: key.
	echo "storage:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "  disks:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "    - device: /dev/disk/by-id/coreos-boot-disk" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      wipe_table: false" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      partitions:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "        - number: 4" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "          label: root" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "          size_mib: 0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "          resize: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml

	echo -n "Fedora CoreOS: Generate yaml hostname block... "
	hostname="$(qm cloudinit dump ${vmid} user | /usr/local/bin/yq '.hostname // ""')"
	echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "          ${hostname,,}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml network block... "
	netcfg="$(mktemp)"
	qm cloudinit dump ${vmid} network > "${netcfg}"
	netcards="$(/usr/local/bin/yq '[.config[] | select(.type == "physical")] | length' "${netcfg}")"
	for (( i=0; i<${netcards}; i++ ))
	do
		{
			echo "    - path: /etc/NetworkManager/system-connections/net${i}.nmconnection"
			echo "      mode: 0600"
			echo "      overwrite: true"
			echo "      contents:"
			echo "        inline: |"
			nm_profile "${netcfg}" ${i} | sed -e 's/^/          /' -e 's/^ *$//'
		} >> ${COREOS_FILES_PATH}/${vmid}.yaml
	done
	rm -f "${netcfg}"
	echo "[done]"

	[[ -e "${COREOS_TMPLT}" ]]&& {
		echo -n "Fedora CoreOS: Generate other block based on template... "
		cat "${COREOS_TMPLT}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	}

	echo -n "Fedora CoreOS: Generate ignition config... "
	/usr/local/bin/butane --pretty --strict --files-dir "${COREOS_TMPLT_FILES}" \
		--output ${COREOS_FILES_PATH}/${vmid}.ign \
		${COREOS_FILES_PATH}/${vmid}.yaml
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

	# first start: pass the ignition to qemu
	qm config ${vmid} --current | grep -q ^args || start_again_with_ignition
fi

exit 0