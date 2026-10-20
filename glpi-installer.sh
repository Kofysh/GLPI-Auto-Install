#!/usr/bin/env bash
# GLPI Auto-Install - maintained by Kofysh
# https://github.com/Kofysh/GLPI-Auto-Install
set -Eeuo pipefail
umask 027

VERSION=5.0.0
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
    if ((status != 0)); then
        warn "Installation interrupted. Existing GLPI databases and installations were not removed."
        [[ -z "$LOG_FILE" ]] || warn "See $LOG_FILE for diagnostics (secrets are never logged)."
    fi
}
trap cleanup EXIT

help() {
    cat <<EOF
GLPI Auto-Install $VERSION - fresh Linux server deployments
Usage: sudo bash glpi-installer.sh [options]
  -y, --yes                 Non-interactive installation
  -d, --dry-run             Detect platform and show planned actions (no writes)
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

This installer never upgrades, replaces, or uninstalls existing GLPI instances.
The target must be a dedicated machine, VM, or LXC with a working init system.
EOF
}

while (($#)); do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -y|--yes) YES=true; shift ;;
        --enable-ssl) SSL=true; shift ;;
        --glpi-version|--db-name|--db-user|--db-pass|--timezone|--domain|--ssl-email)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --glpi-version) GLPI_VERSION=$2 ;;
                --db-name) DB_NAME=$2 ;;
                --db-user) DB_USER=$2 ;;
                --db-pass) DB_PASS=$2 ;;
                --timezone) TIMEZONE=$2 ;;
                --domain) DOMAIN=$2 ;;
                --ssl-email) SSL_EMAIL=$2 ;;
            esac
            shift 2 ;;
        --force|--skip-checks|--no-rollback|--uninstall|--keep-db|--keep-packages)
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
if "$SSL"; then
    [[ -n "$DOMAIN" && -n "$SSL_EMAIL" ]] || die 'SSL requires --domain and --ssl-email'
fi

version_at_least() { [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]; }

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
    version_at_least "$php_version" 8.2.0 || die "GLPI 11 needs PHP >= 8.2. Installed: $php_version. Use a supported OS/repository."
    for ext in bcmath curl dom fileinfo filter gd intl libxml mbstring mysqli openssl session simplexml tokenizer xmlreader xmlwriter zlib; do
        "$PHP_BIN" -r "exit(extension_loaded('$ext') ? 0 : 1);" || missing="$missing $ext"
    done
    [[ -z "$missing" ]] || die "Missing PHP modules:$missing"
    find_fpm
    info "PHP $php_version with required extensions, FPM service $FPM_SERVICE"
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
        [[ -t 0 ]] || die 'Non-interactive shell: pass --yes'
        printf 'Install GLPI on this dedicated %s server? [y/N] ' "$OS_ID"
        read -r answer
        [[ "$answer" == y || "$answer" == Y ]] || die 'Cancelled'
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

download_glpi() {
    TMP_DIR=$(mktemp -d)
    local archive="$TMP_DIR/glpi.tgz"
    local url="https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
    curl --fail --location --retry 3 --show-error --silent --proto '=https' --tlsv1.2 \
        "$url" -o "$archive" || die 'Failed to download official GLPI release archive'
    tar -tzf "$archive" >"$TMP_DIR/list" || die 'Invalid release archive'
    grep -q '^glpi/' "$TMP_DIR/list" || die 'Release archive has no glpi/ root folder'
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TMP_DIR/list"; then die 'Unsafe release archive member path'; fi
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
        apt-get install -y certbot python3-certbot-apache || { warn 'Certbot packages unavailable; set up TLS manually'; return 0; }
    elif [[ "$OS_FAMILY" == rhel ]]; then
        dnf install -y certbot python3-certbot-apache || { warn 'Certbot packages unavailable; set up TLS manually'; return 0; }
    else
        warn 'Automatic TLS is not available on this family; configure HTTPS with your reverse proxy or Certbot'
        return
    fi
    if ! certbot --apache --non-interactive --agree-tos --redirect -d "$DOMAIN" -m "$SSL_EMAIL"; then
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

main() {
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
    info 'A complete GLPI database upgrade and existing deployments are intentionally out of scope.'
}
main
