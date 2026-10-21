#!/usr/bin/env bash
# GLPI Auto-Install - maintained by Kofysh
# https://github.com/Kofysh/GLPI-Auto-Install
set -Eeuo pipefail
umask 027

VERSION=5.2.0
MODE=install
MENU_SELECTED=false
BACKUP_RETENTION_DAYS=0
REQUIRE_HTTPS=false
ARCHIVE_SHA256=
ACK_PLUGIN_MIGRATION=false
RESTORE_SOURCE=
CONFIRM_RESTORE=
FPM_CHILDREN=8
PURGE_DATA=false
PURGE_DB=false
CONFIRM_PURGE=
CONFIRM_DB_PURGE=
ALLOW_MAJOR=false
DB_NAME_EXPLICIT=false
BACKUP_ROOT=/var/backups/glpi-installer
BACKUP_PATH=
MAINTENANCE_ON=false
CODE_SWAPPED=false
OLD_CODE_DIR=
STAGE_DIR=
INSTALL_DIR=/var/www/glpi
DATA_DIR=/var/lib/glpi
CONFIG_DIR=/etc/glpi
GLPI_LOG_DIR=/var/log/glpi
CREDENTIALS=/root/.glpi_credentials
LOG_DIR=/var/log/glpi-installer
DRY_RUN=false
YES=false
SSL=false
SSL_EMAIL=
DOMAIN=
GLPI_VERSION=
DB_NAME=glpi_db
DB_USER=glpi_user
DB_PASS=${GLPI_DB_PASSWORD:-}
TIMEZONE=Europe/Paris
OS_FAMILY=
OS_ID=
OS_VERSION=
VIRT=physical
WEB_USER=
WEB_GROUP=
WEB_SERVICE=
DB_SERVICE=mariadb
FPM_SERVICE=
FPM_POOL_DIR=
FPM_SOCKET=/run/glpi-fpm.sock
APACHE_CONF=
PHP_BIN=php
PKG_MANAGER=
LOG_FILE=
TMP_DIR=

say() {
    printf '[%s] %s\n' "$1" "$2"
    [[ -z "$LOG_FILE" ]] || printf '[%s] %s\n' "$1" "$2" >> "$LOG_FILE"
}
info() { say INFO "$*"; }
warn() { say WARN "$*" >&2; }
die() { say ERROR "$*" >&2; exit 1; }
cleanup() {
    local status=$?
    [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
    if [[ -n "$STAGE_DIR" && "$STAGE_DIR" == /var/www/.glpi-stage.* && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
    if [[ "$MODE" == upgrade && "$MAINTENANCE_ON" == true && "$CODE_SWAPPED" == false ]]; then
        warn 'Restoring normal service after an interrupted pre-migration upgrade.'
        glpi_console maintenance:disable >/dev/null 2>&1 || true
        if [[ -n "$BACKUP_PATH" && -d "$BACKUP_PATH/paused-cron" ]]; then
            resume_glpi_cron || true
        fi
    fi
    if ((status != 0)); then
        warn "The $MODE operation was interrupted; inspect the instance and backup."
        [[ -z "$BACKUP_PATH" ]] || warn "Recovery backup: $BACKUP_PATH"
        [[ -z "$LOG_FILE" ]] || warn "Diagnostic log: $LOG_FILE"
    fi
}
trap cleanup EXIT

help() {
    cat <<EOF
GLPI Auto-Install $VERSION - Linux server deployments
Usage: sudo bash glpi-installer.sh [options]
  (no arguments)           Display the interactive action menu
  -y, --yes                 Non-interactive installation
  -d, --dry-run             Detect platform and show planned actions (no writes)
  --upgrade, --update       Back up and update an existing GLPI installation
  --allow-major-upgrade     Allow GLPI 10 -> 11 migration after plugin review
  --ack-plugin-migration    Confirm GLPI 10 plugins were reviewed
  --restore PATH            Restore an installer-managed backup
  --confirm-restore TOKEN   Confirm a restore using RESTORE-GLPI
  --backup-dir PATH         Directory for local recovery archives
  --retention-days N        Prune old archives after success (1-365; opt-in)
  --require-https           Require successful automatic HTTPS
  --archive-sha256 HASH     Check an official release archive digest
  --uninstall               Back up and remove GLPI application code
  --purge-data              Also remove GLPI data and configuration
  --purge-db                Also remove local GLPI database/user
  --confirm-purge TOKEN     DELETE-GLPI-DATA (required with --purge-data)
  --confirm-db-purge TOKEN  DELETE-GLPI-DATABASE (required with --purge-db)
  --glpi-version X.Y.Z      Pin an official GLPI release
  --db-name NAME            Database name (default: glpi_db)
  --db-user USER            Database user (default: glpi_user)
  --db-pass PASSWORD        DB password (prefer GLPI_DB_PASSWORD environment variable)
  --timezone ZONE           PHP timezone (default: Europe/Paris)
  --domain NAME             FQDN for Apache virtual host
  --enable-ssl              Request Let's Encrypt TLS (requires --domain)
  --ssl-email ADDRESS       Let's Encrypt account email
  -h, --help                Show help
  --version                 Show installer version

Upgrade and removal both require verified backups. Removal preserves persistent
data and SQL by default. Supported install path: /var/www/glpi.
The target must be a dedicated machine, VM, or LXC with a working init system.
EOF
}

confirm_operation() {
    local prompt=$1 answer
    if [[ -t 0 ]]; then
        printf '%s [o/N] ' "$prompt"
        IFS= read -r answer || die 'Impossible de lire la confirmation.'
    elif [[ "$MENU_SELECTED" == true ]] && ( : </dev/tty ) 2>/dev/null; then
        printf '%s [o/N] ' "$prompt" > /dev/tty
        IFS= read -r answer < /dev/tty || die 'Impossible de lire la confirmation.'
    else
        die 'Un terminal interactif est nécessaire pour confirmer. Utilisez --yes en automatisation.'
    fi
    case "$answer" in
        o|O|oui|Oui|OUI|y|Y|yes|YES) return 0 ;;
        *) die 'Opération annulée.' ;;
    esac
}

select_operation() {
    # Read from the terminal so the menu also works with curl | sudo bash.
    if [[ ! -t 0 && ! -t 1 ]] || ! ( : </dev/tty ) 2>/dev/null; then
        die 'Interactive menu requires a terminal. Use --upgrade, --uninstall or --yes for automation.'
    fi

    printf '\n%s\n' '======================================'
    printf ' GLPI Auto-Install %s\n' "$VERSION"
    printf '%s\n' '======================================'
    printf '  1) Installer GLPI\n'
    printf '  2) Mettre à jour GLPI\n'
    printf '  3) Désinstaller GLPI\n'
    printf '  0) Quitter\n\n'

    local choice
    while true; do
        printf 'Votre choix [0-3] : ' > /dev/tty
        if ! IFS= read -r choice < /dev/tty; then
            die 'Aucune sélection reçue ; opération annulée.'
        fi
        case "$choice" in
            1) MODE=install; MENU_SELECTED=true; return 0 ;;
            2) MODE=upgrade; MENU_SELECTED=true; return 0 ;;
            3) MODE=uninstall; MENU_SELECTED=true; return 0 ;;
            0|q|Q) info 'Opération annulée.'; exit 0 ;;
            *) printf 'Choix invalide. Saisissez 0, 1, 2 ou 3.\n' > /dev/tty ;;
        esac
    done
}

