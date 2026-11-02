#!/usr/bin/env bash
# Fetch the HiSTB SDK (pinned snapshot) into build/sdk and print its path.
set -eo pipefail

SDK_REPO=${SDK_REPO:-zjkanjie/HiSTBLinuxV100R005C00SPC060}
SDK_SHA=${SDK_SHA:-}
CACHE=${CACHE:-build/cache}
SRC=${SRC:-build/sdk}

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"
mkdir -p "$CACHE"

if [ -z "$SDK_SHA" ]; then
  SDK_SHA=$(git ls-remote "https://github.com/$SDK_REPO.git" refs/heads/master | cut -f1)
  [ -n "$SDK_SHA" ] || { echo "cannot resolve SDK commit" >&2; exit 1; }
fi

TARBALL="$CACHE/sdk-$SDK_SHA.tar.gz"
if [ ! -f "$TARBALL" ]; then
  echo "== downloading $SDK_REPO @ $SDK_SHA =="
  curl -fSL --retry 5 --retry-delay 5 --max-time 3600 \
    -o "$TARBALL.part" "https://codeload.github.com/$SDK_REPO/tar.gz/$SDK_SHA"
  mv "$TARBALL.part" "$TARBALL"
fi

if [ ! -f "$SRC/Makefile" ]; then
  echo "== extracting SDK =="
  mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
fi

echo "$SDK_SHA" > "$CACHE/sdk.sha"
echo "SDK ready: $SRC (commit $SDK_SHA)"
