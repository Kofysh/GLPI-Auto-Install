#!/usr/bin/env bash
set -Eeuo pipefail

# No installation or database operation is executed in these checks.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fails() {
    if bash glpi-installer.sh "$@" >/dev/null 2>&1; then
        printf 'Unexpectedly accepted unsafe options: %s\n' "$*" >&2
        exit 1
    fi
}

fails --restore /tmp/old --dry-run
fails --retention-days 999 --dry-run
fails --backup-dir /var/www/glpi/backups --dry-run
fails --require-https --dry-run
fails --ack-plugin-migration --dry-run
fails --archive-sha256 invalid --dry-run
fails --purge-db --dry-run

bash glpi-installer.sh --upgrade --dry-run --ack-plugin-migration >/dev/null 2>&1 &&
    { echo 'An upgrade dry-run needs a fake instance or should fail' >&2; exit 1; } || :

# Source function definitions without invoking main or requiring root privileges.
sed '/^main$/d' glpi-installer.sh > "$sandbox/functions.sh"
bash -c 'source "$1" --dry-run; version_at_least 3.21 3.20 && ! version_at_least 3.20 3.21'     _ "$sandbox/functions.sh"

mkdir -p "$sandbox/glpi"
printf 'example\n' > "$sandbox/glpi/index.php"
tar -czf "$sandbox/release.tgz" -C "$sandbox" glpi
digest=$(sha256sum "$sandbox/release.tgz" | awk '{print $1}')
bash -c 'source "$1" --dry-run --archive-sha256 "$2"; verify_release_archive "$3"'     _ "$sandbox/functions.sh" "$digest" "$sandbox/release.tgz"
if bash -c 'source "$1" --dry-run --archive-sha256 "$2"; verify_release_archive "$3"'     _ "$sandbox/functions.sh" "$(printf '0%.0s' {1..64})" "$sandbox/release.tgz" >/dev/null 2>&1; then
    echo 'Archive verification accepted an incorrect checksum' >&2
    exit 1
fi
echo 'Safety regression checks passed'
