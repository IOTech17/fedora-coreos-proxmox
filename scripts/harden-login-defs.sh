#!/bin/bash
# Patch /etc/login.defs without overwriting FCOS-specific values
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'   /etc/login.defs
sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN    12/'   /etc/login.defs
sed -i 's/^UMASK.*/UMASK           027/'         /etc/login.defs
