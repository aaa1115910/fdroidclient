#!/usr/bin/env bash
# One time setup: generates the APK signing key and the F-Droid repository signing key.
#
# Everything lands in ./keys (git-ignored). Back this directory up somewhere safe:
#   * losing the APK key means users have to uninstall and reinstall the app
#   * losing the repo key means users have to re-add the repository
#
# Afterwards it prints all values you need as GitHub secrets.
set -euo pipefail

cd "$(dirname "$0")/.."

KEYS_DIR="${KEYS_DIR:-keys}"
APPSTORE="$KEYS_DIR/app.jks"
REPOSTORE="$KEYS_DIR/repo.jks"
SECRETS="$KEYS_DIR/secrets.env"

if [ -e "$APPSTORE" ] || [ -e "$REPOSTORE" ]; then
  echo "error: $KEYS_DIR already contains keystores, refusing to overwrite." >&2
  echo "       move them away first if you really want to generate new ones." >&2
  exit 1
fi

mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"
# make sure keys can never be committed, no matter what the root .gitignore says
printf '*\n' > "$KEYS_DIR/.gitignore"

APP_PASS=$(openssl rand -hex 24)
REPO_PASS=$(openssl rand -hex 24)

echo "==> generating APK signing key (RSA 4096, 10000 days)"
keytool -genkeypair -v \
  -keystore "$APPSTORE" -alias app \
  -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12 \
  -storepass "$APP_PASS" -keypass "$APP_PASS" \
  -dname "CN=F-Droid Shizuku, O=personal" >/dev/null

echo "==> generating repository signing key"
keytool -genkeypair -v \
  -keystore "$REPOSTORE" -alias repo \
  -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12 \
  -storepass "$REPO_PASS" -keypass "$REPO_PASS" \
  -dname "CN=F-Droid Shizuku Repo, O=personal" >/dev/null

echo "==> extracting repository certificate (hex DER, goes into default_repos.json)"
REPO_CERT_HEX=$(
  keytool -exportcert -keystore "$REPOSTORE" -alias repo -storepass "$REPO_PASS" -rfc \
    | openssl x509 -outform DER \
    | od -An -v -tx1 | tr -d ' \n'
)

BASE_URL="${REPO_URL:-https://YOUR_USER.github.io/YOUR_REPO/repo}"

cat > "$SECRETS" <<EOF
# GitHub Actions secrets for the fdroid-shizuku fork. Keep this file private.
SIGNING_KEYSTORE_BASE64=$(base64 -w0 "$APPSTORE")
SIGNING_STORE_PASSWORD=$APP_PASS
SIGNING_KEY_ALIAS=app
SIGNING_KEY_PASSWORD=$APP_PASS

REPO_KEYSTORE_BASE64=$(base64 -w0 "$REPOSTORE")
REPO_STORE_PASSWORD=$REPO_PASS
REPO_KEY_ALIAS=repo
REPO_KEY_PASSWORD=$REPO_PASS

# Repository variables (not secret, but needed by the build)
REPO_URL=$BASE_URL
REPO_CERT_HEX=$REPO_CERT_HEX
EOF
chmod 600 "$SECRETS"

cat <<EOF

Done. Keys and secrets are in $KEYS_DIR/:
  $APPSTORE   APK signing keystore
  $REPOSTORE  repository signing keystore
  $SECRETS    base64 values + passwords, ready for \`gh secret set\`

Set them on your fork with:

  set -a; . $SECRETS; set +a
  gh secret set SIGNING_KEYSTORE_BASE64 --body "\$SIGNING_KEYSTORE_BASE64"
  gh secret set SIGNING_STORE_PASSWORD  --body "\$SIGNING_STORE_PASSWORD"
  gh secret set SIGNING_KEY_ALIAS       --body "\$SIGNING_KEY_ALIAS"
  gh secret set SIGNING_KEY_PASSWORD    --body "\$SIGNING_KEY_PASSWORD"
  gh secret set REPO_KEYSTORE_BASE64    --body "\$REPO_KEYSTORE_BASE64"
  gh secret set REPO_STORE_PASSWORD     --body "\$REPO_STORE_PASSWORD"
  gh secret set REPO_KEY_ALIAS          --body "\$REPO_KEY_ALIAS"
  gh secret set REPO_KEY_PASSWORD       --body "\$REPO_KEY_PASSWORD"
  gh variable set REPO_URL              --body "\$REPO_URL"
  gh variable set REPO_CERT_HEX         --body "\$REPO_CERT_HEX"

Repository certificate (hex DER), for reference:
  $REPO_CERT_HEX

Local build with the real keys (optional):

  set -a; . $SECRETS; set +a
  export ANDROID_HOME=\$HOME/Android/Sdk
  REPO_URL="\$REPO_URL" REPO_CERT_HEX="\$REPO_CERT_HEX" bash scripts/inject-repo.sh
  VERSION_CODE=\$(date +%s | xargs -I{} expr {} / 60) bash scripts/build-apk.sh

EOF
