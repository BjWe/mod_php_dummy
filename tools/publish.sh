#!/bin/sh
# Maintainer helper.
#   sh tools/publish.sh          create/push the GitHub repo (CI starts automatically)
#   sh tools/publish.sh release  after CI is green: tag v1.0.0 + GitHub release with sha256
# Requirements: git, gh (logged in)
set -eu
cd "$(dirname "$0")/.."

REPO=${REPO:-BjWe/mod_php_dummy}
TAG=${TAG:-v1.0.0}
DESC="Temporary Apache kill switch for PHP RCE CVE-2026-109618 / CVE-2026-109619 (until PHP is patched)"

gh auth status >/dev/null 2>&1 || { echo "gh not logged in: gh auth login"; exit 1; }
sh tools/build-installer.sh >/dev/null
git diff --quiet install.sh 2>/dev/null || { echo "install.sh regenerated - commit it first"; exit 1; }

case "${1:-repo}" in
repo)
    [ -d .git ] || { git init -q -b main && git add -A && git commit -q -m "mod_php_dummy v1.0.0"; }
    if gh repo view "$REPO" >/dev/null 2>&1; then
        git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
        git push -u origin main
    else
        gh repo create "$REPO" --public -d "$DESC" --source . --remote origin --push
    fi
    gh repo edit "$REPO" --add-topic php,apache,httpd,cve,security,mitigation >/dev/null 2>&1 || true
    echo "Repo: https://github.com/$REPO"
    echo "CI:   https://github.com/$REPO/actions  -> when green: sh tools/publish.sh release"
    ;;
release)
    git tag -a "$TAG" -m "mod_php_dummy $TAG"
    git push origin "$TAG"
    sha256sum install.sh > install.sh.sha256
    gh release create "$TAG" install.sh install.sh.sha256 -R "$REPO" \
        --title "mod_php_dummy $TAG" \
        --notes "Temporary Apache kill switch for CVE-2026-109618 / CVE-2026-109619. Not a fix - patch PHP, then run install.sh --uninstall.

\`\`\`
curl -fsSL https://raw.githubusercontent.com/$REPO/$TAG/install.sh | sudo sh
\`\`\`

sha256: \`$(cut -d' ' -f1 install.sh.sha256)\`"
    rm -f install.sh.sha256
    echo "Install: curl -fsSL https://raw.githubusercontent.com/$REPO/$TAG/install.sh | sudo sh"
    ;;
*)
    echo "usage: sh tools/publish.sh [repo|release]"; exit 1 ;;
esac
