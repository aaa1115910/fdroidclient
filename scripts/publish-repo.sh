#!/usr/bin/env bash
# Generates the F-Droid repository index with fdroidserver and publishes it to the gh-pages branch.
#
# Required env:
#   APK                     path to the signed APK
#   VERSION_CODE/VERSION_NAME
#   REPO_URL                public URL the repo will be served from
#   REPO_KEYSTORE_BASE64    base64 of the repository signing keystore
#   REPO_STORE_PASSWORD, REPO_KEY_ALIAS, REPO_KEY_PASSWORD
#   GITHUB_REPOSITORY, GITHUB_TOKEN
# Optional env:
#   PKG (default org.fdroid.fdroid.shizuku), REPO_NAME, REPO_DESCRIPTION, SOURCE_REPO
set -euo pipefail

cd "$(dirname "$0")/.."

: "${APK:?APK must point to the signed APK}"
: "${VERSION_CODE:?VERSION_CODE must be set}"
: "${REPO_URL:?REPO_URL must be set}"
: "${REPO_KEYSTORE_BASE64:?REPO_KEYSTORE_BASE64 must be set}"
: "${REPO_STORE_PASSWORD:?REPO_STORE_PASSWORD must be set}"
: "${REPO_KEY_ALIAS:?REPO_KEY_ALIAS must be set}"
: "${REPO_KEY_PASSWORD:?REPO_KEY_PASSWORD must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

PKG="${PKG:-org.fdroid.fdroid.shizuku}"
VERSION_NAME="${VERSION_NAME:-unknown}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/${GITHUB_REPOSITORY}}"
REPO_NAME="${REPO_NAME:-F-Droid Shizuku}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-修改版 F-Droid 客户端（通过 Shizuku 静默安装程序）的自更新源}"

if ! command -v fdroid >/dev/null; then
  echo "error: fdroidserver not found in PATH" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/fd/metadata" "$WORK/fd/repo"
printf '%s' "$REPO_KEYSTORE_BASE64" | base64 -d > "$WORK/fd/keystore.jks"

cat > "$WORK/fd/config.yml" <<EOF
repo_url: ${REPO_URL}
repo_name: ${REPO_NAME}
repo_description: ${REPO_DESCRIPTION}
repo_keyalias: ${REPO_KEY_ALIAS}
keystore: ${WORK}/fd/keystore.jks
keystorepass: ${REPO_STORE_PASSWORD}
keypass: ${REPO_KEY_PASSWORD}
archive_older: 0
make_current_version_link: false
EOF

cat > "$WORK/fd/metadata/${PKG}.yml" <<EOF
Name: F-Droid (Shizuku)
Summary: F-Droid 客户端，通过 Shizuku 静默安装/更新 APK
Description: |-
  基于上游 F-Droid 客户端的最小改动版本，使用 Shizuku 以 shell 身份安装 APK，
  因此不依赖系统自带的软件包安装器，也可以在安装器被裁剪的 ROM 上正常安装与更新应用。
  本仓库仅用于该客户端自身的自动更新。
License: GPL-3.0-or-later
SourceCode: ${SOURCE_REPO}
IssueTracker: ${SOURCE_REPO}/issues
Categories:
  - System
EOF

cp "$APK" "$WORK/fd/repo/"
echo "==> indexing $(basename "$APK") as ${PKG} ${VERSION_CODE}"
(cd "$WORK/fd" && fdroid update --use-date-from-apk --clean)

ls -la "$WORK/fd/repo"

if [ "${DRY_RUN:-0}" = "1" ]; then
  rm -rf build/repo-preview
  mkdir -p build
  cp -a "$WORK/fd/repo" build/repo-preview
  echo "==> DRY_RUN, repository left in build/repo-preview"
  exit 0
fi

echo "==> publishing to gh-pages"
mkdir -p "$WORK/site" && cd "$WORK/site"
git init -q
git checkout -q --orphan gh-pages
cp -a "$WORK/fd/repo/." .
touch .nojekyll
git add -A
git -c user.name="fdroid-shizuku-bot" \
    -c user.email="bot@users.noreply.github.com" \
    commit -qm "repo: ${PKG} ${VERSION_NAME} (${VERSION_CODE})"
git push -q --force \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" gh-pages
echo "==> published ${REPO_URL}"