ask_menu_input() {
    local question=$1 var=$2 result
    printf '%s' "$question" > /dev/tty
    IFS= read -r result < /dev/tty || die 'Entrée interrompue.'
    printf -v "$var" '%s' "$result"
}

menu_settings() {
    local answer value
    case "$MODE" in
        install)
            ask_menu_input 'Version GLPI (Entrée = dernière stable) : ' value
            [[ -z "$value" ]] || GLPI_VERSION=$value
            ask_menu_input 'Domaine DNS (Entrée = accès par IP) : ' DOMAIN
            if [[ -n "$DOMAIN" ]]; then
                ask_menu_input 'Activer HTTPS avec Let’s Encrypt ? [o/N] : ' answer
                case "$answer" in
                    o|O|oui|Oui|y|Y) SSL=true
                        ask_menu_input 'Email pour le certificat : ' SSL_EMAIL
                        REQUIRE_HTTPS=true ;;
                esac
            fi
            ;;
        upgrade)
            ask_menu_input 'Version cible (Entrée = dernière stable) : ' value
            [[ -z "$value" ]] || GLPI_VERSION=$value
            ask_menu_input 'Autoriser une migration majeure 10 vers 11 ? [o/N] : ' answer
            case "$answer" in o|O|oui|Oui|y|Y) ALLOW_MAJOR=true ;; esac
            ;;
        uninstall)
            printf 'Par défaut la base SQL, les fichiers et la configuration sont conservés.\n'
            ask_menu_input 'Supprimer aussi la configuration et les données ? [o/N] : ' answer
            case "$answer" in
                o|O|oui|Oui|y|Y)
                    ask_menu_input 'Saisir DELETE-GLPI-DATA pour confirmer : ' CONFIRM_PURGE
                    [[ "$CONFIRM_PURGE" == DELETE-GLPI-DATA ]] || die 'Confirmation des données incorrecte.'
                    PURGE_DATA=true
                    ask_menu_input 'Supprimer aussi la base SQL et son utilisateur ? [o/N] : ' answer
                    case "$answer" in
                        o|O|oui|Oui|y|Y)
                            ask_menu_input 'Saisir DELETE-GLPI-DATABASE pour confirmer : ' CONFIRM_DB_PURGE
                            [[ "$CONFIRM_DB_PURGE" == DELETE-GLPI-DATABASE ]] || die 'Confirmation SQL incorrecte.'
                            PURGE_DB=true ;;
                    esac ;;
            esac
            ;;
    esac
}

if (($# == 0)); then
    select_operation
    menu_settings
fi

while (($#)); do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        --upgrade|--update) [[ "$MODE" == install ]] || die 'Choose one operation'; MODE=upgrade; shift ;;
        --uninstall) [[ "$MODE" == install ]] || die 'Choose one operation'; MODE=uninstall; shift ;;
        --allow-major-upgrade) ALLOW_MAJOR=true; shift ;;
        --ack-plugin-migration) ACK_PLUGIN_MIGRATION=true; shift ;;
        --require-https) REQUIRE_HTTPS=true; shift ;;
        --restore|--confirm-restore|--backup-dir|--retention-days|--archive-sha256)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --restore) [[ "$MODE" == install ]] || die 'Choose only one operation'; MODE=restore; RESTORE_SOURCE=$2 ;;
                --confirm-restore) CONFIRM_RESTORE=$2 ;;
                --backup-dir) BACKUP_ROOT=$2 ;;
                --retention-days) BACKUP_RETENTION_DAYS=$2 ;;
                --archive-sha256) ARCHIVE_SHA256=$2 ;;
            esac
            shift 2 ;;
        --purge-data) PURGE_DATA=true; shift ;;
        --purge-db) PURGE_DB=true; shift ;;
        --confirm-purge|--confirm-db-purge)
            (($# >= 2)) || die "Missing value for $1"
            if [[ "$1" == --confirm-purge ]]; then CONFIRM_PURGE=$2; else CONFIRM_DB_PURGE=$2; fi
            shift 2 ;;
        -y|--yes) YES=true; shift ;;
        --enable-ssl) SSL=true; shift ;;
        --glpi-version|--db-name|--db-user|--db-pass|--timezone|--domain|--ssl-email)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --glpi-version) GLPI_VERSION=$2 ;;
                --db-name) DB_NAME=$2; DB_NAME_EXPLICIT=true ;;
                --db-user) DB_USER=$2 ;;
                --db-pass) DB_PASS=$2 ;;
                --timezone) TIMEZONE=$2 ;;
                --domain) DOMAIN=$2 ;;
                --ssl-email) SSL_EMAIL=$2 ;;
            esac
            shift 2 ;;
        --force|--skip-checks|--no-rollback|--keep-db|--keep-packages)
            die "The legacy option $1 is not supported: unsafe overrides/uninstall were removed. See --help." ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || die 'Invalid database name'
