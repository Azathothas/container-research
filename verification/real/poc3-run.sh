#!/bin/sh
# PoC 3: AlmaLinux 9 -> EPEL -> fastfetch, run inside the chroot.
set -e
echo "=== os:"
head -2 /etc/os-release
echo "=== dnf: epel-release (extras repo), then fastfetch (epel) in a second transaction"
dnf install -y -q epel-release 2>&1 | tail -1
echo "epel: $(rpm -q epel-release)"
dnf install -y -q fastfetch 2>&1 | grep -E '^Installed|error' | tail -2
echo "=== fastfetch --version:"
fastfetch --version | head -1
echo "=== fastfetch --pipe (data sources: sysinfo(2), netlink, /etc):"
TERM=xterm fastfetch --pipe
echo "POC3-OK"
