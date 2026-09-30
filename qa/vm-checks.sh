#!/bin/bash
# vm-checks.sh - assertions run as root inside a VM cloned from the template
# Usage (from qa.sh): ssh ... 'sudo -n bash -s -- <hostname> <ipv4> <admin user> [<ipv6/prefix>]' < vm-checks.sh
set -uo pipefail

EXPECTED_HOSTNAME="$1"
EXPECTED_IP="$2"
ADMIN_USER="$3"
EXPECTED_IP6="${4:-}"   # empty: ipv6 not configured, so disabled on the nic
PUSER=podman
FAILED=0

ok()   { echo "  [ok]   $*"; }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }
check() {  # $1 = description, $2.. = command
	local desc="$1"; shift
	if "$@" &> /dev/null; then ok "${desc}"; else fail "${desc}"; fi
}

echo "== system"
check "system state running (no failed unit)" test "$(systemctl is-system-running)" = running
systemctl --failed --no-legend --plain | sed 's/^/         failed: /'
check "hostname = ${EXPECTED_HOSTNAME}" test "$(hostname)" = "${EXPECTED_HOSTNAME}"
check "ipv4 ${EXPECTED_IP} configured" bash -c "ip -4 -o addr show | grep -q ' ${EXPECTED_IP}/'"
if [[ -n "${EXPECTED_IP6}" ]]; then
	check "ipv6 ${EXPECTED_IP6} configured" bash -c "ip -6 -o addr show scope global | grep -q ' ${EXPECTED_IP6} '"
else
	check "ipv6 not configured: no global ipv6 address" bash -c "! ip -6 -o addr show scope global | grep -q inet6"
fi
check "network profile net0 active" bash -c "nmcli -g NAME,DEVICE connection show --active | grep -q '^net0:'"
check "/etc/hosts: exactly one '${EXPECTED_IP} ${EXPECTED_HOSTNAME}.local ${EXPECTED_HOSTNAME}' line" \
	test "$(grep -c "^${EXPECTED_IP} ${EXPECTED_HOSTNAME}\.local ${EXPECTED_HOSTNAME}$" /etc/hosts)" = 1
check "fs.file-max = kernel default (> 65535)" test "$(sysctl -n fs.file-max)" -gt 1000000
check "ip_local_port_range = 32768 60999" test "$(sysctl -n net.ipv4.ip_local_port_range | tr -s '\t ' ' ')" = "32768 60999"
check "ssh port 59500 reserved" bash -c "sysctl -n net.ipv4.ip_local_reserved_ports | grep -qw 59500"
check "sysctl --system without error" test -z "$(sysctl --system 2>&1 > /dev/null)"

echo "== first boot units"
check "setup-fcos-packages done (stamp)" test -f /var/lib/fcos-packages.stamp
check "harden-login-defs done (stamp)" test -f /var/lib/harden-login-defs.stamp
for u in fcos-cloudinit update-hosts setup-user-podman; do
	check "${u}.service succeeded" test "$(systemctl show -p Result --value ${u}.service)" = success
done
layered="$(rpm-ostree status --json | python3 -c 'import json,sys; d=[x for x in json.load(sys.stdin)["deployments"] if x["booted"]][0]; print(" ".join(d.get("requested-packages", [])), "|", " ".join(d.get("requested-base-removals", [])))')"
check "package qemu-guest-agent layered" bash -c "echo '${layered}' | cut -d'|' -f1 | grep -qw qemu-guest-agent"
for p in docker-cli moby-engine; do
	check "package ${p} removed" bash -c "echo '${layered}' | cut -d'|' -f2 | grep -qw ${p}"
done
check "qemu-guest-agent active" systemctl is-active qemu-guest-agent

echo "== admin user ${ADMIN_USER}"
check "user exists" id "${ADMIN_USER}"
check "not in docker group" bash -c "! id -nG ${ADMIN_USER} | grep -qw docker"
check "ssh key installed" bash -c "ls /var/home/${ADMIN_USER}/.ssh/authorized_keys.d/ | grep -q ."

echo "== podman account"
check "user ${PUSER} exists" id "${PUSER}"
PUID="$(id -u "${PUSER}" 2>/dev/null || echo none)"
check "password locked" bash -c "passwd -S ${PUSER} | awk '{print \$2}' | grep -q '^L'"
check "no sudo/wheel group" bash -c "! id -nG ${PUSER} | grep -qwE 'sudo|wheel|adm'"
check "subuid/subgid entries" bash -c "grep -q '^${PUSER}:' /etc/subuid && grep -q '^${PUSER}:' /etc/subgid"
check "linger enabled" test "$(loginctl show-user "${PUSER}" -p Linger --value 2>/dev/null)" = yes
check "NPROC drop-in" grep -q '^LimitNPROC=65536:infinity' "/etc/systemd/system/user@${PUID}.service.d/nproc.conf"
AS=(sudo -u "${PUSER}" XDG_RUNTIME_DIR="/run/user/${PUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus")
for u in podman.socket podman-restart.service podman-auto-update.timer; do
	check "user unit ${u} enabled" bash -c "cd /tmp && ${AS[*]} systemctl --user is-enabled ${u}"
done
check "user podman.socket active" bash -c "cd /tmp && ${AS[*]} systemctl --user is-active podman.socket"
check "socket API responds" curl -sf --unix-socket "/run/user/${PUID}/podman/podman.sock" http://localhost/version
check "rootless container runs" bash -c "cd /tmp && ${AS[*]} podman run --rm quay.io/podman/hello:latest"
check "setup-user-podman idempotent (no change on rerun)" bash -c "test \"\$(/usr/local/bin/setup-user-podman | grep -vc '\] OK:')\" = 0"

echo "== root podman / docker"
check "system podman.socket disabled" bash -c "! systemctl is-enabled podman.socket"
check "system podman.socket inactive" bash -c "! systemctl is-active podman.socket"
check "docker.service masked" test "$(systemctl is-enabled docker.service)" = masked

echo "== network exposure"
check "LLMNR/mDNS not listening (5355, 5353)" bash -c "! ss -lnH | grep -qE ':(5355|5353) '"

echo "== audit / services"
check "auditd running" systemctl is-active auditd
check "audit rules loaded (syscall auditing not disabled)" bash -c "auditctl -l | grep -q -- '-k identity' && ! auditctl -l | grep -q 'never,task'"
for u in nfs-client.target systemd-homed.service gssproxy.service rpc-statd-notify.service; do
	check "${u} not active" bash -c "! systemctl is-active --quiet ${u}"
done

echo "== ssh"
check "sshd listens on 59500" bash -c "sshd -T | grep -qx 'port 59500'"
check "password authentication disabled" bash -c "sshd -T | grep -qx 'passwordauthentication no'"
check "ssh restricted to group wheel" bash -c "sshd -T | grep -qx 'allowgroups wheel'"
check "ssh modern algorithms only (no sha1 mac, no nist kex)" bash -c "! sshd -T | grep -E '^(macs|kexalgorithms) ' | grep -qE 'sha1|nistp|umac-64|hmac-sha2-256,|ecdh'"
check "dead ssh sessions detected (clientaliveinterval 300)" bash -c "sshd -T | grep -qx 'clientaliveinterval 300'"

echo
if [[ ${FAILED} -eq 0 ]]; then echo "VM CHECKS: ALL PASSED"; else echo "VM CHECKS: ${FAILED} FAILED"; fi
exit $(( FAILED > 0 ))
