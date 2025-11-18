#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_FILE="$REPO_ROOT/hosts/files/cooklang-federation/feeds.yaml"
TEMP_FILE="$(mktemp)"
SOURCE_URL="https://raw.githubusercontent.com/cooklang/federation/main/config/feeds.yaml"

curl -fsSL "$SOURCE_URL" -o "$TEMP_FILE"

if [ ! -f "$TARGET_FILE" ] || ! cmp -s "$TEMP_FILE" "$TARGET_FILE"; then
  install -D "$TEMP_FILE" "$TARGET_FILE"
  echo "Updated Cooklang feeds definition at $TARGET_FILE"
else
  echo "Cooklang feeds definition already up to date"
fi

rm -f "$TEMP_FILE"

git -C "$REPO_ROOT" status -sb "$TARGET_FILE"
