#!/usr/bin/env bash

#===============================================================================
#
#   GLPI Auto-Installer v4.0
#   Optimized for Debian 10/11/12/13 and Ubuntu 20.04/22.04/24.04
#
#   Author: Kofysh
#   GitHub: https://github.com/Kofysh/GLPI-Auto-Install
#
#===============================================================================

set -Eeo pipefail

#-------------------------------------------------------------------------------
# VARIABLES
#-------------------------------------------------------------------------------

SCRIPT_NAME="${BASH_SOURCE[0]:-glpi-installer.sh}"
readonly SCRIPT_NAME
readonly SCRIPT_NAME_BASE="$(basename "${SCRIPT_NAME}")"
readonly SCRIPT_VERSION="4.0.0"
readonly SCRIPT_PID=$$
readonly START_TIME=$(date +%s)

readonly LOG_DIR="/var/log/glpi-installer"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/var/run/glpi-installer.lock"
readonly BACKUP_DIR="/var/backups/glpi-installer"

readonly GLPI_INSTALL_DIR="/var/www/glpi"
readonly GLPI_VAR_DIR="/var/lib/glpi"
readonly GLPI_LOG_DIR="/var/log/glpi"
readonly GLPI_CONFIG_DIR="/etc/glpi"

readonly MIN_MEMORY_MB=512
readonly MIN_DISK_GB=2

declare -A CONFIG=(
    [GLPI_VERSION]=""
    [GLPI_DOWNLOAD_URL]=""
    [DB_NAME]="glpi_db"
    [DB_USER]="glpi_user"
    [DB_PASS]=""
    [DB_HOST]="localhost"
    [TIMEZONE]="Europe/Paris"
    [INSTALL_DIR]="${GLPI_INSTALL_DIR}"
    [DOMAIN]=""
)

declare -A SYSTEM=(
    [OS_NAME]=""
    [OS_VERSION]=""
    [OS_PRETTY_NAME]=""
    [PHP_VERSION]=""
    [TOTAL_MEMORY_MB]=0
    [AVAILABLE_DISK_GB]=0
    [IP_ADDRESS]=""
)

declare VERBOSE=false
declare DRY_RUN=false
declare FORCE=false
declare UNATTENDED=false
declare UNINSTALL_MODE=false
declare KEEP_DATABASE=false
declare KEEP_PACKAGES=false

# Colors
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BG_RED='\033[41m'

#-------------------------------------------------------------------------------
# LOGGING FUNCTIONS
#-------------------------------------------------------------------------------

init_logging() {
    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
    chmod 640 "${LOG_FILE}" 2>/dev/null || true
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    local prefix=""
    
    case "${level}" in
        DEBUG)   color="${C_DIM}";    prefix="[DEBUG]" ;;
        INFO)    color="${C_BLUE}";   prefix="[INFO] " ;;
        SUCCESS) color="${C_GREEN}";  prefix="[OK]   " ;;
        WARN)    color="${C_YELLOW}"; prefix="[WARN] " ;;
        ERROR)   color="${C_RED}";    prefix="[ERROR]" ;;
        FATAL)   color="${C_BG_RED}"; prefix="[FATAL]" ;;
    esac
    
    [[ "${level}" == "DEBUG" && "${VERBOSE}" != "true" ]] && return
    
    echo -e "${color}${prefix}${C_RESET} ${message}"
    echo "[${timestamp}] ${prefix} ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

debug()   { log DEBUG "$@"; }
info()    { log INFO "$@"; }
success() { log SUCCESS "$@"; }
warn()    { log WARN "$@"; }
error()   { log ERROR "$@"; }

fatal() {
    log FATAL "$@"
    rm -f "${LOCK_FILE}" 2>/dev/null || true
    exit 1
}

#-------------------------------------------------------------------------------
# UI FUNCTIONS
#-------------------------------------------------------------------------------

print_banner() {
    echo -e "${C_CYAN}"
    cat << 'BANNER'

   ██████╗ ██╗     ██████╗ ██╗    ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗ 
  ██╔════╝ ██║     ██╔══██╗██║    ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗
  ██║  ███╗██║     ██████╔╝██║    ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝
  ██║   ██║██║     ██╔═══╝ ██║    ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗
  ╚██████╔╝███████╗██║     ██║    ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║
   ╚═════╝ ╚══════╝╚═╝     ╚═╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝

                                 Auto-Installer v4.0 | By Kofysh

BANNER
    echo -e "${C_RESET}"
}

