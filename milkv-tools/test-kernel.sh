#!/bin/bash
# Usage: milkv-tools/test-kernel.sh <linux-image-...deb> <release> [screenshot.png]
#   e.g. milkv-tools/test-kernel.sh linux-image-7.3.0-k1-amdgpu-modules_7.3.0-1_riscv64.deb \
#            7.3.0-k1-amdgpu-modules
#
# Full board test of one kernel: install the deb, point /boot.cmd + boot.scr at <release>,
# reboot, wait for ssh, then print the checks (PCIe link, amdgpu init, IB ring tests, SDDM,
# loaded modules, new coredumps) and grab the SDDM login screen over HDMI.
# Mind the free space on /boot (715 MB; ~100-150 MB per kernel incl. initrd).
set -u
BOARD=${BOARD:-192.168.2.32}
DEB=${1:?usage: $0 <deb> <release> [screenshot.png]}
REL=${2:?usage: $0 <deb> <release> [screenshot.png]}
SHOT=${3:-screen-$REL.png}
cd "$(dirname "$0")/.."

milkv-tools/install-deb.sh "$DEB" 2>&1 | grep -E "Setting up|update-initramfs|rror"
milkv-tools/set-boot.sh "$REL" | grep -E "current|vmlinuz"
ssh "$BOARD" 'df -h /boot | tail -1; sudo systemctl reboot'
sleep 25
up=
for i in $(seq 1 48); do
	if ssh -o ConnectTimeout=3 -o BatchMode=yes "$BOARD" true 2>/dev/null; then
		echo "up after ~$((25 + i * 5))s"; up=1; break
	fi
	sleep 5
done
[ -n "$up" ] || { echo "board did not come back; check the serial console" >&2; exit 1; }
sleep 15	# let SDDM start
ssh "$BOARD" 'uname -rv
	sudo dmesg | grep -E "link up|Initialized amdgpu|BAR=|ring .*fail|amdgpu.*error|Oops|BUG:"
	sudo cat /sys/kernel/debug/dri/0/amdgpu_test_ib | tail -1
	echo "sddm: $(systemctl is-active sddm)"
	echo "modules loaded: $(($(lsmod | wc -l) - 1)), tainted: $(cat /proc/sys/kernel/tainted)"
	sudo coredumpctl list --since "-10min" --no-pager 2>&1 | tail -3
	systemd-analyze | head -1'
milkv-tools/screenshot.sh "$SHOT" 2>/dev/null
