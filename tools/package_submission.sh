#!/usr/bin/env bash
# Builds movie-picture-pipeline-submission.zip: a clean snapshot of the repo
# (git archive, so nothing untracked or ignored leaks in) plus the submission notes.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

name=movie-picture-pipeline-submission
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

echo "[package] $(date -u +%FT%TZ) archiving $(git rev-parse --short HEAD)"
mkdir -p "$staging/$name/repo"
git archive HEAD | tar -x -C "$staging/$name/repo"

cp SUBMISSION.md "$staging/$name/README.md"
cp -R docs/screenshots "$staging/$name/screenshots"
cp docs/PRIMER.md docs/primer.html docs/PIPELINE.md "$staging/$name/"

rm -f "$name.zip"
(cd "$staging" && zip -qr "$repo_root/$name.zip" "$name")
echo "[package] wrote $name.zip ($(du -h "$name.zip" | cut -f1))"
unzip -l "$name.zip" | tail -1