print_step() {
    local step_num="$1"
    local total="$2"
    local title="$3"
    local width=70
    local line=$(printf '═%.0s' $(seq 1 $width))
    
    echo ""
    echo -e "${C_CYAN}╔${line}╗${C_RESET}"
    printf "${C_CYAN}║${C_RESET} ${C_BOLD}[%02d/%02d]${C_RESET} %-$((width-10))s ${C_CYAN}║${C_RESET}\n" "${step_num}" "${total}" "${title}"
    echo -e "${C_CYAN}╚${line}╝${C_RESET}"
    echo ""
}

confirm() {
    local message="${1:-Continue?}"
    local default="${2:-n}"
    
    [[ "${UNATTENDED}" == "true" ]] && { [[ "${default}" =~ ^[Yy]$ ]] && return 0 || return 1; }
    [[ ! -t 0 ]] && { [[ "${default}" =~ ^[Yy]$ ]] && return 0 || return 1; }
    
    local prompt
    [[ "${default}" =~ ^[Yy]$ ]] && prompt="[Y/n]" || prompt="[y/N]"
    
    while true; do
        read -rp "  ${C_YELLOW}?${C_RESET} ${message} ${prompt}: " answer </dev/tty 2>/dev/null || answer="${default}"
        answer="${answer:-$default}"
        case "${answer}" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer yes or no." ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# SYSTEM FUNCTIONS
#-------------------------------------------------------------------------------

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        fatal "This script must be run as root. Use: sudo ${SCRIPT_NAME_BASE}"
    fi
}

acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local old_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            fatal "Another installation is already running (PID: ${old_pid})"
        fi
        rm -f "${LOCK_FILE}" 2>/dev/null || true
    fi
    echo "${SCRIPT_PID}" > "${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}" 2>/dev/null || true
}

cleanup() {
    local exit_code=$?
    release_lock
    if [[ ${exit_code} -ne 0 ]]; then
        error "Installation failed. Check log: ${LOG_FILE}"
    fi
    local duration=$(($(date +%s) - START_TIME))
    info "Total execution time: $((duration / 60))m $((duration % 60))s"
}

trap cleanup EXIT

check_network() {
    info "Checking network connectivity..."
    
    if curl -s --connect-timeout 10 -o /dev/null "https://github.com" </dev/null 2>/dev/null; then
        success "Network connectivity verified"
        return 0
    fi
    
    if curl -s --connect-timeout 10 -o /dev/null "https://api.github.com" </dev/null 2>/dev/null; then
        success "Network connectivity verified"
        return 0
    fi
    
    if ping -c 1 -W 5 8.8.8.8 </dev/null &>/dev/null; then
        success "Network connectivity verified"
        return 0
    fi
    
    fatal "No network connectivity. Please check your internet connection."
}

detect_system() {
    print_step 1 10 "System Detection"
    
    if [[ ! -f /etc/os-release ]]; then
        fatal "Cannot detect OS: /etc/os-release not found"
    fi
    
    source /etc/os-release
    
    SYSTEM[OS_NAME]="${ID}"
    SYSTEM[OS_VERSION]="${VERSION_ID}"
    SYSTEM[OS_PRETTY_NAME]="${PRETTY_NAME}"
    
    # Check if Debian or Ubuntu
    if [[ "${ID}" != "debian" && "${ID}" != "ubuntu" ]]; then
        fatal "This script only supports Debian and Ubuntu. Detected: ${ID}"
    fi
    
    # Determine PHP version based on OS
    case "${ID}" in
        debian)
            case "${VERSION_ID}" in
                10) SYSTEM[PHP_VERSION]="7.3" ;;
                11) SYSTEM[PHP_VERSION]="7.4" ;;
                12) SYSTEM[PHP_VERSION]="8.2" ;;
                13) SYSTEM[PHP_VERSION]="8.4" ;;
                *)  SYSTEM[PHP_VERSION]="8.2" ;;
            esac
            ;;
        ubuntu)
            case "${VERSION_ID}" in
                20.04) SYSTEM[PHP_VERSION]="7.4" ;;
                22.04) SYSTEM[PHP_VERSION]="8.1" ;;
                24.04) SYSTEM[PHP_VERSION]="8.3" ;;
                *)     SYSTEM[PHP_VERSION]="8.1" ;;
            esac
            ;;
    esac
    
    SYSTEM[TOTAL_MEMORY_MB]=$(free -m | awk '/^Mem:/{print $2}')
    SYSTEM[AVAILABLE_DISK_GB]=$(df -BG / | awk 'NR==2{print int($4)}')
    SYSTEM[IP_ADDRESS]=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    
    success "Detected: ${SYSTEM[OS_PRETTY_NAME]}"
    info "  ├─ PHP Version: ${SYSTEM[PHP_VERSION]}"
    info "  ├─ Memory: ${SYSTEM[TOTAL_MEMORY_MB]} MB"
    info "  ├─ Available Disk: ${SYSTEM[AVAILABLE_DISK_GB]} GB"
    info "  └─ IP Address: ${SYSTEM[IP_ADDRESS]}"
}

