#!/bin/sh
# Generates install.sh from tools/install.sh.in by embedding
# src/mod_php_dummy.c and conf/cve-php-block.conf.
# CI fails if the committed install.sh differs from the generated one.
set -eu
cd "$(dirname "$0")/.."

awk '
    /^@MOD_PHP_DUMMY_C@$/     { while ((getline l < "src/mod_php_dummy.c") > 0) print l; next }
    /^@CVE_PHP_BLOCK_CONF@$/  { while ((getline l < "conf/cve-php-block.conf") > 0) print l; next }
    { print }
' tools/install.sh.in > install.sh

chmod +x install.sh
sh -n install.sh
echo "install.sh generated"
