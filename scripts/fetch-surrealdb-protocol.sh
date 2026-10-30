#!/usr/bin/env bash
# Checks out surrealdb-protocol at the pinned release into .build/surrealdb-protocol,
# for the conformance vector tests and the conformance driver. The vectors and
# scenarios stay in that repository; nothing from it is committed here.
set -euo pipefail

# Bump with ConformanceVectors.pinnedVersion and .github/workflows/ci.yml.
tag="${SURREALDB_PROTOCOL_TAG:-v0.14.0}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${SURREALDB_PROTOCOL_DIR:-$root/.build/surrealdb-protocol}"

if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch --quiet --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    git -C "$dest" -c advice.detachedHead=false checkout --quiet "$tag"
else
    mkdir -p "$(dirname "$dest")"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/surrealdb/surrealdb-protocol.git "$dest"
fi
echo "surrealdb-protocol $tag at $dest"
