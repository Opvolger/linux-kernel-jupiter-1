#!/bin/bash
# Usage: scripts/fetch-debian-config.sh [suite]        (default: sid)
#
# Downloads the newest Debian riscv64 kernel package from <suite> and stores its kernel
# config as configs/debian/config-<release>, the input for scripts/debian-defconfig.sh.
set -euo pipefail

SUITE=${1:-sid}
MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/configs/debian
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The config lives in linux-base-<release>-riscv64 (linux-image-* is only a meta package)
curl -fsSL "$MIRROR/dists/$SUITE/main/binary-riscv64/Packages.xz" | xz -d >"$TMP/Packages"
read -r pkg file < <(awk '
	/^Package: linux-base-[0-9].*-riscv64$/ { p = $2 }
	/^Filename:/ && p { print p, $2; p = "" }' "$TMP/Packages" | sort -V | tail -1)
[ -n "${pkg:-}" ] || { echo "no linux-base-*-riscv64 package in $SUITE" >&2; exit 1; }
release=${pkg#linux-base-}

echo ">> $pkg ($file)"
curl -fsSL -o "$TMP/pkg.deb" "$MIRROR/$file"
mkdir -p "$OUT"
dpkg-deb --fsys-tarfile "$TMP/pkg.deb" |
	tar -xO "./usr/lib/modules/$release/config" >"$OUT/config-$release"
echo ">> $OUT/config-$release"