[[ "$DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,31}$ ]] || die 'Invalid database username'
[[ -z "$DB_PASS" || "$DB_PASS" =~ ^[a-zA-Z0-9._~!@#%+=:-]{12,128}$ ]] || die 'Invalid DB password (12-128 characters; avoid SQL quote and shell-sensitive characters)'
[[ -z "$GLPI_VERSION" || "$GLPI_VERSION" =~ ^(10|11)\.[0-9]+\.[0-9]+$ ]] || die 'Expected GLPI version 10.x.y or 11.x.y'
[[ "$TIMEZONE" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die 'Invalid timezone'
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die 'Invalid domain'
[[ -z "$SSL_EMAIL" || "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Invalid SSL email'
[[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != / && "$BACKUP_ROOT" != /var && "$BACKUP_ROOT" != /var/www* ]] ||
    die 'Backups must use an absolute directory outside /var/www'
[[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( BACKUP_RETENTION_DAYS <= 365 )) ||
    die 'Retention must be a number from 0 (disabled) to 365'
[[ -z "$ARCHIVE_SHA256" || "$ARCHIVE_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die 'Expected a SHA-256 digest'
[[ "$MODE" != restore || "$CONFIRM_RESTORE" == RESTORE-GLPI ]] ||
    die 'Restoration requires --confirm-restore RESTORE-GLPI'
[[ "$ACK_PLUGIN_MIGRATION" == false || "$MODE" == upgrade ]] || die '--ack-plugin-migration requires --upgrade'
[[ "$REQUIRE_HTTPS" == false || ( "$MODE" == install && "$SSL" == true ) ]] ||
    die '--require-https requires a fresh installation with --enable-ssl'
[[ "$PURGE_DB" == false || "$PURGE_DATA" == true ]] || die '--purge-db requires --purge-data'
if [[ "$MODE" != uninstall && ( "$PURGE_DATA" == true || "$PURGE_DB" == true ) ]]; then
    die '--purge-data and --purge-db require --uninstall'
fi
if [[ "$MODE" != upgrade && "$ALLOW_MAJOR" == true ]]; then
    die '--allow-major-upgrade requires --upgrade'
fi
if "$SSL"; then
    [[ -n "$DOMAIN" && -n "$SSL_EMAIL" ]] || die 'SSL requires --domain and --ssl-email'
fi

version_at_least() {
    # BusyBox sort on Alpine has no portable version-sort option.
    awk -v actual="$1" -v required="$2" 'BEGIN {
        split(actual, a, "."); split(required, b, ".");
        for (i = 1; i <= 4; i++) {
            x = a[i] + 0; y = b[i] + 0;
            if (x > y) exit 0;
            if (x < y) exit 1;
        }
        exit 0
    }'
}

platform() {
    [[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release'
    # OS identification uses distro metadata, not guessed release files.
    . /etc/os-release
    OS_ID=${ID,,}
    OS_VERSION=${VERSION_ID:-unknown}
    local ancestor=" ${ID_LIKE:-} "
    case "$OS_ID" in
        debian|ubuntu) OS_FAMILY=debian ;;
        rhel|rocky|almalinux|ol|centos|fedora) OS_FAMILY=rhel ;;
        opensuse-leap|opensuse-tumbleweed|sles|sled) OS_FAMILY=suse ;;
        alpine) OS_FAMILY=alpine ;;
        *)
            case "$ancestor" in
                *debian*) OS_FAMILY=debian ;;
                *rhel*|*fedora*) OS_FAMILY=rhel ;;
                *suse*) OS_FAMILY=suse ;;
                *) die "Unsupported distribution: $OS_ID. Supported families: Debian, RHEL, SUSE, Alpine." ;;
            esac ;;
    esac
    case "$OS_FAMILY" in
        debian)
            PKG_MANAGER=apt-get; WEB_USER=www-data; WEB_GROUP=www-data
            WEB_SERVICE=apache2; APACHE_CONF=/etc/apache2/sites-available/000-0-glpi.conf
            ;;
        rhel)
            PKG_MANAGER=dnf; WEB_USER=apache; WEB_GROUP=apache
            WEB_SERVICE=httpd; APACHE_CONF=/etc/httpd/conf.d/00-glpi.conf
            ;;
        suse)
            PKG_MANAGER=zypper; WEB_USER=wwwrun; WEB_GROUP=www
            WEB_SERVICE=apache2; APACHE_CONF=/etc/apache2/vhosts.d/00-glpi.conf
            ;;
        alpine)
            PKG_MANAGER=apk; WEB_USER=apache; WEB_GROUP=apache
            WEB_SERVICE=apache2; APACHE_CONF=/etc/apache2/conf.d/00-glpi.conf
            ;;
    esac
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt 2>/dev/null || printf physical)
    elif [[ -r /run/systemd/container ]]; then
        VIRT=$(cat /run/systemd/container)
    elif [[ -e /.dockerenv ]]; then
        VIRT=docker
    elif [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ | grep -q '^container=lxc$'; then
        VIRT=lxc
    fi
    info "System: $OS_ID $OS_VERSION | family: $OS_FAMILY | virtualization: $VIRT"
    [[ "$VIRT" != docker && "$VIRT" != podman ]] || die 'OCI containers are not supported: use a dedicated GLPI container image instead.'
}

packages() {
    local -a items=()
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            "$PKG_MANAGER" update -qq
            items=(apache2 mariadb-server mariadb-client php-cli php-fpm php-mysql php-gd
                   php-curl php-mbstring php-xml php-intl php-bcmath php-zip php-ldap
                   php-opcache ca-certificates curl tar openssl cron)
            "$PKG_MANAGER" install -y "${items[@]}" ;;
        rhel)
            # RHEL 9 and its clones default to PHP 8.0; use the vendor's PHP 8.2 stream.
            if [[ "$OS_ID" != fedora && "${OS_VERSION%%.*}" == 9 ]]; then
                "$PKG_MANAGER" module enable -y php:8.2 || die 'Could not enable the PHP 8.2 AppStream module. Check repositories and existing PHP modules.'
            fi
            items=(httpd mariadb-server mariadb php php-cli php-fpm php-mysqlnd php-gd
                   php-mbstring php-xml php-intl php-bcmath php-opcache php-ldap
                   ca-certificates curl tar openssl cronie policycoreutils-python-utils)
            "$PKG_MANAGER" install -y "${items[@]}" ;;
        suse)
            items=(apache2 mariadb mariadb-client php8 php8-fpm php8-mysql php8-gd
                   php8-curl php8-mbstring php8-intl php8-bcmath php8-zip php8-opcache
                   ca-certificates curl tar openssl cron)
            "$PKG_MANAGER" --non-interactive install --no-recommends "${items[@]}" ;;
        alpine)
            # Alpine PHP packages use a versioned suffix; select the newest available major.
            local n=""
            for n in 84 83 82; do apk search -e "php${n}-fpm" 2>/dev/null | grep -q "^php${n}-fpm" && break; done
            apk search -e "php${n}-fpm" 2>/dev/null | grep -q "^php${n}-fpm" || die 'No supported PHP-FPM package in enabled Alpine repositories'
            PHP_BIN="php${n}"
            FPM_SERVICE="php-fpm${n}"
            FPM_POOL_DIR="/etc/php${n}/php-fpm.d"
            items=(apache2 mariadb mariadb-client "php${n}" "php${n}-fpm" "php${n}-mysqli"
                   "php${n}-gd" "php${n}-curl" "php${n}-mbstring" "php${n}-xml"
                   "php${n}-intl" "php${n}-bcmath" "php${n}-session" "php${n}-fileinfo"
                   "php${n}-openssl" "php${n}-dom" "php${n}-simplexml"
                   "php${n}-xmlreader" "php${n}-xmlwriter" "php${n}-tokenizer"
                   ca-certificates curl tar openssl openrc)
            apk add --no-cache "${items[@]}" ;;
    esac
}

