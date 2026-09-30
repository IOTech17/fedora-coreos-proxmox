#!/bin/bash
#
#
#  Apply Basic Cloudinit Settings
#
# ===================================================================================
declare -r VERSION=1.2011

set -e
trap 'catch $?' EXIT

CIPATH=/run/cloudinit
YQ_VERSION="v4.53.6" # pinned, sha256 from the release "checksums" file
YQ_SHA256="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"

# ===================================================================================
# functions()
catch() {
  ${MOUNTED:-false} && umount ${CIPATH} && rmdir ${CIPATH}
}
mount | grep -q /run/cloudinit && MOUNTED=true # init

# use for vm clone: remove everything specific to this vm, then power off
# (next boot: fcos-cloudinit re-applies the cloud-init, setup-user-podman recreates the podman account)
sysprep() {
  # run detached from the ssh session: the sessions of all users are terminated below
  [[ -n "${INVOCATION_ID:-}" ]] || {
    echo "sysprep runs as fcos-sysprep.service (journalctl -u fcos-sysprep -f), the vm powers off at the end"
    exec systemd-run --unit=fcos-sysprep --collect --quiet /usr/local/bin/fcos-cloudinit sysprep
  }
  echo "Remove all ssh system keys..."
  rm -f /etc/ssh/ssh_host_*

  echo "Clean ostree database (automatic updates stopped first)..."
  systemctl stop zincati.service || true
  rpm-ostree cancel &> /dev/null || true # update being staged by zincati
  rpm-ostree cleanup --base --pending --rollback --repomd || echo "[WARN]: ostree cleanup failed, continuing"

  echo "Remove all local users (sessions and rootless containers stopped first)..."
  for user in $(awk -F: -v uiduser="1000" '{if ($3>=uiduser) print $1}' /etc/passwd); do
    uid=$(id -u "${user}")
    loginctl disable-linger "${user}" || true
    loginctl terminate-user "${user}" &> /dev/null || true
    systemctl stop "user@${uid}.service" || true
    userdel --force --remove "${user}"
  done
  rm -f /var/lib/systemd/linger/*
  rm -rf /etc/systemd/system/user@*.service.d

  echo "Purge all podman ressources..."
  podman system prune --all --force

  echo "Remove all network/machine settings..."
  rm -f /var/lib/NetworkManager/*
  rm -f /etc/NetworkManager/system-connections/net*.nmconnection # bound to the mac address
  sed -i '/^[0-9.]* [^ ]*\.local [^ ]*$/d' /etc/hosts # lines written by update-hosts
  echo "" > /etc/machine-id

  echo "Remove obsolete stamps..."
  rm -f /var/lib/setup-user-podman.stamp # older template versions

  echo "Purge all system logs..."
  journalctl --rotate --vacuum-time=1s
  systemctl stop systemd-journald*
  rm -rf /var/log/journal/*

  echo "Force run cloudinit on next reboot..."
  echo "fake" > /var/.cloudinit

  echo -e "\nShutdown now..."
  poweroff

  exit 0
}
[[ "x${1}" == "xsysprep" ]]&& sysprep

# yq (cloud-init files are yaml): downloaded once, installed only if its sha256 matches
setup_yq() {
  [[ -x /usr/local/bin/yq ]]&& [[ "$(/usr/local/bin/yq --version | awk '{print $NF}')" == "${YQ_VERSION}" ]]&& return 0
  echo -n "[INFO]: Cloudinit: setup yaml parser yq ${YQ_VERSION}... "
  curl -fsSL --max-time 120 -o /usr/local/bin/yq.new "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && echo "${YQ_SHA256}  /usr/local/bin/yq.new" | sha256sum --check --quiet - || {
      rm -f /usr/local/bin/yq.new
      echo "[failed]"
      exit 1
    }
  chmod 755 /usr/local/bin/yq.new && mv -f /usr/local/bin/yq.new /usr/local/bin/yq
  echo "[done]"
}
setup_yq

# network
# print the NetworkManager profile of the physical nic $2 described in the cloud-init network-config $1
# (same function in hook-fcos.sh: the profile written by Ignition on the first boot is identical)
nm_profile() {
  local nic="[.config[] | select(.type == \"physical\")][$2]" mac ipv4 netmask gw mode6 ipv6 gw6 dns search
  mac="$(yq "${nic}.mac_address // \"\"" "$1")"
  ipv4="$(yq "(${nic}.subnets[] | select(.type == \"static\") | .address) // \"\"" "$1")"
  netmask="$(yq "(${nic}.subnets[] | select(.type == \"static\") | .netmask) // \"\"" "$1")"
  gw="$(yq "(${nic}.subnets[] | select(.type == \"static\") | .gateway) // \"\"" "$1")"
  mode6="$(yq "(${nic}.subnets[] | select(.type == \"static6\" or .type == \"ipv6_slaac\" or .type == \"dhcp6\") | .type) // \"\"" "$1")"
  ipv6="$(yq "(${nic}.subnets[] | select(.type == \"static6\") | .address) // \"\"" "$1")"
  gw6="$(yq "(${nic}.subnets[] | select(.type == \"static6\") | .gateway) // \"\"" "$1")"
  dns="$(yq '.config[] | select(.type == "nameserver") | .address[]' "$1" | paste -s -d ";" -)"
  search="$(yq '.config[] | select(.type == "nameserver") | .search[]' "$1" | paste -s -d ";" -)"

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

cdr2mask()
{
  # Number of args to shift, 255..255, first non-255 byte, zeroes
  set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
  [[ $1 -gt 1 ]] && shift $1 || shift
  echo ${1-0}.${2-0}.${3-0}.${4-0}
}

# ===================================================================================
# main()
echo "[INFO]: fcos-cloudinit ${VERSION}"
[[ ! -e /dev/sr0 ]]&& {
  echo "[INFO]: Cloudinit: any drive found..."
  exit 0
}
mkdir -p ${CIPATH}
mount -o ro /dev/sr0 ${CIPATH}
MOUNTED=true

[[ ! -e ${CIPATH}/meta-data ]]&& {
  echo "[ERROR]: Cloudinit: nocloud metada not found..."
  exit 1
}

cloudinit_instanceid="$(yq '.["instance-id"] // ""' ${CIPATH}/meta-data)"
if [[ -e /var/.cloudinit ]]
then
  [[ "x$(cat /var/.cloudinit)" == "x${cloudinit_instanceid}" ]]&& {
  echo "[INFO]: Cloudinit any change detected..."
  exit 0
  }

  # hostname
  NEWHOSTNAME="$(yq '.hostname // ""' ${CIPATH}/user-data)"
  [[ -n "${NEWHOSTNAME}" ]]&& [[ "x${NEWHOSTNAME,,}" != "x$(hostname)" ]]&& {
    echo -n "[INFO]: Cloudinit: set hostname to ${NEWHOSTNAME,,}... "
    hostnamectl set-hostname ${NEWHOSTNAME,,} || { echo "[failed]"; exit 1; }
    MUST_REBOOT=true
    echo "[done]"
  }

  # username
  NEWUSERNAME="$(yq '.user // ""' ${CIPATH}/user-data)" # cant be empty if no cloudinit user defined
  [[ "x${NEWUSERNAME}" == "x" ]] && NEWUSERNAME="admin" # NEWUSERNAME="core" use "admin" on fcos-template
  getent passwd ${NEWUSERNAME} &> /dev/null || {
    echo -n "[INFO]: Cloudinit: add system user: ${NEWUSERNAME}... "
    useradd --comment "CoreOS Administrator" --create-home \
            --groups adm,wheel,sudo,systemd-journal ${NEWUSERNAME} &> /dev/null || { echo "[failed]"; exit 1; }
    echo "[done]"
  }
  # passwd
  NEWPASSWORD="$(yq '.password // ""' ${CIPATH}/user-data)"
  [[ -n "${NEWPASSWORD}" ]]&& [[ "x${NEWPASSWORD}" != "x$(grep "^${NEWUSERNAME}:" /etc/shadow | awk -F: '{print $2}')" ]]&& {
    echo -n "[INFO]: Cloudinit: set password for user ${NEWUSERNAME}... "
    sed -e "/^${NEWUSERNAME}:/d" -i /etc/shadow &> /dev/null || { echo "[failed]"; exit 1; }
    echo "${NEWUSERNAME}:${NEWPASSWORD}:18000:0:99999:7:::" >> /etc/shadow || { echo "[failed]"; exit 1; }
    chage --lastday "$(date +%Y-%m-%d)" ${NEWUSERNAME} &> /dev/null || { echo "[failed]"; exit 1; }
    echo "[done]"
  }
  # ssh key
  [[ -e /var/home/${NEWUSERNAME}/.ssh/authorized_keys.d/ignition ]] || {
    install --directory --owner=${NEWUSERNAME} --group=${NEWUSERNAME} \
            --mode=0700 /var/home/${NEWUSERNAME}/.ssh &> /dev/null || { echo "[failed]"; exit 1; }
    install --directory --owner=${NEWUSERNAME} --group=${NEWUSERNAME} \
            --mode=0700 /var/home/${NEWUSERNAME}/.ssh/authorized_keys.d &> /dev/null || { echo "[failed]"; exit 1; }
    install --owner=${NEWUSERNAME} --group=${NEWUSERNAME} \
            --mode=0600 /dev/null /var/home/${NEWUSERNAME}/.ssh/authorized_keys.d/ignition &> /dev/null || { echo "[failed]"; exit 1; }
  }
  echo -n "[INFO]: Cloudinit: wrote ssh authorized keys file for user: ${NEWUSERNAME}... "
  yq '.ssh_authorized_keys[]' ${CIPATH}/user-data > /var/home/${NEWUSERNAME}/.ssh/authorized_keys.d/ignition || { echo "[failed]"; exit 1; }
  echo "[done]"
  # Network: one NetworkManager profile per nic, rewritten only when the cloud-init changes it
  netcards="$(yq '[.config[] | select(.type == "physical")] | length' ${CIPATH}/network-config)"
  rm -f /etc/NetworkManager/system-connections/default_connection.nmconnection # remove default connexion settings
  for (( i=0; i<${netcards}; i++ )); do
    profile=/etc/NetworkManager/system-connections/net${i}.nmconnection
    nm_profile ${CIPATH}/network-config ${i} > /run/net${i}.nmconnection.new
    if ! cmp -s /run/net${i}.nmconnection.new ${profile}; then
      echo -n "[INFO]: Cloudinit: NET${i} $(grep -E '^(method|addresses|gateway|dns|dns-search)=' /run/net${i}.nmconnection.new | paste -s -d ' ' -), wrote NetworkManager config... "
      install --mode=0600 /run/net${i}.nmconnection.new ${profile} || { echo "[failed]"; exit 1; }
      MUST_NET_RECONFIG=true
      echo "[done]"
    fi
    rm -f /run/net${i}.nmconnection.new
  done
fi

${MUST_NET_RECONFIG:-false}&& {
  echo "[INFO]: Cloudinit: must reload network..."
  nmcli connection reload
  nmcli networking off
  nmcli networking on
  # wait for the new configuration (dhcp lease) before the units ordered after fcos-cloudinit
  nm-online --quiet --timeout=60 || echo "[WARN]: Cloudinit: network not online after 60s"
}

echo -n "[INFO]: Cloudinit: save instance id... "
echo "${cloudinit_instanceid}" > /var/.cloudinit
echo "[done]"
${MUST_REBOOT:-false}&& {
  echo "[INFO]: Cloudinit: applied settings; must reboot..."
  /bin/systemctl --no-block reboot
}

exit 0
