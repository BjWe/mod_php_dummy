#!/bin/sh
# mod_php_dummy installer - temporary PHP kill switch for Apache httpd 2.4
# https://github.com/BjWe/mod_php_dummy
# Stopgap for CVE-2026-109618 / CVE-2026-109619 until PHP is patched.
#
#   Install:    curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh
#   Uninstall:  curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh -s -- --uninstall
#   Status:     curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh -s -- --status
#
# Options (environment):  KEEP_FPM=1  do not stop running php-fpm services
#                         NO_DEPS=1   do not install build dependencies
#
# What it does:
#   - builds mod_php_dummy with apxs (installs apache2-dev / httpd-devel if needed)
#   - disables mod_php, enables mod_php_dummy + fallback FilesMatch block
#   - runs configtest; on failure everything is rolled back automatically
#   - reloads Apache, stops running php-fpm services
#   - records all changes in /var/lib/mod_php_dummy for --uninstall
#
# License: MIT - no warranty.

set -eu

STATE_DIR=/var/lib/mod_php_dummy
MARK='#PHPDUMMY#'

log()  { printf '\033[1;34m[php_dummy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[php_dummy] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[php_dummy] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "please run as root (… | sudo sh)"

ACTION=install
case "${1:-}" in
    ""|--install)  ACTION=install ;;
    --uninstall)   ACTION=uninstall ;;
    --status)      ACTION=status ;;
    -h|--help)     echo "usage: install.sh [--install|--uninstall|--status]   env: KEEP_FPM=1 NO_DEPS=1"; exit 0 ;;
    *)             die "unknown option: $1 (use --install, --uninstall, --status)" ;;
esac

# ---------- platform detection ----------
if [ -d /etc/apache2/mods-available ] && command -v a2enmod >/dev/null 2>&1; then
    FAMILY=debian
    MODDIR=/usr/lib/apache2/modules
    SVC=apache2
elif [ -d /etc/httpd/conf.modules.d ]; then
    FAMILY=rhel
    MODDIR=/usr/lib64/httpd/modules
    [ -d "$MODDIR" ] || MODDIR=/usr/lib/httpd/modules
    SVC=httpd
else
    die "no supported Apache layout found (Debian/Ubuntu apache2 or RHEL-family httpd)"
fi

APACHECTL=$(command -v apachectl || command -v apache2ctl || true)
[ -n "$APACHECTL" ] || die "apachectl not found"

configtest() { "$APACHECTL" configtest >/dev/null 2>&1; }
reload() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active -q "$SVC" 2>/dev/null; then
        systemctl reload "$SVC"
    else
        "$APACHECTL" graceful >/dev/null 2>&1 \
            || "$(command -v httpd || command -v apache2)" -k graceful
    fi
}
module_loaded() { "$APACHECTL" -M 2>/dev/null | grep -q "php_dummy_module"; }

# ---------- status ----------
if [ "$ACTION" = status ]; then
    if module_loaded; then log "mod_php_dummy is ACTIVE"; else log "mod_php_dummy is NOT loaded"; fi
    "$APACHECTL" -M 2>/dev/null | grep -i php || true
    [ -d "$STATE_DIR" ] && log "state: $(ls "$STATE_DIR" | tr '\n' ' ')"
    exit 0
fi