check_requirements() {
    print_step 2 10 "Requirements Check"
    
    local errors=0
    
    info "Checking memory..."
    if [[ ${SYSTEM[TOTAL_MEMORY_MB]} -lt ${MIN_MEMORY_MB} ]]; then
        error "Insufficient memory: ${SYSTEM[TOTAL_MEMORY_MB]}MB < ${MIN_MEMORY_MB}MB required"
        errors=$((errors + 1))
    else
        success "Memory: ${SYSTEM[TOTAL_MEMORY_MB]}MB OK"
    fi
    
    info "Checking disk space..."
    if [[ ${SYSTEM[AVAILABLE_DISK_GB]} -lt ${MIN_DISK_GB} ]]; then
        error "Insufficient disk: ${SYSTEM[AVAILABLE_DISK_GB]}GB < ${MIN_DISK_GB}GB required"
        errors=$((errors + 1))
    else
        success "Disk space: ${SYSTEM[AVAILABLE_DISK_GB]}GB OK"
    fi
    
    if [[ ${errors} -gt 0 && "${FORCE}" != "true" ]]; then
        fatal "Requirements check failed with ${errors} error(s). Use --force to override."
    fi
    
    success "All requirements verified"
}

#-------------------------------------------------------------------------------
# GLPI FUNCTIONS
#-------------------------------------------------------------------------------

