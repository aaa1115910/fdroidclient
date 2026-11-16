#!/usr/bin/env bash
# Adds/updates the self hosted F-Droid repository in the preloaded repositories asset.
#
# Kept out of the patch set on purpose: the repository address and its signing certificate are
# deployment details, not code. Rebuilding the fork for a different repo (e.g. a mirror or a
# self-hosted instance) only needs different variables.
#
# Required env:
#   REPO_URL        e.g. https://example.github.io/fdroidclient/repo
#   REPO_CERT_HEX   hex encoded DER of the repository signing certificate
# Optional env:
#   REPO_NAME, REPO_DESCRIPTION
set -euo pipefail

cd "$(dirname "$0")/.."

: "${REPO_URL:?REPO_URL is required}"
: "${REPO_CERT_HEX:?REPO_CERT_HEX is required}"
REPO_NAME="${REPO_NAME:-F-Droid Shizuku}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-修改版 F-Droid 客户端（通过 Shizuku 静默安装）的自更新源}"

ASSET="app/src/main/assets/default_repos.json"

python3 - "$ASSET" "$REPO_URL" "$REPO_NAME" "$REPO_DESCRIPTION" "$REPO_CERT_HEX" <<'PY'
import json
import sys

path, url, name, description, certificate = sys.argv[1:6]

with open(path, encoding="utf-8") as file:
    repositories = json.load(file)

# keep the upstream repositories, just make sure our entry is present and first in the list
repositories = [repo for repo in repositories if repo.get("address") != url]
repositories.insert(
    0,
    {
        "name": name,
        "address": url,
        "description": description,
        "certificate": certificate,
        "enabled": True,
    },
)

with open(path, "w", encoding="utf-8") as file:
    json.dump(repositories, file, ensure_ascii=False, indent=2)
    file.write("\n")

print(f"preloaded repository {url} ({len(repositories)} repos in total)")
PY
