#!/bin/bash
# Publishes Mac Duo: creates the public GitHub repo, uploads the release, and turns on GitHub Pages.
#   ./scripts/publish.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
REPO="kostakarathana/mac-duo"

[ -f build/MacDuo.dmg ] || ./scripts/build.sh "$VERSION"

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public --source . --push \
    --description "Close your MacBook and the screen folds away like iPhone Duo. Glossy fade when you hold power." \
    --homepage "https://kostakarathana.github.io/mac-duo/"
else
  git push origin main
fi

gh release create "v$VERSION" build/MacDuo.dmg build/MacDuo.zip build/SHA256SUMS.txt \
  --repo "$REPO" --title "Mac Duo $VERSION" \
  --notes "Download **MacDuo.dmg**, drag Mac Duo to Applications, then open it (System Settings → Privacy & Security → Open Anyway the first time). Requires macOS 14+."

# Serve the website from /docs on main.
gh api -X POST "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/docs" >/dev/null 2>&1 \
  || gh api -X PUT "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/docs" >/dev/null
echo "✓ https://kostakarathana.github.io/mac-duo/  (Pages can take a minute to go live)"
