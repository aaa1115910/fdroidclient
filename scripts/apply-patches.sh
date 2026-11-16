#!/usr/bin/env bash
# Applies all patches on top of the current upstream checkout.
#
# The patches contain *all* source changes of this fork. `master` itself only ever adds files,
# so `git merge upstream/master` never conflicts; conflicts can only show up here, and then this
# script fails loudly and leaves the usual .rej files behind.
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
patches=(patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "error: no patches found in patches/" >&2
  exit 1
fi

for patch in "${patches[@]}"; do
  echo "==> applying ${patch}"
  git apply --3way --whitespace=nowarn "$patch"
done

echo "==> all patches applied"
