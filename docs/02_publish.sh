#!/usr/bin/env bash
# Publish the rendered site (_site/) to the gh-pages branch.
#
# Replaces `quarto publish gh-pages`, whose temporary worktree lives in
# .quarto/ inside Dropbox: there git reports "local modifications", refuses to
# delete old files, and pages removed from the site stay online. This builds
# the commit in a temporary directory outside Dropbox and mirrors _site/
# exactly, so deleted pages and files are removed from the live site.
#
#   quarto render && bash docs/02_publish.sh
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"
[ -f _site/index.html ] || { echo "No _site/ build; run quarto render first." >&2; exit 1; }
[ -f _site/CNAME ] || { echo "_site/CNAME missing; the custom domain would be lost." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'cd "$repo"; git worktree remove --force "$tmp/ghp" 2>/dev/null || true; rm -rf "$tmp"; git worktree prune' EXIT

git fetch -q origin gh-pages
git worktree add -q --detach "$tmp/ghp" origin/gh-pages
rsync -a --delete --exclude .git --exclude .nojekyll _site/ "$tmp/ghp/"
[ -f "$tmp/ghp/.nojekyll" ] || touch "$tmp/ghp/.nojekyll"

cd "$tmp/ghp"
git add -A
if git diff --cached --quiet; then
  echo "gh-pages already matches _site/; nothing to publish."
  exit 0
fi
git diff --cached --stat | tail -1
git commit -q -m "Built site for gh-pages"
git push -q origin HEAD:gh-pages
echo "Pushed. GitHub Pages deploys in about a minute: https://militarydoctrines.com"
