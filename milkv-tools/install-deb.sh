#!/bin/bash
# Usage: milkv-tools/install-deb.sh <linux-image-...deb> [more .debs]
# Copies the packages to the board and installs them with dpkg -i
# (Debian creates the initrd for the modules kernel while doing so).
# The board still boots the kernel named in /boot.cmd afterwards: see set-boot.sh.
set -euo pipefail
BOARD=${BOARD:-192.168.2.32}
[ $# -gt 0 ] || { echo "usage: $0 <deb> [deb ...]" >&2; exit 1; }
scp "$@" "$BOARD:/tmp/"
names=()
for d in "$@"; do names+=("/tmp/$(basename "$d")"); done
ssh "$BOARD" sudo dpkg -i "${names[@]}"
ssh "$BOARD" 'ls -la /boot/ | grep -E "vmlinuz|initrd"'