service_action() {
    local action=$1 name=$2
    if [[ "$OS_FAMILY" == alpine ]]; then
        command -v rc-service >/dev/null || die 'OpenRC is not available'
        if [[ "$action" == enable ]]; then rc-update add "$name" default; else rc-service "$name" "$action"; fi
    else
        [[ -d /run/systemd/system ]] || die 'systemd is not running. Enable systemd in the LXC/VM before installation.'
        systemctl "$action" "$name"
    fi
}

find_fpm() {
    if [[ "$OS_FAMILY" == alpine ]]; then
        [[ -d "$FPM_POOL_DIR" ]] || die "PHP-FPM pool directory not found: $FPM_POOL_DIR"
        return
    fi
    local candidate
    local native_php_version
    native_php_version=$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')
    for candidate in "/etc/php/$native_php_version/fpm/pool.d" /etc/php-fpm.d /etc/php8/fpm/php-fpm.d /etc/php8/fpm/pool.d; do
        if [[ -d "$candidate" ]]; then FPM_POOL_DIR=$candidate; break; fi
    done
    [[ -n "$FPM_POOL_DIR" ]] || die 'Could not locate PHP-FPM pool configuration'
    if [[ "$OS_FAMILY" == debian ]]; then
        FPM_SOCKET=/run/php/glpi-fpm.sock
        FPM_SERVICE="php$($PHP_BIN -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')-fpm"
    elif [[ "$OS_FAMILY" == suse ]]; then FPM_SERVICE=php-fpm
    else FPM_SERVICE=php-fpm; FPM_SOCKET=/run/php-fpm/glpi-fpm.sock
    fi
}

check_runtime() {
    if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
        if command -v php8 >/dev/null 2>&1; then PHP_BIN=php8; else die 'PHP CLI unavailable'; fi
    fi
    local php_version missing="" ext
    php_version=$($PHP_BIN -r 'echo PHP_VERSION;')
    local minimum_php=8.2.0
    if [[ "$GLPI_VERSION" == 10.* ]]; then minimum_php=7.4.0; fi
    version_at_least "$php_version" "$minimum_php" ||
        die "GLPI $GLPI_VERSION requires PHP >= $minimum_php. Installed: $php_version."
    for ext in bcmath curl dom fileinfo filter gd intl libxml mbstring mysqli openssl session simplexml tokenizer xmlreader xmlwriter zlib; do
        "$PHP_BIN" -r "exit(extension_loaded('$ext') ? 0 : 1);" || missing="$missing $ext"
    done
    [[ -z "$missing" ]] || die "Missing PHP modules:$missing"
    if [[ "$MODE" == install ]]; then find_fpm; fi
    info "PHP $php_version with required extensions"
    command -v mariadb >/dev/null || command -v mysql >/dev/null || die 'MariaDB client not found'
}

db_cli() { if command -v mariadb >/dev/null; then mariadb "$@"; else mysql "$@"; fi; }

check_database_version() {
    local installed
    installed=$(db_cli --batch --skip-column-names -e 'SELECT VERSION()') || die 'Local MariaDB/MySQL root socket authentication failed'
    local numeric=${installed%%-*}
    if [[ "$installed" == *MariaDB* ]]; then
        version_at_least "$numeric" 10.5.0 || die "MariaDB $installed is too old (minimum 10.5)"
    else
        version_at_least "$numeric" 8.0.0 || die "MySQL $installed is too old (minimum 8.0)"
    fi
    info "Database engine: $installed"
}

preflight() {
    [[ $EUID -eq 0 || "$DRY_RUN" == true ]] || die 'Run as root (sudo)'
    [[ ! -e "$INSTALL_DIR" && ! -e "$CONFIG_DIR" && ! -e "$DATA_DIR" ]] || die "GLPI already exists; upgrades/reinstallations are intentionally blocked: $INSTALL_DIR"
    [[ ! -e "$CREDENTIALS" ]] || die "Existing installer credentials found at $CREDENTIALS; refusing to replace"
    case "$OS_ID" in
        debian) version_at_least "$OS_VERSION" 12 || die 'Debian 12+ is required for GLPI 11 without third-party PHP repositories' ;;
        ubuntu) version_at_least "$OS_VERSION" 24.04 || die 'Ubuntu 24.04 LTS+ is required for GLPI 11 without third-party PHP repositories' ;;
        rhel|rocky|almalinux|ol|centos) version_at_least "$OS_VERSION" 9 || die 'RHEL-compatible version 9+ is required' ;;
        alpine) version_at_least "$OS_VERSION" 3.20 || die 'Alpine 3.20+ is required' ;;
    esac
    if [[ "$OS_FAMILY" != alpine && "$OS_FAMILY" != suse ]]; then
        info 'Platform tier: Debian/RHEL family (managed packages)'
    else
        warn 'Platform tier: Alpine/SUSE; package availability and PHP-FPM service names vary by release. Verify on staging first.'
    fi
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: would install Apache + PHP-FPM + MariaDB + GLPI ${GLPI_VERSION:-latest}"
        info "DRY RUN: install at $INSTALL_DIR; database $DB_NAME; Apache config $APACHE_CONF"
        info 'DRY RUN: no packages, services, files, databases or firewall rules changed'
        exit 0
    fi
    local mem disk
    mem=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)
    # LXC can expose host MemTotal; prefer its actual cgroup memory limit.
    local cgroup_bytes=""
    if [[ -r /sys/fs/cgroup/memory.max ]]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory.max)
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    fi
    if [[ "$cgroup_bytes" =~ ^[0-9]+$ ]] && (( cgroup_bytes > 0 )); then
        local cgroup_megabytes=$((cgroup_bytes / 1024 / 1024))
        if (( cgroup_megabytes < mem )); then mem=$cgroup_megabytes; fi
    fi
    disk=$(df -Pk /var | awk 'NR==2{print $4}')
    ((mem >= 1024)) || die "Insufficient RAM: ${mem} MiB (minimum 1024 MiB)"
    ((disk >= 4*1024*1024)) || die 'Need at least 4 GiB of free space on /var'
    [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"
    command -v curl >/dev/null || die 'curl is required (install curl first)'
    command -v tar >/dev/null || die 'tar is required (install tar first)'
    if [[ "$YES" == false ]]; then
        confirm_operation "Installer GLPI sur ce serveur $OS_ID ?"
    fi
}