fetch_latest_version() {
    print_step 3 10 "Fetching Latest GLPI Version"
    
    info "Querying GitHub API..."
    
    local api_response
    local retry=0
    local max_retries=3
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        api_response=$(curl -sS --connect-timeout 15 --max-time 30 \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/glpi-project/glpi/releases/latest" </dev/null 2>&1) && break
        retry=$((retry + 1))
        warn "API request failed, retrying (${retry}/${max_retries})..."
        sleep 3
    done
    
    if [[ ${retry} -eq ${max_retries} ]]; then
        fatal "Failed to fetch GLPI version from GitHub API"
    fi
    
    CONFIG[GLPI_VERSION]=$(echo "${api_response}" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    
    if [[ -z "${CONFIG[GLPI_VERSION]}" ]]; then
        fatal "Could not parse GLPI version from API response"
    fi
    
    CONFIG[GLPI_DOWNLOAD_URL]="https://github.com/glpi-project/glpi/releases/download/${CONFIG[GLPI_VERSION]}/glpi-${CONFIG[GLPI_VERSION]}.tgz"
    
    success "Latest version: ${CONFIG[GLPI_VERSION]}"
}

install_packages() {
    print_step 4 10 "Installing Packages"
    
    info "Updating package repositories..."
    apt-get update -qq
    
    info "Installing Apache, MariaDB, and utilities..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2 \
        mariadb-server \
        mariadb-client \
        curl \
        wget \
        tar \
        bzip2 \
        unzip \
        cron \
        ca-certificates \
        gnupg
    
    info "Installing PHP ${SYSTEM[PHP_VERSION]} and extensions..."
    
    local php_packages=(
        "php${SYSTEM[PHP_VERSION]}"
        "php${SYSTEM[PHP_VERSION]}-fpm"
        "php${SYSTEM[PHP_VERSION]}-mysql"
        "php${SYSTEM[PHP_VERSION]}-ldap"
        "php${SYSTEM[PHP_VERSION]}-imap"
        "php${SYSTEM[PHP_VERSION]}-curl"
        "php${SYSTEM[PHP_VERSION]}-gd"
        "php${SYSTEM[PHP_VERSION]}-mbstring"
        "php${SYSTEM[PHP_VERSION]}-xml"
        "php${SYSTEM[PHP_VERSION]}-intl"
        "php${SYSTEM[PHP_VERSION]}-zip"
        "php${SYSTEM[PHP_VERSION]}-bz2"
        "php${SYSTEM[PHP_VERSION]}-opcache"
        "php${SYSTEM[PHP_VERSION]}-cli"
        "php${SYSTEM[PHP_VERSION]}-bcmath"
        "libapache2-mod-php${SYSTEM[PHP_VERSION]}"
    )
    
    for pkg in "${php_packages[@]}"; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" 2>/dev/null || {
            warn "Package ${pkg} not available, skipping..."
        }
    done
    
    # Optional packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "php${SYSTEM[PHP_VERSION]}-redis" \
        "php${SYSTEM[PHP_VERSION]}-apcu" 2>/dev/null || true
    
    success "All packages installed"
}

configure_php() {
    print_step 5 10 "Configuring PHP"
    
    local php_ini="/etc/php/${SYSTEM[PHP_VERSION]}/apache2/php.ini"
    
    if [[ ! -f "${php_ini}" ]]; then
        php_ini="/etc/php/${SYSTEM[PHP_VERSION]}/fpm/php.ini"
    fi
    
    if [[ ! -f "${php_ini}" ]]; then
        warn "PHP configuration file not found, skipping..."
        return
    fi
    
    info "Configuring ${php_ini}..."
    
    # Backup
    cp "${php_ini}" "${php_ini}.backup"
    
    # Apply settings
    sed -i "s/^memory_limit.*/memory_limit = 256M/" "${php_ini}"
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 100M/" "${php_ini}"
    sed -i "s/^post_max_size.*/post_max_size = 100M/" "${php_ini}"
    sed -i "s/^max_execution_time.*/max_execution_time = 600/" "${php_ini}"
    sed -i "s/^;*max_input_vars.*/max_input_vars = 5000/" "${php_ini}"
    sed -i "s|^;*date.timezone.*|date.timezone = ${CONFIG[TIMEZONE]}|" "${php_ini}"
    sed -i "s/^;*session.cookie_httponly.*/session.cookie_httponly = On/" "${php_ini}"
    
    # Configure FPM pool
    local fpm_conf="/etc/php/${SYSTEM[PHP_VERSION]}/fpm/pool.d/www.conf"
    if [[ -f "${fpm_conf}" ]]; then
        sed -i "s/^;*request_terminate_timeout.*/request_terminate_timeout = 600/" "${fpm_conf}"
    fi
    
    success "PHP configured"
}

configure_database() {
    print_step 6 10 "Configuring Database"
    
    info "Starting MariaDB..."
    systemctl start mariadb
    systemctl enable mariadb
    
    # Generate password if not provided (only alphanumeric for compatibility)
    if [[ -z "${CONFIG[DB_PASS]}" ]]; then
        CONFIG[DB_PASS]=$(head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 20 || true)
        # Fallback if urandom fails
        if [[ -z "${CONFIG[DB_PASS]}" || ${#CONFIG[DB_PASS]} -lt 20 ]]; then
            CONFIG[DB_PASS]=$(date +%s%N | sha256sum | head -c 20)
        fi
    fi
    
    info "Creating database and user..."
    
    # Drop user if exists to ensure clean state
    mysql -e "DROP USER IF EXISTS '${CONFIG[DB_USER]}'@'localhost';" 2>/dev/null || true
    
    # Create database
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${CONFIG[DB_NAME]}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    
    # Create user with password
    mysql -e "CREATE USER '${CONFIG[DB_USER]}'@'localhost' IDENTIFIED BY '${CONFIG[DB_PASS]}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${CONFIG[DB_NAME]}\`.* TO '${CONFIG[DB_USER]}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Timezone support
    mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql mysql 2>/dev/null || true
    mysql -e "GRANT SELECT ON mysql.time_zone_name TO '${CONFIG[DB_USER]}'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;"
    
    # Verify connection
    if mysql -u"${CONFIG[DB_USER]}" -p"${CONFIG[DB_PASS]}" -e "USE ${CONFIG[DB_NAME]};" 2>/dev/null; then
        success "Database connection verified"
    else
        fatal "Database connection failed - check credentials"
    fi
    
    success "Database configured"
    info "  ├─ Database: ${CONFIG[DB_NAME]}"
    info "  ├─ User: ${CONFIG[DB_USER]}"
    info "  └─ Password: ${CONFIG[DB_PASS]}"
}

download_glpi() {
    print_step 7 10 "Downloading GLPI ${CONFIG[GLPI_VERSION]}"
    
    local temp_dir=$(mktemp -d)
    local archive="${temp_dir}/glpi.tgz"
    
    info "Downloading from GitHub..."
    
    if ! wget -q --show-progress -O "${archive}" "${CONFIG[GLPI_DOWNLOAD_URL]}"; then
        rm -rf "${temp_dir}"
        fatal "Failed to download GLPI"
    fi
    
    info "Verifying archive..."
    if ! tar -tzf "${archive}" &>/dev/null; then
        rm -rf "${temp_dir}"
        fatal "Downloaded archive is corrupted"
    fi
    
    # Backup existing installation
    if [[ -d "${CONFIG[INSTALL_DIR]}" ]]; then
        info "Backing up existing installation..."
        mv "${CONFIG[INSTALL_DIR]}" "${BACKUP_DIR}/glpi_backup_$(date +%Y%m%d_%H%M%S)"
    fi
    
    info "Extracting..."
    tar -xzf "${archive}" -C "${temp_dir}"
    mv "${temp_dir}/glpi" "${CONFIG[INSTALL_DIR]}"
    
    rm -rf "${temp_dir}"
    
    success "GLPI downloaded and extracted"
}

configure_glpi() {
    print_step 8 10 "Configuring GLPI"
    
    info "Creating directory structure..."
    
    mkdir -p "${GLPI_VAR_DIR}"/{files,marketplace}
    mkdir -p "${GLPI_VAR_DIR}/files"/{_cron,_dumps,_graphs,_lock,_pictures,_plugins,_rss,_sessions,_tmp,_uploads,_cache}
    mkdir -p "${GLPI_LOG_DIR}"
    mkdir -p "${GLPI_CONFIG_DIR}"
    
    # Move data directories
    if [[ -d "${CONFIG[INSTALL_DIR]}/files" ]]; then
        cp -rn "${CONFIG[INSTALL_DIR]}/files"/* "${GLPI_VAR_DIR}/files/" 2>/dev/null || true
        rm -rf "${CONFIG[INSTALL_DIR]}/files"
    fi
    
    if [[ -d "${CONFIG[INSTALL_DIR]}/marketplace" ]]; then
        cp -rn "${CONFIG[INSTALL_DIR]}/marketplace"/* "${GLPI_VAR_DIR}/marketplace/" 2>/dev/null || true
        rm -rf "${CONFIG[INSTALL_DIR]}/marketplace"
    fi
    
    if [[ -d "${CONFIG[INSTALL_DIR]}/config" ]]; then
        cp -rn "${CONFIG[INSTALL_DIR]}/config"/* "${GLPI_CONFIG_DIR}/" 2>/dev/null || true
        rm -rf "${CONFIG[INSTALL_DIR]}/config"
    fi
    
    info "Creating configuration files..."
    
    # downstream.php
    cat > "${CONFIG[INSTALL_DIR]}/inc/downstream.php" << 'DOWNSTREAM'
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
DOWNSTREAM

    # local_define.php
    cat > "${GLPI_CONFIG_DIR}/local_define.php" << LOCALDEFINE
<?php
define('GLPI_VAR_DIR', '${GLPI_VAR_DIR}/files');
define('GLPI_MARKETPLACE_DIR', '${GLPI_VAR_DIR}/marketplace');
define('GLPI_LOG_DIR', '${GLPI_LOG_DIR}');
define('GLPI_DOC_DIR', GLPI_VAR_DIR);
define('GLPI_CRON_DIR', GLPI_VAR_DIR . '/_cron');
define('GLPI_DUMP_DIR', GLPI_VAR_DIR . '/_dumps');
define('GLPI_GRAPH_DIR', GLPI_VAR_DIR . '/_graphs');
define('GLPI_LOCK_DIR', GLPI_VAR_DIR . '/_lock');
define('GLPI_PICTURE_DIR', GLPI_VAR_DIR . '/_pictures');
define('GLPI_PLUGIN_DOC_DIR', GLPI_VAR_DIR . '/_plugins');
define('GLPI_RSS_DIR', GLPI_VAR_DIR . '/_rss');
define('GLPI_SESSION_DIR', GLPI_VAR_DIR . '/_sessions');
define('GLPI_TMP_DIR', GLPI_VAR_DIR . '/_tmp');
define('GLPI_UPLOAD_DIR', GLPI_VAR_DIR . '/_uploads');
define('GLPI_CACHE_DIR', GLPI_VAR_DIR . '/_cache');
LOCALDEFINE

    info "Setting permissions..."
    
    chown -R www-data:www-data "${CONFIG[INSTALL_DIR]}"
    chown -R www-data:www-data "${GLPI_VAR_DIR}"
    chown -R www-data:www-data "${GLPI_LOG_DIR}"
    chown -R www-data:www-data "${GLPI_CONFIG_DIR}"
    
    find "${CONFIG[INSTALL_DIR]}" -type d -exec chmod 755 {} \;
    find "${CONFIG[INSTALL_DIR]}" -type f -exec chmod 644 {} \;
    chmod -R 770 "${GLPI_VAR_DIR}"
    chmod -R 770 "${GLPI_LOG_DIR}"
    chmod -R 770 "${GLPI_CONFIG_DIR}"
    
    success "GLPI configured"
}

configure_apache() {
    print_step 9 10 "Configuring Apache"
    
    local server_name="${CONFIG[DOMAIN]:-${SYSTEM[IP_ADDRESS]}}"
    local php_version="${SYSTEM[PHP_VERSION]}"
    
    info "Creating Apache virtual host..."
    
    cat > "/etc/apache2/sites-available/glpi.conf" << APACHE
<VirtualHost *:80>
    ServerName ${server_name}
    DocumentRoot ${CONFIG[INSTALL_DIR]}/public

    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    <Directory ${CONFIG[INSTALL_DIR]}>
        Require all denied
    </Directory>

    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHE

    info "Enabling Apache modules..."
    a2enmod rewrite 2>/dev/null || true
    a2enmod headers 2>/dev/null || true
    
    info "Enabling GLPI site..."
    a2dissite 000-default.conf 2>/dev/null || true
    a2ensite glpi.conf 2>/dev/null || true
    
    info "Testing Apache configuration..."
    if ! apache2ctl configtest 2>/dev/null; then
        fatal "Apache configuration test failed"
    fi
    
    info "Restarting Apache..."
    systemctl restart apache2
    systemctl enable apache2
    
    success "Apache configured"
}

finalize_installation() {
    print_step 10 10 "Finalizing Installation"
    
    info "Configuring cron job..."
    cat > "/etc/cron.d/glpi" << CRON
*/2 * * * * www-data /usr/bin/php ${CONFIG[INSTALL_DIR]}/front/cron.php &>/dev/null
CRON
    chmod 644 /etc/cron.d/glpi
    
    info "Saving credentials..."
    cat > "/root/.glpi_credentials" << CREDENTIALS
# GLPI Installation Credentials
# Generated: $(date)

URL=http://${SYSTEM[IP_ADDRESS]}
VERSION=${CONFIG[GLPI_VERSION]}

DB_HOST=${CONFIG[DB_HOST]}
DB_NAME=${CONFIG[DB_NAME]}
DB_USER=${CONFIG[DB_USER]}
DB_PASS=${CONFIG[DB_PASS]}

# Default GLPI Accounts (CHANGE IMMEDIATELY!)
# Super-Admin: glpi / glpi
# Admin: tech / tech
# Normal: normal / normal
# Post-only: post-only / post-only
CREDENTIALS
    chmod 600 /root/.glpi_credentials
    
    success "Installation finalized"
}

print_summary() {
    local duration=$(($(date +%s) - START_TIME))
    
    echo ""
    echo -e "${C_GREEN}${C_BOLD}"
    cat << 'SUCCESS_BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║                     INSTALLATION COMPLETE / SUCCÈS                        ║
╚═══════════════════════════════════════════════════════════════════════════╝
SUCCESS_BANNER
    echo -e "${C_RESET}"
    
    echo -e "${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}                          INSTALLATION SUMMARY${C_RESET}"
    echo -e "${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Access URL:${C_RESET}        ${C_GREEN}http://${SYSTEM[IP_ADDRESS]}${C_RESET}"
    echo -e "  ${C_BOLD}GLPI Version:${C_RESET}      ${CONFIG[GLPI_VERSION]}"
    echo -e "  ${C_BOLD}Duration:${C_RESET}          $((duration / 60))m $((duration % 60))s"
    echo ""
    echo -e "${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}                        DATABASE CONFIGURATION${C_RESET}"
    echo -e "${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Host:${C_RESET}              ${CONFIG[DB_HOST]}"
    echo -e "  ${C_BOLD}Database:${C_RESET}          ${CONFIG[DB_NAME]}"
    echo -e "  ${C_BOLD}Username:${C_RESET}          ${CONFIG[DB_USER]}"
    echo -e "  ${C_BOLD}Password:${C_RESET}          ${CONFIG[DB_PASS]}"
    echo ""
    echo -e "${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}                        DEFAULT GLPI ACCOUNTS${C_RESET}"
    echo -e "${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Super-Admin:${C_RESET}       glpi / glpi"
    echo -e "  ${C_BOLD}Admin:${C_RESET}             tech / tech"
    echo -e "  ${C_BOLD}Normal:${C_RESET}            normal / normal"
    echo -e "  ${C_BOLD}Post-only:${C_RESET}         post-only / post-only"
    echo ""
    echo -e "${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_YELLOW}${C_BOLD}⚠  POST-INSTALLATION STEPS:${C_RESET}"
    echo ""
    echo -e "     1. Open ${C_BOLD}http://${SYSTEM[IP_ADDRESS]}${C_RESET} in your browser"
    echo -e "     2. Complete the setup wizard"
    echo -e "     3. ${C_RED}${C_BOLD}CHANGE ALL DEFAULT PASSWORDS!${C_RESET}"
    echo -e "     4. Remove install script: ${C_BOLD}rm ${CONFIG[INSTALL_DIR]}/install/install.php${C_RESET}"
    echo ""
    echo -e "${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_GREEN}Credentials saved:${C_RESET} /root/.glpi_credentials"
    echo -e "  ${C_GREEN}Log file:${C_RESET}          ${LOG_FILE}"
    echo ""
}

#-------------------------------------------------------------------------------
# UNINSTALL FUNCTION
#-------------------------------------------------------------------------------

uninstall_glpi() {
    print_banner
    
    echo -e "${C_RED}${C_BOLD}"
    cat << 'UNINSTALL_BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║                           GLPI UNINSTALLATION                             ║
╚═══════════════════════════════════════════════════════════════════════════╝
UNINSTALL_BANNER
    echo -e "${C_RESET}"
    
    check_root
    
    warn "This will remove GLPI from your system!"
    echo ""
    [[ "${KEEP_DATABASE}" == "false" ]] && warn "Database will be DELETED!"
    [[ "${KEEP_PACKAGES}" == "false" ]] && warn "Apache, MariaDB, PHP packages will be REMOVED!"
    echo ""
    
    if [[ "${UNATTENDED}" != "true" ]]; then
        if ! confirm "Are you sure you want to uninstall GLPI?" "n"; then
            info "Uninstallation cancelled"
            exit 0
        fi
    fi
    
    info "Stopping services..."
    systemctl stop apache2 2>/dev/null || true
    
    info "Removing GLPI files..."
    rm -rf "${GLPI_INSTALL_DIR}" 2>/dev/null || true
    rm -rf "${GLPI_VAR_DIR}" 2>/dev/null || true
    rm -rf "${GLPI_LOG_DIR}" 2>/dev/null || true
    rm -rf "${GLPI_CONFIG_DIR}" 2>/dev/null || true
    
    info "Removing Apache configuration..."
    a2dissite glpi.conf 2>/dev/null || true
    rm -f /etc/apache2/sites-available/glpi.conf 2>/dev/null || true
    a2ensite 000-default.conf 2>/dev/null || true
    
    info "Removing cron job..."
    rm -f /etc/cron.d/glpi 2>/dev/null || true
    
    if [[ "${KEEP_DATABASE}" == "false" ]]; then
        info "Removing database..."
        
        local db_name="glpi_db"
        local db_user="glpi_user"
        
        if [[ -f /root/.glpi_credentials ]]; then
            source /root/.glpi_credentials 2>/dev/null || true
            db_name="${DB_NAME:-glpi_db}"
            db_user="${DB_USER:-glpi_user}"
        fi
        
        systemctl start mariadb 2>/dev/null || true
        sleep 2
        mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
        mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        
        success "Database removed"
    fi
    
    if [[ "${KEEP_PACKAGES}" == "false" ]]; then
        info "Removing packages..."
        systemctl stop apache2 mariadb 2>/dev/null || true
        
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
            apache2 apache2-* \
            mariadb-server mariadb-client mariadb-* \
            php* libapache2-mod-php* 2>/dev/null || true
        
        apt-get autoremove -y -qq 2>/dev/null || true
        apt-get clean 2>/dev/null || true
        
        success "Packages removed"
    else
        systemctl restart apache2 2>/dev/null || true
    fi
    
    rm -f /root/.glpi_credentials 2>/dev/null || true
    
    echo ""
    echo -e "${C_GREEN}${C_BOLD}GLPI has been uninstalled successfully!${C_RESET}"
    echo ""
}

#-------------------------------------------------------------------------------
# HELP & ARGUMENTS
#-------------------------------------------------------------------------------

show_help() {
    cat << HELP
${C_BOLD}GLPI Auto-Installer v${SCRIPT_VERSION}${C_RESET}
Optimized for Debian and Ubuntu

${C_BOLD}USAGE:${C_RESET}
    ${SCRIPT_NAME_BASE} [OPTIONS]

${C_BOLD}INSTALL OPTIONS:${C_RESET}
    -h, --help              Show this help
    -v, --verbose           Verbose output
    -y, --yes               Non-interactive mode
    -f, --force             Force install despite warnings
    -d, --dry-run           Show what would be done
    --db-name NAME          Database name (default: glpi_db)
    --db-user USER          Database user (default: glpi_user)
    --db-pass PASS          Database password (auto-generated)
    --timezone TZ           Timezone (default: Europe/Paris)
    --domain DOMAIN         Server domain name
    --version               Show version

${C_BOLD}UNINSTALL OPTIONS:${C_RESET}
    --uninstall             Uninstall GLPI
    --keep-db               Keep database when uninstalling
    --keep-packages         Keep packages when uninstalling

${C_BOLD}EXAMPLES:${C_RESET}
    sudo ${SCRIPT_NAME_BASE}                    Interactive install
    sudo ${SCRIPT_NAME_BASE} -y                 Automatic install
    sudo ${SCRIPT_NAME_BASE} --uninstall        Uninstall GLPI
    sudo ${SCRIPT_NAME_BASE} --uninstall -y     Uninstall without prompts

${C_BOLD}SUPPORTED SYSTEMS:${C_RESET}
    - Debian 10, 11, 12, 13
    - Ubuntu 20.04, 22.04, 24.04

HELP
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)      show_help; exit 0 ;;
            -v|--verbose)   VERBOSE=true; shift ;;
            -y|--yes)       UNATTENDED=true; shift ;;
            -f|--force)     FORCE=true; shift ;;
            -d|--dry-run)   DRY_RUN=true; shift ;;
            --uninstall)    UNINSTALL_MODE=true; shift ;;
            --keep-db)      KEEP_DATABASE=true; shift ;;
            --keep-packages) KEEP_PACKAGES=true; shift ;;
            --db-name)      CONFIG[DB_NAME]="$2"; shift 2 ;;
            --db-user)      CONFIG[DB_USER]="$2"; shift 2 ;;
            --db-pass)      CONFIG[DB_PASS]="$2"; shift 2 ;;
            --timezone)     CONFIG[TIMEZONE]="$2"; shift 2 ;;
            --domain)       CONFIG[DOMAIN]="$2"; shift 2 ;;
            --version)      echo "GLPI Auto-Installer v${SCRIPT_VERSION}"; exit 0 ;;
            *)              error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------