# ---------- uninstall ----------
if [ "$ACTION" = uninstall ]; then
    [ -d "$STATE_DIR" ] || warn "no state in $STATE_DIR - removing module config only"
    if [ "$FAMILY" = debian ]; then
        a2dismod -q php_dummy >/dev/null 2>&1 || true
        a2disconf -q cve-php-block >/dev/null 2>&1 || true
        if [ -s "$STATE_DIR/php_mods" ]; then
            while read -r m; do [ -n "$m" ] && a2enmod -q "$m" && log "re-enabled $m"; done < "$STATE_DIR/php_mods"
        fi
        if [ -s "$STATE_DIR/php_confs" ]; then
            while read -r c; do [ -n "$c" ] && a2enconf -q "$c" && log "re-enabled conf $c"; done < "$STATE_DIR/php_confs"
        fi
        rm -f /etc/apache2/mods-available/php_dummy.load /etc/apache2/conf-available/cve-php-block.conf
    else
        rm -f /etc/httpd/conf.modules.d/99-php_dummy.conf /etc/httpd/conf.d/cve-php-block.conf
        for f in /etc/httpd/conf.modules.d/*.conf; do
            grep -q "^$MARK" "$f" 2>/dev/null && sed -i "s/^$MARK//" "$f" && log "restored $f"
        done
    fi
    configtest || die "configtest failed after uninstall - check: $APACHECTL configtest"
    reload
    if [ -s "$STATE_DIR/fpm_services" ]; then
        while read -r s; do [ -n "$s" ] && systemctl start "$s" && log "started $s"; done < "$STATE_DIR/fpm_services"
    fi
    if [ -s "$STATE_DIR/so_path" ]; then rm -f "$(cat "$STATE_DIR/so_path")"; else rm -f "$MODDIR/mod_php_dummy.so"; fi
    rm -rf "$STATE_DIR"
    log "uninstalled. Verify PHP version on this host: php -v"
    exit 0
fi

# ---------- install ----------
if module_loaded; then
    log "mod_php_dummy already active - nothing to do (use --status / --uninstall)"
    exit 0
fi

APXS=$(command -v apxs || command -v apxs2 || true)
if [ -z "$APXS" ] || ! command -v gcc >/dev/null 2>&1; then
    [ "${NO_DEPS:-0}" = 1 ] && die "apxs/gcc missing and NO_DEPS=1"
    log "installing build dependencies ..."
    if [ "$FAMILY" = debian ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q apache2-dev gcc libc6-dev >/dev/null 2>&1 \
            || { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q apache2-dev gcc libc6-dev >/dev/null; } \
            || die "apt-get install apache2-dev gcc failed"
    else
        PM=$(command -v dnf || command -v yum)
        "$PM" install -y -q httpd-devel gcc redhat-rpm-config >/dev/null \
            || die "$PM install httpd-devel gcc failed"
    fi
    APXS=$(command -v apxs || command -v apxs2 || true)
    [ -n "$APXS" ] || die "apxs still not found"
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
cd "$BUILD"

cat > mod_php_dummy.c <<'PHP_DUMMY_SOURCE_EOF'
/*
 * mod_php_dummy - temporary PHP kill switch for Apache httpd 2.4
 *
 * Stopgap for CVE-2026-109618 / CVE-2026-109619 (PHP core RCE) until the
 * patched PHP release is installed. Does NOT fix anything - patch PHP.
 *
 * 1. Accepts php_value, php_flag, php_admin_value and php_admin_flag
 *    (same syntax and contexts as mod_php) and ignores them,
 *    so vhost configs and .htaccess files stay valid without mod_php.
 *
 * 2. Answers every request that targets PHP with
 *    "503 Service Unavailable" + "Retry-After: 3600":
 *    - file extensions php, php3-8, phtml, phar, phps, inc
 *      (also "proxy:fcgi://.../x.php" in ProxyPassMatch-based FPM setups)
 *    - handler / content type application/x-httpd-php*
 *      (AddHandler / AddType, e.g. .html parsed as PHP)
 *    Runs in the fixups hook (APR_HOOK_REALLY_FIRST), i.e. before any
 *    handler (mod_php, mod_proxy_fcgi, default handler) - so PHP is neither
 *    executed nor its source delivered.
 *
 * Never load together with the real mod_php.
 *
 * Build & install:  apxs -c -i mod_php_dummy.c
 * License: MIT
 */

#include "httpd.h"
#include "http_config.h"
#include "http_core.h"
#include "http_request.h"
#include "http_log.h"
#include "apr_strings.h"
#include <string.h>
#include <strings.h>

APLOG_USE_MODULE(php_dummy);

#define PHP_DUMMY_MESSAGE \
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">" \
    "<title>503 Service Unavailable</title></head>" \
    "<body><h1>Waiting for CVE patch</h1>" \
    "<p>This service is temporarily disabled.</p></body></html>"

static const char *const blocked_ext[] = {
    "php", "php3", "php4", "php5", "php6", "php7", "php8",
    "phtml", "phar", "phps", "inc",
    NULL
};

/* ---------- 1. Accept and ignore mod_php directives ---------- */