latest_release() {
    if [[ -z "$GLPI_VERSION" ]]; then
        info 'Fetching current stable GLPI release'
        local response
        response=$(curl --fail --silent --show-error --location --retry 3 --max-time 30 \
            https://api.github.com/repos/glpi-project/glpi/releases/latest) || die 'GitHub release API unavailable'
        GLPI_VERSION=$(printf '%s' "$response" | awk -F '"' '/"tag_name"/ {print $4; exit}')
        [[ "$GLPI_VERSION" =~ ^(10|11)\.[0-9]+\.[0-9]+$ ]] || die 'Unexpected GLPI release tag'
    fi
    info "GLPI version selected: $GLPI_VERSION"
}

configure_database() {
    service_action enable "$DB_SERVICE"
    if [[ "$OS_FAMILY" == alpine && ! -d /var/lib/mysql/mysql ]]; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
    fi
    service_action start "$DB_SERVICE"
    check_database_version
    local exists
    exists=$(db_cli --batch --skip-column-names -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'" || true)
    [[ -z "$exists" ]] || die "Database $DB_NAME already exists: refusing to alter it"
    exists=$(db_cli --batch --skip-column-names -e "SELECT User FROM mysql.user WHERE User='$DB_USER' AND Host='localhost'" || true)
    [[ -z "$exists" ]] || die "Database user $DB_USER@localhost already exists: refusing to alter it"
    [[ -n "$DB_PASS" ]] || DB_PASS=$(openssl rand -hex 24)
    db_cli <<SQL
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
SQL
    # If installation fails later, preserve the database for inspection/recovery.
    info "Created new database $DB_NAME with dedicated user"
}

verify_release_archive() {
    local archive=$1
    if [[ -n "$ARCHIVE_SHA256" ]]; then
        local measured
        measured=$(sha256sum "$archive" | awk '{print $1}')
        [[ "${measured,,}" == "${ARCHIVE_SHA256,,}" ]] ||
            die 'GLPI release digest differs from the expected SHA-256; refusing extraction'
        info 'Official release archive SHA-256 verified'
    else
        warn 'Release fetched over HTTPS, but no pinned SHA-256 was provided'
    fi
    local entries
    entries=$(tar -tzf "$archive") || die 'Invalid GLPI release archive'
    if grep -E -v '^glpi(/|$)' <<< "$entries" | grep -q .; then
        die 'Unexpected path outside the GLPI archive root'
    fi
    if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$entries"; then
        die 'Unsafe GLPI archive member path'
    fi
}

download_glpi() {
    TMP_DIR=$(mktemp -d)
    local archive="$TMP_DIR/glpi.tgz"
    local url="https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
    curl --fail --location --retry 3 --show-error --silent --proto '=https' --tlsv1.2 \
        "$url" -o "$archive" || die 'Failed to download official GLPI release archive'
    verify_release_archive "$archive"
    mkdir -p /var/www
    tar -xzf "$archive" --no-same-owner -C /var/www
    [[ -f "$INSTALL_DIR/bin/console" && -d "$INSTALL_DIR/public" ]] || die 'Extracted GLPI layout not recognized'
}

configure_glpi() {
    mkdir -p "$DATA_DIR/files" "$DATA_DIR/marketplace" "$GLPI_LOG_DIR" "$CONFIG_DIR"
    # Move bundled writable directories away from the HTTP document root.
    local folder target
    for folder in files marketplace config; do
        case "$folder" in files) target="$DATA_DIR/files" ;; marketplace) target="$DATA_DIR/marketplace" ;; config) target="$CONFIG_DIR" ;; esac
        if [[ -d "$INSTALL_DIR/$folder" ]]; then
            cp -a "$INSTALL_DIR/$folder/." "$target/"
            rm -rf -- "${INSTALL_DIR:?}/$folder"
        fi
    done
    cat > "$INSTALL_DIR/inc/downstream.php" <<'PHP'
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
PHP
    cat > "$CONFIG_DIR/local_define.php" <<'PHP'
<?php
define('GLPI_VAR_DIR', '/var/lib/glpi/files');
define('GLPI_MARKETPLACE_DIR', '/var/lib/glpi/marketplace');
define('GLPI_LOG_DIR', '/var/log/glpi');
PHP
    chown -R root:root "$INSTALL_DIR"
    find "$INSTALL_DIR" -type d -exec chmod 755 {} +
    find "$INSTALL_DIR" -type f -exec chmod 644 {} +
    chown -R "$WEB_USER:$WEB_GROUP" "$DATA_DIR" "$GLPI_LOG_DIR" "$CONFIG_DIR"
    chmod -R u+rwX,g+rX,o-rwx "$DATA_DIR" "$GLPI_LOG_DIR" "$CONFIG_DIR"
    chmod 2770 "$DATA_DIR" "$GLPI_LOG_DIR" "$CONFIG_DIR"
    # GLPI must write its DB config during the web-based initial setup.
    chmod g+w "$CONFIG_DIR"
    if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
        if command -v semanage >/dev/null && command -v restorecon >/dev/null; then
            local path
            for path in "$DATA_DIR" "$GLPI_LOG_DIR" "$CONFIG_DIR"; do
                semanage fcontext -a -t httpd_sys_rw_content_t "${path}(/.*)?" 2>/dev/null || true
                restorecon -RF "$path"
            done
            semanage fcontext -a -t httpd_var_run_t "$FPM_SOCKET" 2>/dev/null || true
        else
            die 'SELinux enforcing: install semanage/restorecon tools, then retry'
        fi
    fi
}

configure_fpm() {
    mkdir -p "$FPM_POOL_DIR" "$(dirname "$FPM_SOCKET")"
    cat > "$FPM_POOL_DIR/glpi.conf" <<EOF
[glpi]
user = $WEB_USER
group = $WEB_GROUP
listen = $FPM_SOCKET
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = dynamic
pm.max_children = 8
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 70M
php_admin_value[max_execution_time] = 300
php_admin_value[date.timezone] = $TIMEZONE
php_admin_flag[session.cookie_httponly] = on
EOF
    service_action enable "$FPM_SERVICE"
    service_action restart "$FPM_SERVICE" || service_action start "$FPM_SERVICE"
    [[ -S "$FPM_SOCKET" ]] || die "PHP-FPM socket not found: $FPM_SOCKET"
    if command -v restorecon >/dev/null && command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
        restorecon -v "$FPM_SOCKET"
    fi
}

