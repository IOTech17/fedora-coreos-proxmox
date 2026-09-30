#!/bin/bash
# setup-user-podman - dedicated unprivileged account for rootless Podman (idempotent, every boot)
set -euo pipefail
PUSER=podman
PCOMMENT="Podman rootless (containers)"
NPROC_LIMIT="65536:infinity"
log() { echo "[setup-user-podman] $*"; }

if ! getent passwd "${PUSER}" >/dev/null; then
  log "create account ${PUSER}"
  useradd --comment "${PCOMMENT}" --create-home --shell /bin/bash "${PUSER}"
  passwd --lock "${PUSER}" >/dev/null
fi
PUID=$(id -u "${PUSER}"); PHOME=$(getent passwd "${PUSER}" | cut -d: -f6)
for f in /etc/subuid /etc/subgid; do grep -q "^${PUSER}:" "$f" || { log "ERROR: ${PUSER} missing from $f"; exit 1; }; done

# containers created through the Docker-compatible API freeze the host NPROC limit (crun setrlimit error)
DROPIN=/etc/systemd/system/user@${PUID}.service.d/nproc.conf
if [[ ! -f "${DROPIN}" ]]; then
  log "NPROC limit ${NPROC_LIMIT}"
  install -d -m 0755 "$(dirname "${DROPIN}")"
  printf '[Service]\nLimitNPROC=%s\n' "${NPROC_LIMIT}" > "${DROPIN}"; chmod 0644 "${DROPIN}"
  systemctl daemon-reload; RESTART_USER_MANAGER=true
fi

enable_user_unit() {  # $1 = unit, $2 = target
  local wants="${PHOME}/.config/systemd/user/$2.wants"
  if [[ ! -e "${wants}/$1" ]]; then
    log "enable $1"
    install -d -o "${PUSER}" -g "${PUSER}" -m 0755 "${PHOME}/.config" "${PHOME}/.config/systemd" "${PHOME}/.config/systemd/user" "${wants}"
    ln -sf "/usr/lib/systemd/user/$1" "${wants}/$1"; chown -h "${PUSER}:${PUSER}" "${wants}/$1"
  fi
}
enable_user_unit podman.socket            sockets.target
enable_user_unit podman-restart.service   default.target
enable_user_unit podman-auto-update.timer timers.target
install -d -o "${PUSER}" -g "${PUSER}" -m 0750 "${PHOME}/.config/containers" "${PHOME}/.config/containers/systemd"

if [[ "$(loginctl show-user "${PUSER}" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  log "enable linger"; loginctl enable-linger "${PUSER}"
fi
if [[ "${RESTART_USER_MANAGER:-false}" == true ]] && systemctl is-active --quiet "user@${PUID}.service"; then
  log "restart user@${PUID}"; systemctl restart "user@${PUID}.service"
fi
systemctl start "user@${PUID}.service"
for _ in $(seq 1 20); do [[ -S "/run/user/${PUID}/bus" ]] && break; sleep 1; done
sudo -u "${PUSER}" XDG_RUNTIME_DIR="/run/user/${PUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" \
  systemctl --user start podman.socket podman-auto-update.timer
log "OK: socket /run/user/${PUID}/podman/podman.sock"
