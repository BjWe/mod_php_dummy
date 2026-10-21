# mod_php_dummy – temporary PHP kill switch for Apache httpd 2.4

[![CI](https://github.com/BjWe/mod_php_dummy/actions/workflows/ci.yml/badge.svg)](https://github.com/BjWe/mod_php_dummy/actions/workflows/ci.yml)

Stopgap for **CVE-2026-109618 / CVE-2026-109619** (critical PHP core RCE, CVSS v4.0 9.2).
The PHP project ships the fix on **2026-10-21, 14:00 UTC** ([php.net announcement](https://www.php.net/archive/2026.php#2026-10-20-1)).

Takes PHP offline on Apache hosts **until the patched PHP release is installed** – without taking down the
non-PHP sites on the same server and without hunting down every PHP application first.

> ⚠️ This is **not a fix**. Patch PHP as soon as the release is out, then uninstall.
> PHP 5.x / 7.x / 8.0 / 8.1 will not get a fix – upgrade or keep those hosts isolated.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh
```

Status and removal after patching:

```bash
curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh -s -- --status
curl -fsSL https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh | sudo sh -s -- --uninstall
```

Prefer to read before you run (you should):

```bash
curl -fsSLO https://raw.githubusercontent.com/BjWe/mod_php_dummy/v1.0.0/install.sh
sha256sum install.sh        # compare with install.sh.sha256 on the release page
less install.sh
sudo sh install.sh
```

The URL is pinned to the release tag, so the script you reviewed is the script that runs.

### What the installer does

Debian/Ubuntu and RHEL family (Rocky, Alma, RHEL):

- installs `apache2-dev` / `httpd-devel` + `gcc` if `apxs` is missing (`NO_DEPS=1` to skip)
- builds the module from the source embedded in `install.sh` (CI guarantees it is identical to `src/mod_php_dummy.c`)
- disables `mod_php` and `php*-fpm` confs, enables `mod_php_dummy` + `cve-php-block.conf`
- runs `apachectl configtest` – **on failure every change is rolled back** and Apache is left untouched
- reloads Apache and stops running `php*-fpm` services (`KEEP_FPM=1` to keep them)
- records every change in `/var/lib/mod_php_dummy`, so `--uninstall` restores the previous state exactly
- is idempotent – running it twice does nothing

## What it does

`mod_php_dummy` replaces `mod_php` while PHP must not run:

| | |
|---|---|
| `php_value`, `php_flag`, `php_admin_value`, `php_admin_flag` | accepted and ignored → vhost configs and `.htaccess` stay valid |
| Requests to `*.php`, `.php3–8`, `.phtml`, `.phar`, `.phps`, `.inc` | **503** + `Retry-After: 3600` + "Waiting for CVE patch" page |
| Files mapped to PHP via `AddType`/`AddHandler` (e.g. `.html`) | **503** – no source code disclosure |
| PHP-FPM via `SetHandler proxy:…` **and** `ProxyPassMatch` | **503** – blocked before the request reaches FPM |
| Everything else (static files, reverse proxies, other apps) | untouched |

The check runs in the `fixups` hook with `APR_HOOK_REALLY_FIRST`, i.e. before any content handler,
and also covers internal rewrites (front controllers) and `DirectoryIndex index.php`.

### Why not just `a2dismod php` + `FilesMatch … Require all denied`?

A plain `FilesMatch` deny **misses two cases** (verified):

- `AddType application/x-httpd-php .html` → with mod_php disabled, Apache serves the **PHP source as plain text** (credentials!)
- FPM wired via `ProxyPassMatch` → `FilesMatch` does not apply, **PHP still executes**

And without mod_php, any `php_admin_value` in a vhost makes `apachectl configtest` fail, any `php_value` in `.htaccess` returns 500.
`conf/cve-php-block.conf` is therefore only a fallback that is active when the module is **not** loaded.

## Repository layout

| Path | Purpose |
|---|---|
| `install.sh` | one-shot installer / uninstaller – **generated**, do not edit |
| `src/mod_php_dummy.c` | the module |
| `conf/php_dummy.load` | LoadModule line (Debian/Ubuntu `mods-available`) |
| `conf/cve-php-block.conf` | fallback `FilesMatch` deny, only active without the module |
| `tools/install.sh.in` | installer template |
| `tools/build-installer.sh` | regenerates `install.sh` (embeds src + conf) |
| `tests/smoke.sh` | end-to-end test used by CI |

## Manual install – Debian / Ubuntu

```bash
apt install apache2-dev
apxs -c -i src/mod_php_dummy.c
cp conf/php_dummy.load     /etc/apache2/mods-available/
cp conf/cve-php-block.conf /etc/apache2/conf-available/

ls /etc/apache2/mods-enabled/ | grep -i php      # find your mod_php, e.g. php8.2
a2dismod php8.2                                  # if mod_php is used
a2enmod php_dummy
a2enconf cve-php-block
apachectl configtest && systemctl reload apache2
systemctl stop 'php*-fpm'                        # defense in depth
```

## Manual install – RHEL / Alma / Rocky

```bash
dnf install httpd-devel gcc redhat-rpm-config
apxs -c -i src/mod_php_dummy.c
echo 'LoadModule php_dummy_module modules/mod_php_dummy.so' > /etc/httpd/conf.modules.d/99-php_dummy.conf
cp conf/cve-php-block.conf /etc/httpd/conf.d/
# if mod_php is loaded: comment out its LoadModule line in /etc/httpd/conf.modules.d/*php*.conf
apachectl configtest && systemctl reload httpd
systemctl stop php-fpm
```

## Verify

```bash
apachectl -M | grep -i php                              # expected: php_dummy_module only
curl -sI https://your.host/index.php | head -1          # expected: 503
curl -s  https://your.host/ | grep -c "Waiting for CVE"
curl -sI https://your.host/some/static.css | head -1    # expected: 200
```

Optional logging of blocked requests: `LogLevel warn php_dummy:info` (only valid while the module is loaded).

## After patching

Installed via `install.sh`: run it with `--uninstall`, then `php -v` on every host.

Manual rollback (Debian/Ubuntu):

```bash
a2dismod php_dummy && a2disconf cve-php-block
a2enmod php8.x                 # or: a2enconf php8.x-fpm && systemctl start php8.x-fpm
apachectl configtest && systemctl reload apache2
php -v
```

## Notes & limitations

- **Never load together with the real `mod_php`.**
- Only covers PHP served through **Apache**. nginx/Caddy + FPM, `php -S`, PHP-CLI cron jobs etc. are not affected by the module
  (the installer does stop running `php*-fpm` services unless `KEEP_FPM=1`).
- Reverse-proxy paths that end in `.php` (Apache in front of a *remote* PHP server) are blocked as well.
- With `DirectoryIndex index.php index.html`, a directory that also has `index.html` falls back to it.
- `.inc` is blocked on purpose (often PHP includes with credentials).
- CI runs the full install → verify → uninstall cycle on Debian 12, Ubuntu 22.04/24.04 (mod_php) and Rocky/Alma 9 (php-fpm).
  Still: run the verify step on your own hosts.

## Contributing

Edit `src/`, `conf/` or `tools/install.sh.in`, then run `sh tools/build-installer.sh` and commit the regenerated `install.sh`.

## License

MIT – no warranty. Use at your own risk.