static const char *php_dummy_ignore(cmd_parms *cmd, void *cfg,
                                    const char *name, const char *value)
{
    (void)cmd; (void)cfg; (void)name; (void)value;
    return NULL;
}

static const command_rec php_dummy_cmds[] = {
    AP_INIT_TAKE2("php_value",       php_dummy_ignore, NULL, OR_OPTIONS,
                  "ignored by mod_php_dummy"),
    AP_INIT_TAKE2("php_flag",        php_dummy_ignore, NULL, OR_OPTIONS,
                  "ignored by mod_php_dummy"),
    AP_INIT_TAKE2("php_admin_value", php_dummy_ignore, NULL, ACCESS_CONF | RSRC_CONF,
                  "ignored by mod_php_dummy"),
    AP_INIT_TAKE2("php_admin_flag",  php_dummy_ignore, NULL, ACCESS_CONF | RSRC_CONF,
                  "ignored by mod_php_dummy"),
    { NULL }
};

/* ---------- 2. Block PHP requests ---------- */

static int has_php_extension(const char *path)
{
    const char *base, *dot;
    int i;

    if (path == NULL)
        return 0;

    base = strrchr(path, '/');
    base = base ? base + 1 : path;

    dot = strrchr(base, '.');
    if (dot == NULL || dot[1] == '\0')
        return 0;

    for (i = 0; blocked_ext[i] != NULL; i++) {
        if (strcasecmp(dot + 1, blocked_ext[i]) == 0)
            return 1;
    }
    return 0;
}

static int is_php_type(const char *t)
{
    return t != NULL && strncasecmp(t, "application/x-httpd-php", 23) == 0;
}

static void php_dummy_set_response(request_rec *rr)
{
    apr_table_setn(rr->err_headers_out, "Retry-After", "3600");
    ap_custom_response(rr, HTTP_SERVICE_UNAVAILABLE, PHP_DUMMY_MESSAGE);
}

static int php_dummy_fixups(request_rec *r)
{
    request_rec *top = r;

    if (!has_php_extension(r->filename)
        && !is_php_type(r->handler)
        && !is_php_type(r->content_type))
        return DECLINED;

    /* For subrequests (e.g. DirectoryIndex index.php via mod_dir) the error
     * is returned by the main request - set the response there as well. */
    php_dummy_set_response(r);
    while (top->main != NULL)
        top = top->main;
    if (top != r)
        php_dummy_set_response(top);

    ap_log_rerror(APLOG_MARK, APLOG_INFO, 0, r,
                  "php_dummy: blocked %s (file=%s)",
                  r->uri, r->filename ? r->filename : "-");

    return HTTP_SERVICE_UNAVAILABLE;
}

static void php_dummy_register_hooks(apr_pool_t *p)
{
    (void)p;
    ap_hook_fixups(php_dummy_fixups, NULL, NULL, APR_HOOK_REALLY_FIRST);
}

/* ---------- Module ---------- */

module AP_MODULE_DECLARE_DATA php_dummy_module = {
    STANDARD20_MODULE_STUFF,
    NULL,                       /* create per-dir config */
    NULL,                       /* merge per-dir config */
    NULL,                       /* create per-server config */
    NULL,                       /* merge per-server config */
    php_dummy_cmds,             /* directives */
    php_dummy_register_hooks    /* register hooks */
#ifdef AP_MODULE_FLAG_NONE
    , AP_MODULE_FLAG_NONE       /* flags */
#endif
};
PHP_DUMMY_SOURCE_EOF

cat > cve-php-block.conf <<'PHP_DUMMY_CONF_EOF'
# Fallback: deny PHP files if mod_php_dummy is NOT loaded.
# Inactive while mod_php_dummy is loaded (the module answers with 503 instead).
#
# Limitations of this fallback on its own (verified in testing):
#  - does NOT catch AddType/AddHandler mappings (e.g. .html parsed as PHP)
#    -> without mod_php those files are delivered as plain-text source!
#  - does NOT catch FPM setups using ProxyPassMatch (PHP still executes)
# Use mod_php_dummy wherever possible.

<IfModule !php_dummy_module>
    <FilesMatch "\.(php\d?|phar|phtml|phps|inc)$">
        Require all denied
    </FilesMatch>
</IfModule>
PHP_DUMMY_CONF_EOF

