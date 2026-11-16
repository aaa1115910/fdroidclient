#!/usr/bin/env bash
# Builds, aligns, signs and verifies the release APK.
#
# Produces build/dist/fdroid-shizuku-<versionCode>.apk (build/ is git ignored)
# (if apksigner emits one).
#
# Required env: ANDROID_HOME (or ANDROID_SDK_ROOT), VERSION_CODE,
#               SIGNING_KEYSTORE_BASE64, SIGNING_STORE_PASSWORD,
#               SIGNING_KEY_ALIAS, SIGNING_KEY_PASSWORD
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
: "${SDK:?ANDROID_HOME or ANDROID_SDK_ROOT must be set}"
: "${VERSION_CODE:?VERSION_CODE must be set}"
: "${SIGNING_KEYSTORE_BASE64:?SIGNING_KEYSTORE_BASE64 must be set}"
: "${SIGNING_STORE_PASSWORD:?SIGNING_STORE_PASSWORD must be set}"
: "${SIGNING_KEY_ALIAS:?SIGNING_KEY_ALIAS must be set}"
: "${SIGNING_KEY_PASSWORD:?SIGNING_KEY_PASSWORD must be set}"

BUILD_TOOLS=$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)
if [ -z "$BUILD_TOOLS" ]; then
  echo "error: no build-tools installed in $SDK/build-tools" >&2
  exit 1
fi

export JAVA_HOME="${JAVA_HOME:-}"
# extra Gradle flags, e.g. GRADLE_ARGS="-x lintVitalAnalyzeFullDefaultRelease" for low memory boxes
EXTRA_ARGS=()
if [ -n "${GRADLE_ARGS:-}" ]; then
  read -r -a EXTRA_ARGS <<< "${GRADLE_ARGS}"
fi
./gradlew --no-daemon --console=plain assembleFullDefaultRelease "${EXTRA_ARGS[@]}"

UNSIGNED=$(find app/build/outputs/apk/fullDefault/release -name '*-unsigned.apk' | head -1)
if [ -z "$UNSIGNED" ]; then
  # AGP only emits "unsigned" when no signing config is present; adjust if upstream adds one
  UNSIGNED=$(find app/build/outputs/apk/fullDefault/release -name '*.apk' | head -1)
fi
if [ -z "$UNSIGNED" ]; then
  echo "error: no APK produced" >&2
  exit 1
fi
echo "==> unsigned APK: $UNSIGNED"

mkdir -p build/dist
KEYSTORE=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '$KEYSTORE'" EXIT
printf '%s' "$SIGNING_KEYSTORE_BASE64" | base64 -d > "$KEYSTORE"

OUT="build/dist/fdroid-shizuku-${VERSION_CODE}.apk"
"$BUILD_TOOLS/zipalign" -p -f 4 "$UNSIGNED" build/dist/aligned.apk
"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass "pass:$SIGNING_STORE_PASSWORD" \
  --ks-key-alias "$SIGNING_KEY_ALIAS" \
  --key-pass "pass:$SIGNING_KEY_PASSWORD" \
  --out "$OUT" \
  build/dist/aligned.apk
rm -f build/dist/aligned.apk

echo "==> verifying"
"$BUILD_TOOLS/apksigner" verify --print-certs "$OUT"
BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$OUT" 2>/dev/null || true)
echo "$BADGING" | head -3

EXPECTED_PACKAGE="${EXPECTED_PACKAGE:-org.fdroid.fdroid.shizuku}"
if ! grep -q "package: name='${EXPECTED_PACKAGE}'" <<<"$BADGING"; then
  echo "error: unexpected package name, expected ${EXPECTED_PACKAGE}" >&2
  exit 1
fi
if ! grep -q "versionCode='${VERSION_CODE}'" <<<"$BADGING"; then
  echo "error: unexpected versionCode, expected ${VERSION_CODE}" >&2
  exit 1
fi
echo "==> OK: $OUT"
