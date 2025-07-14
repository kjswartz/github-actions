#!/usr/bin/env bash
# build_installer.sh
# Standalone script to build and copy from <repo-1> into <repo-2> and open a PR
# Usage: sh ./build_installer.sh

set -euo pipefail

# --- Input Parameters ---
FROM_REPO="${1:-}" # OWNER/NAME
TO_REPO="${2:-}"   # OWNER/NAME

BRANCH_NAME="build-update-$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Build <repo-1> ---
echo "Building $FROM_REPO ..."
cd "$SCRIPT_DIR"
bun run build

# --- Clone the target repository ---
echo "Cloning $TO_REPO ..."
TMP_TO_REPO="$(mktemp -d)"
gh repo clone "$TO_REPO" "$TMP_TO_REPO"
cd "$TMP_TO_REPO"

git checkout -b "$BRANCH_NAME"

# --- Copy template files ---
echo "Copying bloom-discussion build files ..."
cp "$SCRIPT_DIR/." .

git add .

git commit -m "Update build files"

git push --set-upstream origin "$BRANCH_NAME"

# --- Create Pull Request ---
PR_TITLE="Update build files"
PR_BODY="This PR adds the build files.

### 📝 Changes
Added / updated the following files:
- file 1
- file 2"

PR_FLAGS=(--title "$PR_TITLE" --body "$PR_BODY" --head "$BRANCH_NAME" --base main)

echo "Creating pull request ..."
gh pr create "${PR_FLAGS[@]}"

echo "Removing Temporary directory: $TMP_TO_REPO"
rm -rf "$TMP_TO_REPO"
if [ ! -d "$TMP_TO_REPO" ]; then
  echo "Temporary directory removed successfully."
else
  echo "Failed to remove temporary directory!"
fi

echo "Done!"