configure_apache() {
    mkdir -p "$(dirname "$APACHE_CONF")"
    local server_name=${DOMAIN:-localhost}
    cat > "$APACHE_CONF" <<EOF
<VirtualHost *:80>
    ServerName $server_name
    DocumentRoot $INSTALL_DIR/public
    <Directory $INSTALL_DIR/public>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
        <FilesMatch "\\.php$">
            SetHandler "proxy:unix:$FPM_SOCKET|fcgi://localhost/"
        </FilesMatch>
    </Directory>
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF
    case "$OS_FAMILY" in
        debian)
            a2enmod rewrite headers proxy proxy_fcgi >/dev/null
            a2ensite "$(basename "$APACHE_CONF")" >/dev/null ;;
        rhel)
            # RHEL's standard modules load from /etc/httpd/conf.modules.d.
            : ;;
        suse)
            a2enmod rewrite headers proxy proxy_fcgi >/dev/null || die 'Enable Apache rewrite/headers/proxy_fcgi modules manually' ;;
        alpine)
            # Alpine ships LoadModule statements in /etc/apache2/httpd.conf.
            sed -i -E 's/^#(LoadModule (rewrite_module|headers_module|proxy_module|proxy_fcgi_module) )/\1/' /etc/apache2/httpd.conf ;;
    esac
    if command -v apache2ctl >/dev/null; then apache2ctl configtest
    else httpd -t; fi
    service_action enable "$WEB_SERVICE"
    service_action restart "$WEB_SERVICE" || service_action start "$WEB_SERVICE"
}

configure_cron() {
    if [[ "$OS_FAMILY" == alpine ]]; then
        mkdir -p /etc/periodic/15min
        cat > /etc/periodic/15min/glpi <<EOF
#!/bin/sh
cd '$INSTALL_DIR' && su '$WEB_USER' -s /bin/sh -c '$PHP_BIN $INSTALL_DIR/front/cron.php' >/dev/null 2>&1
EOF
        chmod 750 /etc/periodic/15min/glpi
        service_action enable crond
        service_action start crond
    else
        cat > /etc/cron.d/glpi <<EOF
0-59/2 * * * * $WEB_USER $PHP_BIN $INSTALL_DIR/front/cron.php >/dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/glpi
        local cron_service
        cron_service=$( [[ "$OS_FAMILY" == rhel ]] && echo crond || echo cron )
        service_action enable "$cron_service" || warn 'Could not enable cron service'
        service_action start "$cron_service" || warn 'Could not start cron service'
    fi
}

configure_tls() {
    "$SSL" || return 0
    if [[ "$OS_FAMILY" == debian ]]; then
        apt-get install -y certbot python3-certbot-apache || { if [[ "$REQUIRE_HTTPS" == true ]]; then die 'Certbot is required but unavailable'; fi; warn 'Certbot packages unavailable'; return 0; }
    elif [[ "$OS_FAMILY" == rhel ]]; then
        dnf install -y certbot python3-certbot-apache || { warn 'Certbot packages unavailable; set up TLS manually'; return 0; }
    else
        if [[ "$REQUIRE_HTTPS" == true ]]; then die 'Automatic HTTPS is unavailable on this platform'; fi
        warn 'Automatic TLS is not available on this family; configure HTTPS with your reverse proxy or Certbot'
        return
    fi
    if ! certbot --apache --non-interactive --agree-tos --redirect -d "$DOMAIN" -m "$SSL_EMAIL"; then
        if [[ "$REQUIRE_HTTPS" == true ]]; then
            die 'TLS is required but certificate issuance failed. Do not expose this site until HTTPS works.'
        fi
        warn 'Certbot failed. HTTP is still available; configure TLS before exposing GLPI publicly.'
    fi
}

save_credentials() {
    (umask 077; cat > "$CREDENTIALS" <<EOF
# GLPI database credentials - keep private (root only)
URL=http://${DOMAIN:-localhost}/
VERSION=$GLPI_VERSION
DB_HOST=localhost
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
EOF
    )
    chmod 600 "$CREDENTIALS"
}

read_credential() {
    local key=$1
    [[ -f "$CREDENTIALS" && ! -L "$CREDENTIALS" ]] || return 0
    awk -v key="$key" 'index($0, key "=") == 1 {print substr($0, length(key) + 2); exit}' "$CREDENTIALS"
}

