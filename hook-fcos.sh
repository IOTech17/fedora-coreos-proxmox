#!/bin/bash

#set -e
 
vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/coreos-pve/coreos
YQ="/usr/local/bin/yq read --exitStatus --printMode v --stripComments --"

# Butane spec version - must match the FCOS version being deployed:
#   fcos 1.4.0 -> Ignition 3.3.0  (FCOS 38-41)
#   fcos 1.5.0 -> Ignition 3.4.0  (FCOS 42)
#   fcos 1.6.0 -> Ignition 3.5.0  (FCOS 43+)  <-- current
BUTANE_SPEC_VERSION="1.6.0"

# ==================================================================================================================================================================
# functions()
#
setup_butane()
{
	local CT_VER=0.26.0
	local ARCH=x86_64
	local OS=unknown-linux-gnu # Linux
	local DOWNLOAD_URL=https://github.com/coreos/butane/releases/download
 
	[[ -x /usr/local/bin/butane ]]&& [[ "x$(/usr/local/bin/butane --version | awk '{print $NF}')" == "x${CT_VER}" ]]&& return 0
	echo "Setup Fedora CoreOS config transpiler..."
	rm -f /usr/local/bin/butane
	curl -fsSL "${DOWNLOAD_URL}/v${CT_VER}/butane-${ARCH}-${OS}" -o /usr/local/bin/butane
	chmod 755 /usr/local/bin/butane
}
setup_butane

setup_yq()
{
	local VER=3.4.1

	[[ -x /usr/local/bin/yq ]]&& [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]]&& return 0
	echo "Setup yaml parser tools yq..."
	rm -f /usr/local/bin/yq
	curl -fsSL "https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64" -o /usr/local/bin/yq
	chmod 755 /usr/local/bin/yq
}
setup_yq

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} - 'instance-id')"
	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ -n $instance_id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]&& {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]&& exit 0 # already done

	mkdir -p ${COREOS_FILES_PATH} || exit 1

	# check config
	cipasswd="$(qm cloudinit dump ${vmid} user | ${YQ} - 'password' 2> /dev/null)" || true # can be empty
	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ "x$(qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]')" == "x" ]]|| VALIDCONFIG=true
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
	echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	qm cloudinit dump ${vmid} user | ${YQ} - 'ssh_authorized_keys[*]' 2>/dev/null \
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
	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} - 'hostname' 2> /dev/null)"
	echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "          ${hostname,,}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml network block... "
	netcards="$(qm cloudinit dump ${vmid} network | ${YQ} - 'config[*].name' 2> /dev/null | wc -l)"
	nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].address[*]" | paste -s -d ";" -)"
	searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} - "config[${netcards}].search[*]" | paste -s -d ";" -)"
	for (( i=0; i<${netcards}; i++ ))
	do
		ipv4="" netmask="" gw="" macaddr="" # reset on each run
		ipv4="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].address 2> /dev/null)" || continue # dhcp
		netmask="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].netmask 2> /dev/null)"
		gw="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].subnets[0].gateway 2> /dev/null)" || true # can be empty
		macaddr="$(qm cloudinit dump ${vmid} network | ${YQ} - config[${i}].mac_address 2> /dev/null)"
		# ipv6: TODO

		echo "    - path: /etc/NetworkManager/system-connections/net${i}.nmconnection" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      mode: 0600" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          [connection]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          type=ethernet" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          id=net${i}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "\n          [ethernet]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          mac-address=${macaddr}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "\n          [ipv4]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          method=manual" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          addresses=${ipv4}/${netmask}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          gateway=${gw}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          dns=${nameservers}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "          dns-search=${searchdomain}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	done
	echo "[done]"

	[[ -e "${COREOS_TMPLT}" ]]&& {
		echo -n "Fedora CoreOS: Generate other block based on template... "
		cat "${COREOS_TMPLT}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	}

	echo -n "Fedora CoreOS: Generate ignition config... "
	/usr/local/bin/butane --pretty --strict \
		--output ${COREOS_FILES_PATH}/${vmid}.ign \
		${COREOS_FILES_PATH}/${vmid}.yaml
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Set args com.coreos/config on VM${vmid}... "
		rm -f /var/lock/qemu-server/lock-${vmid}.conf
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf

		# hack for reload new ignition file
		echo -e "\nWARNING: New generated Fedora CoreOS ignition settings, we must restart vm..."
		qm stop ${vmid} && sleep 2 && qm start ${vmid}&
		exit 1
	}
fi

exit 0