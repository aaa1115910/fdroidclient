#!/usr/bin/env bash
# Overrides versionCode/versionName of the app module.
#
# This is intentionally *not* part of the patch set: upstream bumps these values regularly, which
# would make the patches conflict for no reason. If the format ever changes, this script fails
# loudly instead of silently shipping a wrong version.
set -euo pipefail

cd "$(dirname "$0")/.."

GRADLE_FILE="app/build.gradle.kts"

VC_BASE=$(grep -m1 -oP 'versionCode = \K[0-9]+' "$GRADLE_FILE" || true)
VN_BASE=$(grep -m1 -oP 'versionName = "\K[^"]+' "$GRADLE_FILE" || true)
# make repeated runs idempotent (local rebuilds), CI always starts from a clean checkout
VN_BASE="${VN_BASE%-shizuku}"
if [ -z "$VC_BASE" ] || [ -z "$VN_BASE" ]; then
  echo "error: could not find versionCode/versionName in $GRADLE_FILE" >&2
  exit 1
fi

# Timestamp based, like the upstream nightly flavor: always increasing, no state to keep around.
# One minute granularity is plenty for a fork that releases on upstream changes.
VC=${FDROID_VERSION_CODE:-$(( $(date +%s) / 60 ))}
VN="${VN_BASE}-shizuku"
TAG="v${VN}-${VC}"

perl -0pi -e "s/versionCode = ${VC_BASE}/versionCode = ${VC}/" "$GRADLE_FILE"
perl -0pi -e "s/versionName = \"\Q${VN_BASE}\E\"/versionName = \"${VN}\"/" "$GRADLE_FILE"

grep -q "versionCode = ${VC}" "$GRADLE_FILE" || { echo "error: versionCode injection failed" >&2; exit 1; }
grep -q "versionName = \"${VN}\"" "$GRADLE_FILE" || { echo "error: versionName injection failed" >&2; exit 1; }

echo "upstream ${VN_BASE} (${VC_BASE}) -> ${VN} (${VC})"

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1" >> "$GITHUB_OUTPUT"
  else
    echo "$1"
  fi
}
out "version_code=${VC}"
out "version_name=${VN}"
out "upstream_version_name=${VN_BASE}"
out "upstream_version_code=${VC_BASE}"
out "tag=${TAG}"