main() {
    parse_arguments "$@"
    
    # Auto-detect piped input
    [[ ! -t 0 ]] && UNATTENDED=true
    
    # Handle uninstall
    if [[ "${UNINSTALL_MODE}" == "true" ]]; then
        uninstall_glpi
        exit 0
    fi
    
    print_banner
    check_root
    init_logging
    acquire_lock
    
    info "Starting GLPI installation..."
    info "Log file: ${LOG_FILE}"
    [[ "${UNATTENDED}" == "true" ]] && info "Running in unattended mode"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "DRY RUN - No changes will be made"
        check_network
        detect_system
        check_requirements
        fetch_latest_version
        success "Dry run completed"
        exit 0
    fi
    
    check_network
    detect_system
    check_requirements
    fetch_latest_version
    
    if [[ "${UNATTENDED}" != "true" ]]; then
        echo ""
        echo -e "${C_BOLD}Installation Configuration:${C_RESET}"
        echo -e "  GLPI Version:    ${CONFIG[GLPI_VERSION]}"
        echo -e "  Database:        ${CONFIG[DB_NAME]}"
        echo -e "  Timezone:        ${CONFIG[TIMEZONE]}"
        echo ""
        if ! confirm "Proceed with installation?" "y"; then
            fatal "Installation cancelled"
        fi
    fi
    
    install_packages
    configure_php
    configure_database
    download_glpi
    configure_glpi
    configure_apache
    finalize_installation
    print_summary
}

main "$@"
