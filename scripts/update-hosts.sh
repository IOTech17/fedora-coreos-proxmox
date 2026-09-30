#!/bin/bash
# Update /etc/hosts with current IP and hostname - NAME-4404
CURRENTIP=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {print $7}')
CURRENTHOSTNAME=$(hostname)
[[ -z "${CURRENTIP}" ]] || [[ -z "${CURRENTHOSTNAME}" ]] && exit 0
# Remove old entry if exists then add fresh one
sed -i "/[[:space:]]${CURRENTHOSTNAME}\.local[[:space:]]\+${CURRENTHOSTNAME}$/d" /etc/hosts
echo "${CURRENTIP} ${CURRENTHOSTNAME}.local ${CURRENTHOSTNAME}" >> /etc/hosts
