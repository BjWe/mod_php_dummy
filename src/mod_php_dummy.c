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
