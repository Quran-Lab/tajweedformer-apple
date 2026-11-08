#!/bin/bash
# CI helper: put the engine submodule's pinned commit at PATH.
#   scripts/ci-engine.sh PATH
# The submodule (Quran-Lab/tajweedformer-engine) normally just checks out. If it cannot be fetched (the engine
# repository not reachable with this workflow's token), the same commit is read from this repository's
# release asset engine-<7 hex>.tar.gz (a `git archive` of that engine commit), checked against the pin.
set -euo pipefail
P=${1:?usage: ci-engine.sh PATH}
pin=$(git ls-tree HEAD "$P" | awk '{print $3}')
if git submodule update --init --depth 1 "$P" 2>/dev/null || git submodule update --init "$P" 2>/dev/null; then
  echo "engine $pin from the submodule"
  exit 0
fi
short=${pin:0:7}
tmp=${RUNNER_TEMP:-/tmp}
gh release download "engine-$short" -R "${GITHUB_REPOSITORY:?}" -D "$tmp" --pattern "engine-$short.tar.gz" --clobber
[ "$(gzip -dc "$tmp/engine-$short.tar.gz" | git get-tar-commit-id)" = "$pin" ] || { echo "engine archive is not $pin" >&2; exit 1; }
# through stdin: Windows tar reads "D:" in a path as a remote host
rm -rf "$P" && mkdir -p "$P" && gzip -dc "$tmp/engine-$short.tar.gz" | tar -xf - -C "$P"
echo "engine $pin from the release asset engine-$short"
