#!/bin/bash
# Usage: milkv-tools/screenshot.sh [out.png] [number-of-frames]
# Grabs the board's HDMI output through the UGREEN capture device.
# With more than 1 frame: out-001.png, out-002.png, ... (useful to spot artifacts).
# The device is looked up by name (video numbers change when USB devices are replugged);
# the laptop webcam is never used. MJPEG 1920x1080 sometimes hangs, so the default
# format is used and ffmpeg is killed after 30 s.
set -euo pipefail
OUT=${1:-screen.png}
N=${2:-1}
DEV=${VIDEO_DEV:-}
if [ -z "$DEV" ]; then
	for d in /sys/class/video4linux/video*; do
		if grep -q "UGREEN" "$d/name" && [ "$(cat "$d/index")" = 0 ]; then
			DEV=/dev/$(basename "$d"); break
		fi
	done
fi
[ -n "$DEV" ] || { echo "no UGREEN HDMI capture device found" >&2; exit 1; }
if [ "$N" -gt 1 ]; then OUT=${OUT%.png}-%03d.png; else UPDATE=(-update 1); fi
timeout -s KILL 30 ffmpeg -hide_banner -loglevel error -y -f v4l2 -i "$DEV" \
	-frames:v "$N" "${UPDATE[@]}" "$OUT"
ls ${OUT//%03d/*}