log "building mod_php_dummy with $APXS ..."
"$APXS" -c mod_php_dummy.c >build.log 2>&1 || { cat build.log >&2; die "build failed"; }
"$APXS" -i mod_php_dummy.la >>build.log 2>&1 || { cat build.log >&2; die "module install failed"; }
MODDIR=$("$APXS" -q LIBEXECDIR 2>/dev/null || echo "$MODDIR")
SO="$MODDIR/mod_php_dummy.so"
[ -f "$SO" ] || die "mod_php_dummy.so not found in $MODDIR after install"

mkdir -p "$STATE_DIR"
: > "$STATE_DIR/php_mods"; : > "$STATE_DIR/php_confs"; : > "$STATE_DIR/fpm_services"
echo "$SO" > "$STATE_DIR/so_path"

rollback() {
    warn "rolling back ..."
    if [ "$FAMILY" = debian ]; then
        a2dismod -q php_dummy >/dev/null 2>&1 || true
        a2disconf -q cve-php-block >/dev/null 2>&1 || true
        while read -r m; do [ -n "$m" ] && a2enmod -q "$m" >/dev/null 2>&1; done < "$STATE_DIR/php_mods"
        while read -r c; do [ -n "$c" ] && a2enconf -q "$c" >/dev/null 2>&1; done < "$STATE_DIR/php_confs"
    else
        rm -f /etc/httpd/conf.modules.d/99-php_dummy.conf /etc/httpd/conf.d/cve-php-block.conf
        for f in /etc/httpd/conf.modules.d/*.conf; do
            grep -q "^$MARK" "$f" 2>/dev/null && sed -i "s/^$MARK//" "$f"
        done
    fi
    rm -rf "$STATE_DIR"
}

if [ "$FAMILY" = debian ]; then
    echo "LoadModule php_dummy_module $SO" > /etc/apache2/mods-available/php_dummy.load
    cp cve-php-block.conf /etc/apache2/conf-available/cve-php-block.conf
    for f in /etc/apache2/mods-enabled/php*.load; do
        [ -e "$f" ] || continue
        m=$(basename "$f" .load)
        [ "$m" = php_dummy ] && continue
        echo "$m" >> "$STATE_DIR/php_mods"
        a2dismod -q "$m" >/dev/null 2>&1 && log "disabled mod_php: $m"
    done
    for f in /etc/apache2/conf-enabled/php*-fpm.conf; do
        [ -e "$f" ] || continue
        c=$(basename "$f" .conf)
        echo "$c" >> "$STATE_DIR/php_confs"
        a2disconf -q "$c" >/dev/null 2>&1 && log "disabled FPM conf: $c"
    done
    a2enmod -q php_dummy >/dev/null
    a2enconf -q cve-php-block >/dev/null
else
    for f in /etc/httpd/conf.modules.d/*.conf; do
        [ -e "$f" ] || continue
        if grep -Eq '^[[:space:]]*LoadModule[[:space:]]+php[0-9]*_module' "$f"; then
            sed -i -E "s/^([[:space:]]*LoadModule[[:space:]]+php[0-9]*_module)/$MARK\1/" "$f"
            log "disabled mod_php in $f"
        fi
    done
    echo "LoadModule php_dummy_module $SO" > /etc/httpd/conf.modules.d/99-php_dummy.conf
    cp cve-php-block.conf /etc/httpd/conf.d/cve-php-block.conf
fi

if ! configtest; then
    "$APACHECTL" configtest 2>&1 | tail -5 >&2 || true
    rollback
    die "configtest failed - all changes rolled back, Apache untouched"
fi
reload
module_loaded || { rollback; configtest && reload; die "module not active after reload - rolled back"; }
log "mod_php_dummy active - PHP requests now answer 503 'Waiting for CVE patch'"

if [ "${KEEP_FPM:-0}" != 1 ]; then
    for s in $(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
               | awk '{print $1}' | grep -E '^php.*fpm.*\.service$' || true); do
        systemctl stop "$s" && echo "$s" >> "$STATE_DIR/fpm_services" && log "stopped $s"
    done
fi

log "done. Verify:  curl -sI https://<your-host>/index.php | head -1   (expected: 503)"
log "after patching PHP:  ... | sudo sh -s -- --uninstall"