identify_existing() {
    [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" && -f "$INSTALL_DIR/bin/console" ]] ||
        die "GLPI not found at $INSTALL_DIR (bin/console missing)"
    [[ -f "$INSTALL_DIR/inc/define.php" ]] || die 'Missing GLPI version file'
    local path
    for path in "$DATA_DIR" "$CONFIG_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/files" \
                "$INSTALL_DIR/marketplace" "$INSTALL_DIR/plugins"; do
        [[ ! -L "$path" ]] || die "Symlinked GLPI directory: $path. Handle this layout manually."
    done
}

load_existing_database() {
    local saved_name saved_user saved_host
    saved_name=$(read_credential DB_NAME)
    saved_user=$(read_credential DB_USER)
    saved_host=$(read_credential DB_HOST)
    if [[ -n "$saved_name" ]]; then
        if [[ "$DB_NAME_EXPLICIT" == true && "$DB_NAME" != "$saved_name" ]]; then
            die "Specified database differs from $CREDENTIALS"
        fi
        DB_NAME=$saved_name
        DB_USER=${saved_user:-$DB_USER}
    elif [[ "$DB_NAME_EXPLICIT" != true ]]; then
        die "Supply --db-name for a legacy installation without $CREDENTIALS"
    fi
    [[ "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || die 'Invalid saved database name'
    [[ "$DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,31}$ ]] || die 'Invalid saved database user'
    [[ -z "$saved_host" || "$saved_host" == localhost || "$saved_host" == 127.0.0.1 ]] ||
        die "Remote SQL host ($saved_host) requires a manual backup"
    command -v mariadb-dump >/dev/null 2>&1 || command -v mysqldump >/dev/null 2>&1 ||
        die 'Install mariadb-dump or mysqldump before continuing'
    db_cli --batch --skip-column-names -e \
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'" |
        grep -Fxq "$DB_NAME" || die "Cannot access local database $DB_NAME"
}

existing_version() {
    grep 'GLPI_VERSION' "$INSTALL_DIR/inc/define.php" |
        grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

glpi_console() {
    local subcommand=$1
    shift
    if command -v runuser >/dev/null 2>&1; then
        (cd "$INSTALL_DIR" && runuser -u "$WEB_USER" -- "$PHP_BIN" bin/console "$subcommand" --no-interaction "$@")
    else
        (cd "$INSTALL_DIR" && su -s /bin/sh "$WEB_USER" -c \
            "'$PHP_BIN' bin/console '$subcommand' --no-interaction")
    fi
}

backup_existing() {
    local operation=$1 stamp path dump
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP_PATH="$BACKUP_ROOT/${operation}_${stamp}_${BASHPID}"
    mkdir -p "$BACKUP_PATH"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_PATH"
    local -a paths=()
    for path in "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$GLPI_LOG_DIR" "$CREDENTIALS" \
                "$APACHE_CONF" /etc/apache2/sites-available/glpi.conf \
                /etc/cron.d/glpi /etc/periodic/15min/glpi; do
        if [[ -e "$path" || -L "$path" ]]; then paths+=("${path#/}"); fi
    done
    ((${#paths[@]} > 0)) || die 'Nothing found to back up'
    info 'Backing up GLPI files, configuration and persistent data'
    tar -C / -czf "$BACKUP_PATH/files.tar.gz" -- "${paths[@]}" ||
        die 'File backup failed; installation was not modified'
    [[ -s "$BACKUP_PATH/files.tar.gz" ]] || die 'Empty file backup'
    if command -v mariadb-dump >/dev/null 2>&1; then dump=mariadb-dump; else dump=mysqldump; fi
    info "Backing up SQL database $DB_NAME"
    "$dump" --single-transaction --quick --routines --events --triggers \
        --databases "$DB_NAME" | gzip -1 > "$BACKUP_PATH/database.sql.gz" ||
        die 'SQL backup failed; installation was not modified'
    [[ -s "$BACKUP_PATH/database.sql.gz" ]] || die 'Empty SQL backup'
    gzip -t "$BACKUP_PATH/database.sql.gz" || die 'Corrupted SQL backup'
    (cd "$BACKUP_PATH" && sha256sum files.tar.gz database.sql.gz > SHA256SUMS &&
        sha256sum -c SHA256SUMS >/dev/null) || die 'Backup verification failed'
    printf 'Operation=%s\nDatabase=%s\nSource=%s\nCreated=%s\n' \
        "$operation" "$DB_NAME" "$INSTALL_DIR" "$stamp" > "$BACKUP_PATH/manifest.txt"
    chmod 600 "$BACKUP_PATH"/*

    info "Backup verified: $BACKUP_PATH"
}

pause_glpi_cron() {
    local path destination
    for path in /etc/cron.d/glpi /etc/periodic/15min/glpi; do
        if [[ -f "$path" ]] && grep -Fq "$INSTALL_DIR" "$path"; then
            mkdir -p "$BACKUP_PATH/paused-cron"
            destination="$BACKUP_PATH/paused-cron/$(basename "$(dirname "$path")")-$(basename "$path")"
            mv "$path" "$destination"
        fi
    done
}

resume_glpi_cron() {
    local path copy
    for path in /etc/cron.d/glpi /etc/periodic/15min/glpi; do
        copy="$BACKUP_PATH/paused-cron/$(basename "$(dirname "$path")")-$(basename "$path")"
        [[ ! -f "$copy" ]] || mv "$copy" "$path"
    done
}

download_upgrade_release() {
    STAGE_DIR=$(mktemp -d /var/www/.glpi-stage.XXXXXXXX)
    chmod 700 "$STAGE_DIR"
    local url="https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
    curl --fail --location --retry 3 --show-error --silent --proto '=https' --tlsv1.2 \
        "$url" -o "$STAGE_DIR/release.tgz" || die 'Could not download official release'
    verify_release_archive "$STAGE_DIR/release.tgz"
    tar -xzf "$STAGE_DIR/release.tgz" --no-same-owner -C "$STAGE_DIR"
    [[ -f "$STAGE_DIR/glpi/bin/console" && -d "$STAGE_DIR/glpi/public" ]] ||
        die 'Incomplete release archive'
}

restore_application_files() {
    local folder
    for folder in config files plugins marketplace; do
        if [[ -d "$OLD_CODE_DIR/$folder" ]]; then
            mkdir -p "$INSTALL_DIR/$folder"
            cp -a "$OLD_CODE_DIR/$folder/." "$INSTALL_DIR/$folder/"
        fi
    done
    if [[ -f "$OLD_CODE_DIR/inc/downstream.php" ]]; then
        cp -a "$OLD_CODE_DIR/inc/downstream.php" "$INSTALL_DIR/inc/downstream.php"
    fi
    chown -R root:root "$INSTALL_DIR"
    find "$INSTALL_DIR" -type d -exec chmod 755 {} +
    find "$INSTALL_DIR" -type f -exec chmod 644 {} +
    for folder in config files plugins marketplace; do
        if [[ -d "$INSTALL_DIR/$folder" ]]; then
            chown -R "$WEB_USER:$WEB_GROUP" "$INSTALL_DIR/$folder"
        fi
    done
}

upgrade_existing() {
    local current_version current_major target_major
    current_version=$(existing_version)
    [[ -n "$current_version" ]] || die 'Cannot determine current GLPI version'
    latest_release
    version_at_least "$GLPI_VERSION" "$current_version" ||
        die "Downgrades are not supported ($current_version -> $GLPI_VERSION)"
    if [[ "$GLPI_VERSION" == "$current_version" ]]; then
        info "GLPI $current_version is already up to date"
        return 0
    fi
    current_major=${current_version%%.*}
    target_major=${GLPI_VERSION%%.*}
    if [[ "$current_major" != "$target_major" && "$ALLOW_MAJOR" != true ]]; then
        die "Major upgrade ($current_version -> $GLPI_VERSION) requires --allow-major-upgrade"
    fi
    info "GLPI upgrade: $current_version -> $GLPI_VERSION"
    check_runtime
    check_database_version
    download_upgrade_release
    if [[ "$YES" == false ]]; then
        confirm_operation "Mettre à jour GLPI vers $GLPI_VERSION après sauvegarde ?"
    fi
    glpi_console maintenance:enable || die 'Could not enable GLPI maintenance'
    MAINTENANCE_ON=true
    backup_existing upgrade
    pause_glpi_cron
    OLD_CODE_DIR="/var/www/.glpi-previous-${BASHPID}-$(date +%s)"
    mv "$INSTALL_DIR" "$OLD_CODE_DIR"
    chmod 700 "$OLD_CODE_DIR"
    CODE_SWAPPED=true
    mv "$STAGE_DIR/glpi" "$INSTALL_DIR"
    restore_application_files
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "$INSTALL_DIR" || warn 'SELinux contexts may need manual restoration'
    fi
    info 'Applying GLPI database schema migrations'
    if ! glpi_console db:update; then
        die "Schema migration failed. Maintenance stays on; restore SQL and code together using $BACKUP_PATH"
    fi
    if ! glpi_console maintenance:disable; then
        die 'Migration finished, but maintenance could not be disabled. Check GLPI manually.'
    fi
    MAINTENANCE_ON=false
    resume_glpi_cron
    rm -rf -- "${OLD_CODE_DIR:?}"
    OLD_CODE_DIR=
    info "GLPI $GLPI_VERSION successfully installed"
    info "Restore point: $BACKUP_PATH"
    warn 'Review plugin compatibility. GLPI 11 may require manual plugin migrations.'
}

remove_owned_integration() {
    local path
    for path in "$APACHE_CONF" /etc/apache2/sites-available/glpi.conf \
                /etc/apache2/sites-available/000-0-glpi.conf /etc/httpd/conf.d/00-glpi.conf \
                /etc/apache2/vhosts.d/00-glpi.conf /etc/apache2/conf.d/00-glpi.conf; do
        if [[ -f "$path" ]] && grep -Fq "$INSTALL_DIR" "$path"; then
            if [[ "$OS_FAMILY" == debian ]] && command -v a2dissite >/dev/null; then
                a2dissite "$(basename "$path")" >/dev/null 2>&1 || true
            fi
            rm -f -- "$path"
        fi
    done
    for path in /etc/cron.d/glpi /etc/periodic/15min/glpi; do
        if [[ -f "$path" ]] && grep -Fq "$INSTALL_DIR" "$path"; then rm -f -- "$path"; fi
    done
    # Remove only the named GLPI pool (never the system default PHP-FPM pool).
    for path in /etc/php-fpm.d/glpi.conf /etc/php8/fpm/php-fpm.d/glpi.conf; do
        if [[ -f "$path" ]] && grep -Fq '[glpi]' "$path"; then rm -f -- "$path"; fi
    done
    if [[ -d /etc/php ]]; then
        while IFS= read -r path; do
            if grep -Fq '[glpi]' "$path"; then rm -f -- "$path"; fi
        done < <(find /etc/php -type f -name glpi.conf)
    fi
    if command -v apache2ctl >/dev/null; then
        if apache2ctl configtest >/dev/null 2>&1; then
            service_action reload "$WEB_SERVICE" || warn 'Apache reload failed'
        else
            warn 'Apache configuration test failed; inspect other virtual hosts'
        fi
    elif command -v httpd >/dev/null; then
        if httpd -t >/dev/null 2>&1; then
            service_action reload "$WEB_SERVICE" || warn 'Apache reload failed'
        fi
    fi
}

uninstall_existing() {
    if [[ "$PURGE_DATA" == true && "$CONFIRM_PURGE" != DELETE-GLPI-DATA ]]; then
        die 'Data removal also requires --confirm-purge DELETE-GLPI-DATA'
    fi
    if [[ "$PURGE_DB" == true && "$CONFIRM_DB_PURGE" != DELETE-GLPI-DATABASE ]]; then
        die 'SQL removal also requires --confirm-db-purge DELETE-GLPI-DATABASE'
    fi
    if [[ "$PURGE_DB" == true && ! -f "$CREDENTIALS" ]]; then
        die "Dropping SQL requires original credentials metadata: $CREDENTIALS"
    fi
    if [[ "$YES" == false ]]; then
        confirm_operation 'Désinstaller GLPI après sauvegarde des fichiers et de la base ?'
    fi
    backup_existing uninstall
    pause_glpi_cron
    if [[ "$PURGE_DB" == true ]]; then
        db_cli -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" ||
            die "Cannot drop database $DB_NAME; application unchanged"
        db_cli -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" ||
            die "Cannot drop database user $DB_USER; application unchanged"
        info "Removed local SQL database $DB_NAME and its dedicated user"
    fi
    remove_owned_integration
    rm -rf -- "${INSTALL_DIR:?}"
    if [[ "$PURGE_DATA" == true ]]; then
        rm -rf -- "${DATA_DIR:?}" "${CONFIG_DIR:?}" "${GLPI_LOG_DIR:?}"
        rm -f -- "$CREDENTIALS"
    fi
    info 'GLPI code and managed integration files removed; Apache/PHP/MariaDB packages untouched'
    [[ "$PURGE_DATA" == true ]] || info 'Persistent data, credentials and SQL were retained'
    info "Verified recovery archive: $BACKUP_PATH"
}

lifecycle_main() {
    platform
    [[ $EUID -eq 0 || "$DRY_RUN" == true ]] || die 'Run as root'
    identify_existing
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$MODE" == uninstall ]]; then
            info "DRY RUN: would back up GLPI and remove $INSTALL_DIR"
            info "DRY RUN: remove persistent files: $PURGE_DATA; remove database: $PURGE_DB"
        else
            info "DRY RUN: would back up GLPI, install ${GLPI_VERSION:-latest}, and run db:update"
        fi
        info 'DRY RUN: no disk, database or service changes'
        return 0
    fi
    command -v tar >/dev/null || die 'tar is needed for backups'
    command -v gzip >/dev/null || die 'gzip is needed for backups'
    command -v sha256sum >/dev/null || die 'sha256sum is needed for backup verification'
    command -v curl >/dev/null || die 'curl is needed for upgrades'
    [[ -t 0 || "$YES" == true || "$MENU_SELECTED" == true ]] ||
        die 'Noninteractive operation requires --yes'
    load_existing_database
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${MODE}_$(date -u +%Y%m%dT%H%M%SZ).log"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    if [[ "$MODE" == upgrade ]]; then upgrade_existing; else uninstall_existing; fi
}

main() {
    if [[ "$MODE" != install ]]; then
        lifecycle_main
        return
    fi
    platform
    preflight
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    # Do not pipe xtrace, SQL/passwords, or credentials to the log.
    info 'Installing distribution packages'
    packages
    check_runtime
    latest_release
    configure_database
    download_glpi
    configure_glpi
    configure_fpm
    configure_apache
    configure_cron
    save_credentials
    configure_tls
    info "Installation files ready: $INSTALL_DIR"
    info "Open http://${DOMAIN:-YOUR_SERVER_IP}/ and complete the GLPI web installation wizard."
    info "Credentials: $CREDENTIALS (mode 0600). Change the default GLPI account passwords."
    warn 'Configure HTTPS and restrict network access before exposing GLPI to the internet.'
    info 'For upgrades and removal, use --upgrade or --uninstall.'
}
main
