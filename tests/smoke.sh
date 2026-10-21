#!/bin/sh
# End-to-end smoke test, run as root inside a fresh distro container (see CI).
# Expects Apache + PHP installed and running, DocumentRoot at $DOCROOT.
#   1. PHP executes before install
#   2. after install: PHP -> 503 + CVE page, no source leak, static -> 200
#   3. second run is a no-op
#   4. after uninstall: PHP executes again
set -eu

DOCROOT=${DOCROOT:-/var/www/html}
BASE=${BASE:-http://127.0.0.1}
INSTALLER=${INSTALLER:-./install.sh}
SECRET=S3CR3T_$$

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok:   $*"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$BASE$1"; }
body() { curl -s "$BASE$1"; }

mkdir -p "$DOCROOT/app" "$DOCROOT/legacy"
printf '<?php $pw="%s"; echo "PHP_RUNS";' "$SECRET" > "$DOCROOT/index.php"
cp "$DOCROOT/index.php" "$DOCROOT/app/index.php"
printf '<?php $pw="%s";' "$SECRET" > "$DOCROOT/config.inc"
printf '<?php echo "PHP_RUNS"; /* %s */' "$SECRET" > "$DOCROOT/legacy/page.html"
echo static > "$DOCROOT/style.css"
printf 'RewriteEngine On\nRewriteCond %%{REQUEST_FILENAME} !-f\nRewriteRule ^ index.php [L]\n' > "$DOCROOT/app/.htaccess"
printf 'AddType application/x-httpd-php .html\n' > "$DOCROOT/legacy/.htaccess"
chmod -R a+rX "$DOCROOT"

# --- 1. baseline ---
body /index.php | grep -q PHP_RUNS || fail "baseline: PHP does not execute (test setup broken)"
ok "baseline: PHP executes"

# --- 2. install ---
cat "$INSTALLER" | sh
sleep 1
for u in /index.php / /app/some/route /config.inc /legacy/page.html; do
    c=$(code "$u"); b=$(body "$u")
    [ "$c" = 503 ]                                   || fail "$u: expected 503, got $c"
    echo "$b" | grep -q "Waiting for CVE patch"      || fail "$u: CVE page missing"
    echo "$b" | grep -q "$SECRET"                    && fail "$u: SOURCE LEAKED"
    echo "$b" | grep -q PHP_RUNS                     && fail "$u: PHP EXECUTED"
    ok "$u -> 503, no execution, no leak"
done
curl -sI "$BASE/index.php" | grep -qi '^retry-after: 3600' || fail "Retry-After header missing"
ok "Retry-After header present"
[ "$(code /style.css)" = 200 ] || fail "static file not served"
ok "/style.css -> 200"

# --- 3. idempotent ---
cat "$INSTALLER" | sh | grep -q "already active" || fail "second run not idempotent"
ok "second run is a no-op"
cat "$INSTALLER" | sh -s -- --status | grep -q ACTIVE || fail "--status does not report ACTIVE"
ok "--status reports ACTIVE"

# --- 4. uninstall ---
cat "$INSTALLER" | sh -s -- --uninstall
sleep 1
if [ -n "${FPM_START:-}" ]; then sh -c "$FPM_START"; sleep 1; fi
body /index.php | grep -q PHP_RUNS || fail "after uninstall: PHP does not execute again"
[ ! -d /var/lib/mod_php_dummy ] || fail "state dir left behind"
ok "uninstall restored PHP"

echo "ALL TESTS PASSED"
