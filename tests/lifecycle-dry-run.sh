#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise lifecycle argument parsing and detection without a real GLPI host.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/glpi/bin" "$sandbox/glpi/inc"
touch "$sandbox/glpi/bin/console"
printf "<?php define('GLPI_VERSION', '10.0.19');\n" > "$sandbox/glpi/inc/define.php"
sed "s|^INSTALL_DIR=/var/www/glpi$|INSTALL_DIR=$sandbox/glpi|" \
    glpi-installer.sh > "$sandbox/installer.sh"

bash "$sandbox/installer.sh" --upgrade --glpi-version 11.0.1 --dry-run >/dev/null
bash "$sandbox/installer.sh" --uninstall --dry-run >/dev/null
bash "$sandbox/installer.sh" --uninstall --purge-data \
    --confirm-purge DELETE-GLPI-DATA --dry-run >/dev/null

# Neither the existing installation nor a new backup may be touched.
test -f "$sandbox/glpi/bin/console"
test -f "$sandbox/glpi/inc/define.php"

if bash "$sandbox/installer.sh" --upgrade --uninstall --dry-run >/dev/null 2>&1; then
    echo 'Mutually exclusive actions were accepted' >&2
    exit 1
fi
if bash "$sandbox/installer.sh" --uninstall --purge-db --dry-run >/dev/null 2>&1; then
    echo 'Database purge without data purge was accepted' >&2
    exit 1
fi
if bash "$sandbox/installer.sh" --upgrade --purge-data --dry-run >/dev/null 2>&1; then
    echo 'Data purge on an upgrade was accepted' >&2
    exit 1
fi

echo 'Lifecycle dry-run tests passed'
