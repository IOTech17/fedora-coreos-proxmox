#!/bin/bash
# qa.sh - quality gate for the template: run before promoting any change to the Proxmox node
#
# Usage: qa/qa.sh [static|validate|e2e|promote|all] [--keep] [--dhcp]
#   static    local: bash -n (+ shellcheck if installed) on the scripts and on the inline scripts of the fragment
#   validate  node : butane --strict with the test header AND with the real header of every VM using the hook
#                    (a VM whose regenerated ignition fails would no longer start)
#   e2e       node : stage the files as qa-* snippets, clone the template, copy the cloud-init of REF_VMID
#                    (TEST_IPCONFIG, or DHCP with --dhcp), boot, run vm-checks.sh; then with a broken fragment,
#                    change the cloud-init (network static <-> dhcp) and restart through Proxmox: the VM must
#                    start (safe hook) and fcos-cloudinit apply the change; switch back, check again;
#                    sysprep then start again (must come back configured);
#                    destroy the clone (--keep to keep it with the qa-* snippets)
#   promote   node : backup then copy hook + fragment to the production snippets (runs validate again)
#   all       static + validate + e2e (default). Promote is never automatic.
#
# Configuration: qa/qa.env (not versioned, see qa/qa.env.example)
set -euo pipefail

QA_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "${QA_DIR}")"
HOOK=hook-fcos.sh
FRAGMENT=fcos-base-tmplt.yaml

# node configuration (not needed by the static stage, used alone by CI)
if [[ "${1:-all}" != static ]]; then
	[[ -f "${QA_DIR}/qa.env" ]] || { echo "Missing ${QA_DIR}/qa.env (copy qa/qa.env.example)"; exit 1; }
	# shellcheck source=/dev/null
	source "${QA_DIR}/qa.env"
	: "${PVE_HOST:?}" "${TEMPLATE_VMID:?}" "${REF_VMID:?}" "${TEST_VMID:?}" "${TEST_NAME:?}" "${TEST_IP:?}" "${TEST_IPCONFIG:?}"
fi
SSH_PORT="${SSH_PORT:-59500}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
SNIPPET_DIR="${SNIPPET_DIR:-/var/lib/vz/snippets}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"   # promote: backups of the production snippets kept on the node
TEST_IP6="fd5a:9e3c:1d2b::c7/64" # unique local address, added to the test VM in the last network step
EXPECTED_IP6=""
KEEP=false
FIRST_NET=static
for opt in "${@:2}"; do
	case "${opt}" in
		--keep) KEEP=true ;;
		--dhcp) FIRST_NET=dhcp ;;
		*) echo "unknown option ${opt}"; exit 1 ;;
	esac
done

COREOS_FILES_PATH=/etc/pve/coreos-pve/coreos
PVE_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "${PVE_HOST:-}")
# the test VM gets new host keys at every run: do not pollute known_hosts
VM_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "${SSH_PORT}")

step() { echo -e "\n######## $*"; }
die()  { echo "QA FAILED: $*"; exit 1; }

