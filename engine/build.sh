#!/bin/bash
# Builds Core's WebKit: upstream at the commit in WEBKIT_COMMIT, with every
# patch in patches/ applied in order, as a release build.
#
#   engine/build.sh            fetch if needed, apply, build
#   engine/build.sh rebase     move to upstream main, re-apply, record the commit
#
# The checkout lives outside the repository (CORE_ENGINE_SRC, default
# ~/repos/core-engine/webkit): it is 8 GB and the build is 30+ GB more.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SRC="${CORE_ENGINE_SRC:-$HOME/repos/core-engine/webkit}"
COMMIT="$(cat "$here/WEBKIT_COMMIT")"

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --filter=blob:none --no-checkout https://github.com/WebKit/WebKit.git "$SRC"
fi
cd "$SRC"

if [ "${1:-}" = "rebase" ]; then
  git fetch --depth 1 origin main
  COMMIT="$(git rev-parse FETCH_HEAD)"
fi

if [ "$(git rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
  git fetch --depth 1 origin "$COMMIT"
  git reset --quiet --hard
  git checkout --quiet --detach "$COMMIT"
fi

# Exactly upstream + patches: if the tree holds anything else, start over.
patches=("$here"/patches/*.patch)
if ! git diff --quiet && ! git apply --reverse --check "${patches[@]}" 2>/dev/null; then
  git reset --quiet --hard
fi
if git diff --quiet; then
  git apply --whitespace=nowarn "${patches[@]}"
fi

[ "${1:-}" = "rebase" ] && echo "$COMMIT" > "$here/WEBKIT_COMMIT"
Tools/Scripts/build-webkit --release
echo "$SRC/WebKitBuild/Release"
