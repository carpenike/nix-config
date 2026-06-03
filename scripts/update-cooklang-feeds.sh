#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_FILE="$REPO_ROOT/hosts/files/cooklang-federation/feeds.yaml"
TEMP_FILE="$(mktemp)"
SOURCE_URL="https://raw.githubusercontent.com/cooklang/federation/main/config/feeds.yaml"

curl -fsSL "$SOURCE_URL" -o "$TEMP_FILE"

# Normalise upstream formatting so the vendored copy stays lint-clean.
# Upstream occasionally ships large runs of blank lines, which trips
# yamllint's `empty-lines` rule (max 2). Collapse any run of 2+ blank
# lines down to a single blank line and strip trailing whitespace.
NORMALISED_FILE="$(mktemp)"
sed 's/[[:space:]]*$//' "$TEMP_FILE" | cat -s >"$NORMALISED_FILE"
mv "$NORMALISED_FILE" "$TEMP_FILE"

if [ ! -f "$TARGET_FILE" ] || ! cmp -s "$TEMP_FILE" "$TARGET_FILE"; then
  # Portable replace: GNU `install -D` is not available on BSD/macOS, so we
  # mkdir + cp ourselves. The repo's pre-commit hooks will normalise perms.
  mkdir -p "$(dirname "$TARGET_FILE")"
  cp "$TEMP_FILE" "$TARGET_FILE"
  echo "Updated Cooklang feeds definition at $TARGET_FILE"
else
  echo "Cooklang feeds definition already up to date"
fi

rm -f "$TEMP_FILE"

git -C "$REPO_ROOT" status -sb "$TARGET_FILE"
