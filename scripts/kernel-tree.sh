#!/bin/bash
# Usage: scripts/kernel-tree.sh <version>        (e.g. 7.2 or 7.3)
#
# Makes sure linux-<version>/ exists and has every patch from linux-<version>-patches/:
#   - .kernel.git: shared (bare) kernel git for all versions; created when missing
#     (blobless clone, blobs are fetched on checkout). With KERNEL_DEPTH=<n> (CI) it is
#     an empty repository instead and only the tag is fetched, <n> commits deep.
#   - tag v<version> is fetched when it is not there yet.
#   - linux-<version>/: git worktree on branch jupiter-<version>, started at v<version>.
#   - each patch is applied with `git am`, unless a commit with the same subject is
#     already in v<version>..HEAD. Running it again is therefore safe.
set -euo pipefail

V=${1:?usage: $0 <version>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KERNEL_URL=${KERNEL_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}
GIT=$ROOT/.kernel.git
TREE=$ROOT/linux-$V
PATCHES=$ROOT/linux-$V-patches
BRANCH=jupiter-$V
TAG=v$V

[ -d "$PATCHES" ] || { echo "no patch directory $PATCHES" >&2; exit 1; }

DEPTH=${KERNEL_DEPTH:-}

if [ ! -d "$GIT" ]; then
	echo ">> creating kernel git in $GIT (from $KERNEL_URL)"
	if [ -n "$DEPTH" ]; then
		git init -q --bare "$GIT"
		git -C "$GIT" remote add origin "$KERNEL_URL"
	else
		git clone --bare --filter=blob:none --no-tags "$KERNEL_URL" "$GIT"
	fi
fi

if ! git -C "$GIT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	echo ">> fetching tag $TAG${DEPTH:+ (depth $DEPTH)}"
	git -C "$GIT" fetch --no-tags ${DEPTH:+--depth "$DEPTH"} origin tag "$TAG"
fi

if [ ! -e "$TREE/.git" ]; then
	echo ">> creating worktree $TREE ($BRANCH at $TAG)"
	if git -C "$GIT" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
		git -C "$GIT" worktree add "$TREE" "$BRANCH"
	else
		git -C "$GIT" worktree add -b "$BRANCH" "$TREE" "$TAG"
	fi
fi

cd "$TREE"
if [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
	echo "linux-$V: a 'git am' is still in progress (resolve it or 'git -C linux-$V am --abort')" >&2
	exit 1
fi

# Subjects of the commits already on top of the tag
applied=$(git log --format=%s "$TAG..HEAD")

subject() {
	git mailinfo /dev/null /dev/null <"$1" | sed -n 's/^Subject: //p'
}

n_new=0
for p in "$PATCHES"/*.patch; do
	[ -e "$p" ] || continue
	s=$(subject "$p")
	if grep -qxF -- "$s" <<<"$applied"; then
		continue
	fi
	echo ">> applying: $(basename "$p")"
	git am --3way --keep-cr "$p"
	n_new=$((n_new + 1))
done

echo ">> linux-$V: $(git rev-list --count "$TAG..HEAD") commits on $TAG ($n_new newly applied)"
