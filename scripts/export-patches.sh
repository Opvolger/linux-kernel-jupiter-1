#!/bin/bash
# Usage: scripts/export-patches.sh <version>
#
# Writes the commits v<version>..HEAD of linux-<version>/ back out as
# linux-<version>-patches/NNNN-*.patch. Workflow: change the kernel in linux-<version>/,
# commit (or `git commit --fixup` + `git rebase -i --autosquash v<version>`), then run
# this script. Old .patch files in the directory are removed first.
set -euo pipefail

V=${1:?usage: $0 <version>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=$ROOT/linux-$V
PATCHES=$ROOT/linux-$V-patches

[ -e "$TREE/.git" ] || { echo "no kernel tree $TREE" >&2; exit 1; }
if [ -n "$(git -C "$TREE" status --porcelain --untracked-files=no)" ]; then
	echo "linux-$V has uncommitted changes; commit them first" >&2
	exit 1
fi

mkdir -p "$PATCHES"
rm -f "$PATCHES"/*.patch
git -C "$TREE" format-patch --quiet --zero-commit --no-signature \
	-o "$PATCHES" "v$V..HEAD"
ls "$PATCHES"