stage_static() {
	step "static checks (local)"
	local files=("${REPO_DIR}/vmsetup.sh" "${REPO_DIR}/${HOOK}" "${QA_DIR}/qa.sh" "${QA_DIR}/vm-checks.sh" "${REPO_DIR}"/scripts/*.sh)
	for f in "${files[@]}"; do
		bash -n "$f" || die "bash -n $f"
	done
	echo "bash -n OK on ${#files[@]} scripts"
	if command -v shellcheck &> /dev/null; then
		shellcheck -S warning "${files[@]}" || die "shellcheck"
		echo "shellcheck OK (no warning)"
	else
		echo "shellcheck not installed: skipped (run in CI)"
	fi
}

# ==================================================================================================
# butane --strict on the node: test header + real header of every VM using the hook
# (with the butane version and spec of the hook; the real headers are validated with the current spec)
# $1 = fragment path on the node, $2 = hook path on the node, $3 = scripts directory of the fragment
validate_on_node() {
	"${PVE_SSH[@]}" bash -s -- "$1" "${COREOS_FILES_PATH}" "$2" "$3" <<'EOF'
set -uo pipefail
FRAGMENT="$1"; FILES="$2"; HOOKFILE="$3"; SCRIPTS="$4"; FAILED=0
D=$(mktemp -d); chmod 700 "$D"; trap 'rm -rf "$D"' EXIT
# shellcheck source=/dev/null
source <(sed -n '/^BUTANE_SPEC_VERSION=/,/^# main()/p' "${HOOKFILE}")
setup_butane > /dev/null || { echo "  [FAIL] butane ${BUTANE_VERSION:-?} not installed (download or sha256)"; exit 1; }
echo "  butane $(/usr/local/bin/butane --version | awk '{print $NF}'), spec fcos ${BUTANE_SPEC_VERSION}"
first="$(head -1 "${FRAGMENT}")"
cat /tmp/qa-header-test.yaml "${FRAGMENT}" > "$D/test.bu"
if /usr/local/bin/butane --strict --files-dir "${SCRIPTS}" "$D/test.bu" -o /dev/null; then echo "  [ok]   test header"; else echo "  [FAIL] test header"; FAILED=1; fi
for conf in /etc/pve/qemu-server/*.conf; do
	grep -q '^hookscript:.*hook-fcos' "$conf" || continue
	vmid="$(basename "$conf" .conf)"
	grep -q '^template: 1' "$conf" && { echo "  [skip] ${vmid} (template)"; continue; }
	yaml="${FILES}/${vmid}.yaml"
	[[ -f "${yaml}" ]] || { echo "  [skip] ${vmid} (never started: no ${vmid}.yaml)"; continue; }
	[[ -f "${FILES}/${vmid}.ign" ]] || echo "  [warn] ${vmid}: no ${vmid}.ign, the hook will regenerate it at next start"
	line="$(grep -n -F -x -- "${first}" "${yaml}" | cut -d: -f1)"
	[[ "$(echo "${line}" | wc -w)" -eq 1 ]] || { echo "  [FAIL] ${vmid}: cannot find the fragment start in ${vmid}.yaml"; FAILED=1; continue; }
	head -n $((line - 1)) "${yaml}" | sed "s/^version: .*/version: ${BUTANE_SPEC_VERSION}/" | cat - "${FRAGMENT}" > "$D/${vmid}.bu"
	if /usr/local/bin/butane --strict --files-dir "${SCRIPTS}" "$D/${vmid}.bu" -o /dev/null; then echo "  [ok]   VM ${vmid} (real header)"; else echo "  [FAIL] VM ${vmid}: would not start after a cloud-init change"; FAILED=1; fi
done
rm -f /tmp/qa-header-test.yaml
exit ${FAILED}
EOF
}

stage_validate() {
	step "butane --strict on ${PVE_HOST} (test header + every VM using the hook)"
	scp -q "${QA_DIR}/header-test.yaml" "${PVE_HOST}:/tmp/qa-header-test.yaml"
	scp -q "${REPO_DIR}/${FRAGMENT}" "${PVE_HOST}:/tmp/qa-${FRAGMENT}"
	scp -q "${REPO_DIR}/${HOOK}" "${PVE_HOST}:/tmp/qa-${HOOK}"
	"${PVE_SSH[@]}" "rm -rf /tmp/qa-scripts" && scp -rq "${REPO_DIR}/scripts" "${PVE_HOST}:/tmp/qa-scripts"
	"${PVE_SSH[@]}" "bash -n /tmp/qa-${HOOK}" || die "hook syntax on node"
	validate_on_node "/tmp/qa-${FRAGMENT}" "/tmp/qa-${HOOK}" /tmp/qa-scripts || die "butane validation (see above)"
	"${PVE_SSH[@]}" "rm -rf /tmp/qa-${FRAGMENT} /tmp/qa-${HOOK} /tmp/qa-scripts"
}

# ==================================================================================================
# copy hook + fragment to the node as <prefix>hook-fcos.sh / <prefix>fcos-base-tmplt.yaml
install_snippets() {  # $1 = prefix ("" for production, "qa-" for staging)
	scp -q "${REPO_DIR}/${FRAGMENT}" "${PVE_HOST}:${SNIPPET_DIR}/$1${FRAGMENT}"
	"${PVE_SSH[@]}" "rm -rf ${SNIPPET_DIR}/$1${FRAGMENT%.yaml}.d" && scp -rq "${REPO_DIR}/scripts" "${PVE_HOST}:${SNIPPET_DIR}/$1${FRAGMENT%.yaml}.d"
	sed -e "/^COREOS_TMPLT=/ c\COREOS_TMPLT=${SNIPPET_DIR}/$1${FRAGMENT}" "${REPO_DIR}/${HOOK}" \
		| "${PVE_SSH[@]}" "cat > ${SNIPPET_DIR}/$1${HOOK} && chmod 755 ${SNIPPET_DIR}/$1${HOOK}"
}

# current ipv4 of the test VM: TEST_IP in static mode, read through the guest agent in dhcp mode
vm_ipv4() {
	if [[ "${NET_MODE}" == static ]]; then echo "${TEST_IP}"; return 0; fi
	"${PVE_SSH[@]}" "qm agent ${TEST_VMID} network-get-interfaces" 2> /dev/null | python3 -c '
import json, sys
try:
    print(next(a["ip-address"] for i in json.load(sys.stdin) if i["name"] != "lo"
               for a in i.get("ip-addresses", []) if a["ip-address-type"] == "ipv4"))
except Exception:
    pass' || true  # agent not answering yet: retried by wait_vm_ssh
}

wait_vm_ssh() {  # wait until the test VM finished its boots and accepts ssh, sets VM_IP
	local start=${SECONDS}
	while (( SECONDS - start < BOOT_TIMEOUT )); do
		VM_IP="$(vm_ipv4)"
		# boot finished ("degraded" too: the failed units are reported by vm-checks.sh)
		if [[ -n "${VM_IP}" ]] && "${VM_SSH[@]}" "${ADMIN_USER}@${VM_IP}" \
			'test -f /var/lib/fcos-packages.stamp && systemctl is-system-running --wait; true' 2> /dev/null | grep -qE 'running|degraded'; then
			echo "VM reachable on ${VM_IP} (${NET_MODE}) after $((SECONDS - start))s"; return 0
		fi
		sleep 10
	done
	die "VM ${TEST_VMID} not reachable (${NET_MODE}${VM_IP:+, ${VM_IP}}) on port ${SSH_PORT} after ${BOOT_TIMEOUT}s"
}

vm_checks() {
	"${VM_SSH[@]}" "${ADMIN_USER}@${VM_IP}" "sudo -n bash -s -- ${TEST_NAME} ${VM_IP} ${ADMIN_USER} ${EXPECTED_IP6}" \
		< "${QA_DIR}/vm-checks.sh" || die "vm checks (see above)"
}

ipconfig_of() {  # $1 = static|dhcp
	if [[ "$1" == static ]]; then echo "${TEST_IPCONFIG}"; else echo "ip=dhcp"; fi
}

# change the network mode in the cloud-init then restart through Proxmox (hook + fcos-cloudinit)
switch_network() {  # $1 = static|dhcp, $2 = optional ipv6/prefix
	NET_MODE="$1"
	EXPECTED_IP6="${2:-}"
	"${PVE_SSH[@]}" "qm set ${TEST_VMID} --ipconfig0 $(ipconfig_of "$1")${2:+,ip6=$2} > /dev/null && qm shutdown ${TEST_VMID} --timeout 120 && qm start ${TEST_VMID}" \
		| grep -E 'Fedora CoreOS' || true
	wait_vm_ssh
}

destroy_test_vm() {
	"${PVE_SSH[@]}" "rm -rf ${SNIPPET_DIR}/qa-${HOOK} ${SNIPPET_DIR}/qa-${FRAGMENT} ${SNIPPET_DIR}/qa-${FRAGMENT%.yaml}.d
		qm status ${TEST_VMID} &> /dev/null || exit 0
		grep -q '^name: ${TEST_NAME}\$' /etc/pve/qemu-server/${TEST_VMID}.conf || { echo 'VM ${TEST_VMID} is not ${TEST_NAME}: not destroyed'; exit 1; }
		qm stop ${TEST_VMID} &> /dev/null; qm destroy ${TEST_VMID} --purge &> /dev/null
		rm -f ${COREOS_FILES_PATH}/${TEST_VMID}.yaml ${COREOS_FILES_PATH}/${TEST_VMID}.ign ${COREOS_FILES_PATH}/${TEST_VMID}.id
		echo 'test VM ${TEST_VMID} destroyed'"
}

stage_e2e() {
	local first="${FIRST_NET}" other
	if [[ "${first}" == static ]]; then other=dhcp; else other=static; fi
	step "end-to-end test on a clone of ${TEMPLATE_VMID} (VM ${TEST_VMID} ${TEST_NAME}, first boot: ${first})"
	ADMIN_USER="$("${PVE_SSH[@]}" "sed -n 's/^ciuser: //p' /etc/pve/qemu-server/${REF_VMID}.conf")"
	[[ -n "${ADMIN_USER}" ]] || die "no ciuser in VM ${REF_VMID}"
	destroy_test_vm
	"${PVE_SSH[@]}" "! ping -c1 -W1 ${TEST_IP} &> /dev/null" || die "${TEST_IP} already answers ping"
	install_snippets qa-
	NET_MODE="${first}"
	"${PVE_SSH[@]}" bash -s <<EOF || die "clone"
set -e
qm clone ${TEMPLATE_VMID} ${TEST_VMID} --name ${TEST_NAME} > /dev/null
grep -E '^(ciuser|cipassword|sshkeys|nameserver|searchdomain):' /etc/pve/qemu-server/${REF_VMID}.conf >> /etc/pve/qemu-server/${TEST_VMID}.conf
qm set ${TEST_VMID} --ipconfig0 $(ipconfig_of "${first}") --onboot 0 --hookscript ${SNIPPET_STORAGE}:snippets/qa-${HOOK} > /dev/null
echo "clone ${TEST_VMID} created (cloud-init of ${REF_VMID}, $(ipconfig_of "${first}"), hook qa-${HOOK})"
# first start: the hook generates the ignition, sets args, then restarts the VM itself (error expected)
qm start ${TEST_VMID} 2>&1 | grep -E 'Fedora CoreOS|WARNING' || true
EOF
	"${PVE_SSH[@]}" "test -s ${COREOS_FILES_PATH}/${TEST_VMID}.ign" || die "ignition not generated"
	# Proxmox firewall of the template inherited by the clone (when the template has one)
	if "${PVE_SSH[@]}" "test -f /etc/pve/firewall/${TEMPLATE_VMID}.fw"; then
		"${PVE_SSH[@]}" "test -f /etc/pve/firewall/${TEST_VMID}.fw && qm config ${TEST_VMID} | grep -q '^net0:.*firewall=1'" \
			|| die "Proxmox firewall of the template not inherited by the clone"
		echo "Proxmox firewall inherited from the template"
	fi

	step "boot 1 + 2 (packages, reboot)"
	wait_vm_ssh
	step "vm checks"
	vm_checks

	step "safe hook: broken fragment + cloud-init change (network ${first} -> ${other}, dns-search), restart through Proxmox"
	local ign_sum
	ign_sum="$("${PVE_SSH[@]}" "sha256sum < ${COREOS_FILES_PATH}/${TEST_VMID}.ign")"
	"${PVE_SSH[@]}" "echo 'broken: [fragment' > ${SNIPPET_DIR}/qa-${FRAGMENT} && qm set ${TEST_VMID} --searchdomain qa.example.com > /dev/null"
	switch_network "${other}"
	install_snippets qa-
	[[ "$("${PVE_SSH[@]}" "sha256sum < ${COREOS_FILES_PATH}/${TEST_VMID}.ign")" == "${ign_sum}" ]] || die "ignition of a provisioned VM was regenerated"
	echo "VM started with a broken fragment, ignition kept"
	[[ "$("${VM_SSH[@]}" "${ADMIN_USER}@${VM_IP}" 'nmcli -g ipv4.dns-search connection show net0' 2> /dev/null | tail -1)" == qa.example.com ]] \
		|| die "cloud-init change not applied by fcos-cloudinit"
	echo "cloud-init change applied by fcos-cloudinit (${other}, dns-search qa.example.com)"
	vm_checks

	step "network back ${other} -> ${first} and static ipv6 ${TEST_IP6} added, restart through Proxmox"
	switch_network "${first}" "${TEST_IP6}"
	vm_checks
	"${PVE_SSH[@]}" "qm agent ${TEST_VMID} ping" && echo "qemu-guest-agent answers" || die "qemu-guest-agent"

	step "sysprep, then start again: the VM must come back fully configured from the cloud-init"
	"${VM_SSH[@]}" "${ADMIN_USER}@${VM_IP}" "sudo -n /usr/local/bin/fcos-cloudinit sysprep" || die "sysprep did not start"
	"${PVE_SSH[@]}" "for _ in \$(seq 1 60); do qm status ${TEST_VMID} | grep -q stopped && exit 0; sleep 5; done; exit 1" \
		|| die "VM not powered off by sysprep after 300s"
	echo "VM powered off by sysprep"
	"${PVE_SSH[@]}" "qm start ${TEST_VMID}" | grep -E 'Fedora CoreOS' || true
	wait_vm_ssh
	vm_checks

	if ${KEEP}; then
		echo "--keep: VM ${TEST_VMID} and qa-* snippets kept (ssh -p ${SSH_PORT} ${ADMIN_USER}@${VM_IP})"
	else
		destroy_test_vm
	fi
}

# keep only the KEEP_BACKUPS newest backups made by promote (<file>.bak-YYYYMMDD-HHMMSS)
prune_backups() {
	"${PVE_SSH[@]}" bash -s -- "${SNIPPET_DIR}" "${HOOK}" "${FRAGMENT}" "${FRAGMENT%.yaml}.d" "${KEEP_BACKUPS}" <<'EOF'
set -euo pipefail
cd "$1"
keep="$5"
mapfile -t stamps < <(find . -maxdepth 1 -name "$2.bak-*" -printf '%f\n' | sed -n 's/.*\.bak-\([0-9]\{8\}-[0-9]\{6\}\)$/\1/p' | sort)
n=${#stamps[@]}
if (( n > keep )); then
	for stamp in "${stamps[@]:0:n-keep}"; do
		rm -rf -- "$2.bak-${stamp}" "$3.bak-${stamp}" "$4.bak-${stamp}"
		echo "  old backup removed: ${stamp}"
	done
fi
echo "backups kept: $(( n < keep ? n : keep )) (KEEP_BACKUPS=${keep})"
EOF
}

stage_promote() {
	step "promote to production snippets on ${PVE_HOST}"
	local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
	local files_dir="${FRAGMENT%.yaml}.d"
	"${PVE_SSH[@]}" "cd ${SNIPPET_DIR} && cp -a ${HOOK} ${HOOK}.bak-${stamp} && cp -a ${FRAGMENT} ${FRAGMENT}.bak-${stamp} \
		&& { [[ ! -d ${files_dir} ]] || cp -a ${files_dir} ${files_dir}.bak-${stamp}; }"
	echo "backup: ${SNIPPET_DIR}/{${HOOK},${FRAGMENT},${files_dir}}.bak-${stamp}"
	install_snippets ""
	scp -q "${QA_DIR}/header-test.yaml" "${PVE_HOST}:/tmp/qa-header-test.yaml"
	validate_on_node "${SNIPPET_DIR}/${FRAGMENT}" "${SNIPPET_DIR}/${HOOK}" "${SNIPPET_DIR}/${files_dir}" || {
		"${PVE_SSH[@]}" "cd ${SNIPPET_DIR} && cp -a ${HOOK}.bak-${stamp} ${HOOK} && cp -a ${FRAGMENT}.bak-${stamp} ${FRAGMENT} \
			&& rm -rf ${files_dir} && { [[ ! -d ${files_dir}.bak-${stamp} ]] || cp -a ${files_dir}.bak-${stamp} ${files_dir}; }"
		die "validation after promote: previous snippets restored"
	}
	echo "promoted"
	prune_backups
}

case "${1:-all}" in
	static)   stage_static ;;
	validate) stage_validate ;;
	e2e)      stage_e2e ;;
	promote)  stage_promote ;;
	all)      stage_static; stage_validate; stage_e2e ;;
	*)        sed -n '2,15p' "$0"; exit 1 ;;
esac
echo -e "\nQA OK: ${1:-all}"
