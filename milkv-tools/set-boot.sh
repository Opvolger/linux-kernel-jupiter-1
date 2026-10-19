#!/bin/bash
# Usage: milkv-tools/set-boot.sh             show which kernel /boot.cmd boots
#        milkv-tools/set-boot.sh <release>   e.g. 7.3.0-k1-amdgpu-modules
#
# Replaces the current kernel release in /boot.cmd on the board with <release>
# (backup: /boot.cmd.<old release>) and regenerates boot.scr. First checks that
# vmlinuz, the dtb and (for -modules) the initrd of <release> exist.
set -euo pipefail
BOARD=${BOARD:-192.168.2.32}

cur=$(ssh "$BOARD" "grep -o 'vmlinuz-[^ ;\"]*' /boot.cmd | head -1" | sed 's/^vmlinuz-//')
echo "current: $cur"
[ $# -gt 0 ] || exit 0
new=$1
[ "$new" != "$cur" ] || { echo "already set to $new"; exit 0; }

ssh "$BOARD" "test -f /boot/vmlinuz-$new && test -f /usr/lib/linux-image-$new/spacemit/k1-milkv-jupiter.dtb" ||
	{ echo "kernel $new is not (fully) installed on the board" >&2; exit 1; }
case "$new" in *-modules)
	ssh "$BOARD" "test -f /boot/initrd.img-$new" || { echo "no initrd for $new" >&2; exit 1; }
	ssh "$BOARD" "grep -q initrd /boot.cmd" ||
		{ echo "/boot.cmd does not load an initrd; edit it by hand" >&2; exit 1; } ;;
esac

ssh "$BOARD" "sudo cp /boot.cmd /boot.cmd.$cur && sudo sed -i 's/$cur/$new/g' /boot.cmd &&
	cd / && sudo mkimage -C none -A riscv -T script -d boot.cmd boot.scr >/dev/null && cat /boot.cmd"
