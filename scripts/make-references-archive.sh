#!/usr/bin/env bash
# Archive third-party reference material (docs, tools, source snapshots) so it
# survives link rot. Output goes to dist/:
#   references-<stamp>.tar.gz                  docs + scripts + tools + manifest
#   snapshot-glinuz-hi3798mv100-<sha>.tar.gz   full upstream snapshot
#   snapshot-histb-sdk-SPC050-<sha>.tar.gz     full upstream snapshot
#   snapshot-histb-SPC060-fastboot-<sha>.tar.gz  only source/boot/fastboot
set -eo pipefail

DIST=${DIST:-dist}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
WORK=build/references

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

rm -rf "$WORK"
mkdir -p "$WORK/pkg" "$WORK/tmp" "$DIST"

MANIFEST="$WORK/pkg/MANIFEST.txt"
: > "$MANIFEST"
printf 'EC6108V9C reference archive\nbuilt (UTC): %s\n\n' "$STAMP" >> "$MANIFEST"

resolve_sha() {
  git ls-remote "https://github.com/$1/$2.git" refs/heads/master | cut -f1
}

record() {
  # name url sha path
  size=$(stat -c%s "$4")
  sum=$(sha256sum "$4" | cut -d' ' -f1)
  printf '%-42s %s\n  url:    %s\n  commit: %s\n  bytes:  %s\n  sha256: %s\n\n' \
    "$1" "" "$2" "$3" "$size" "$sum" >> "$MANIFEST"
}

fetch_full() {
  owner=$1; repo=$2; asset=$3
  sha=$(resolve_sha "$owner" "$repo")
  echo "== $owner/$repo @ $sha =="
  out="$DIST/$asset-$sha.tar.gz"
  if [ ! -f "$out" ]; then
    curl -fSL --retry 5 --retry-delay 5 --max-time 3600 \
      -o "$out" "https://codeload.github.com/$owner/$repo/tar.gz/$sha"
  fi
  record "$asset" "https://github.com/$owner/$repo/tree/$sha" "$sha" "$out"
}

# 1) glinuz: Chinese build/flash guide + HiTool screenshots + SDK SPC041B020
fetch_full glinuz hi3798mv100 snapshot-glinuz-hi3798mv100

# 2) JasonFreeLab: HiSTB Linux SDK SPC050 (contains fastboot/uboot sources)
fetch_full JasonFreeLab HiSTBLinuxV100R005C00SPC050 snapshot-histb-sdk-SPC050

# 3) zjkanjie SDK SPC060: keep only source/boot/fastboot (hiboot source)
owner=zjkanjie; repo=HiSTBLinuxV100R005C00SPC060
sha=$(resolve_sha "$owner" "$repo")
echo "== $owner/$repo @ $sha (fastboot subset) =="
full="$WORK/tmp/spc060.tar.gz"
if [ ! -f "$full" ]; then
  curl -fSL --retry 5 --retry-delay 5 --max-time 3600 \
    -o "$full" "https://codeload.github.com/$owner/$repo/tar.gz/$sha"
fi
rm -rf "$WORK/tmp/spc060"
mkdir -p "$WORK/tmp/spc060"
tar -xzf "$full" -C "$WORK/tmp/spc060" --wildcards '*/source/boot/fastboot/*'
pkg="$DIST/snapshot-histb-SPC060-fastboot-$sha.tar.gz"
tar -czf "$pkg" -C "$WORK/tmp/spc060" .
record "snapshot-histb-SPC060-fastboot" "https://github.com/$owner/$repo/tree/$sha" "$sha" "$pkg"
rm -rf "$WORK/tmp" "$full"

# 4) our own docs / scripts / local tools
cp -r docs scripts references "$WORK/pkg/"
printf 'sha256sums of local files:\n' >> "$MANIFEST"
( cd "$WORK/pkg/references" && sha256sum tools/USBFormat.exe ) >> "$MANIFEST"

tar -czf "$DIST/references-$STAMP.tar.gz" -C "$WORK/pkg" .
echo "== archive results =="
ls -lh "$DIST"/references-*.tar.gz "$DIST"/snapshot-*.tar.gz
