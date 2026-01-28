#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_VERSION="4.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PID=$$
readonly START_TIME=$(date +%s)

readonly LOG_DIR="/var/log/glpi-installer"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/var/run/glpi-installer.lock"
readonly BACKUP_DIR="/var/backups/glpi-installer"
readonly STATE_FILE="/tmp/glpi_install_state_${SCRIPT_PID}"

readonly GLPI_INSTALL_DIR="/var/www/html/glpi"
readonly GLPI_VAR_DIR="/var/lib/glpi"
readonly GLPI_LOG_DIR="/var/log/glpi"
readonly GLPI_CONFIG_DIR="/etc/glpi"

readonly MIN_MEMORY_MB=1024
readonly MIN_DISK_GB=5
readonly MIN_PHP_VERSION="7.4"
readonly SUPPORTED_OS=("debian:10,11,12,13" "ubuntu:20.04,22.04,24.04" "rhel:8,9" "centos:8,9" "rocky:8,9" "almalinux:8,9" "fedora:38,39,40,41")

declare -A CONFIG=(
    [GLPI_VERSION]=""
    [GLPI_DOWNLOAD_URL]=""
    [DB_NAME]="glpi_db"
    [DB_USER]="glpi_user"
    [DB_PASS]=""
    [DB_HOST]="localhost"
    [DB_PORT]="3306"
    [TIMEZONE]="Europe/Paris"
    [WEB_SERVER]="apache"
    [INSTALL_DIR]="${GLPI_INSTALL_DIR}"
    [ENABLE_SSL]="false"
    [SSL_CERT]=""
    [SSL_KEY]=""
    [DOMAIN]=""
)

declare -A SYSTEM=(
    [OS_FAMILY]=""
    [OS_NAME]=""
    [OS_VERSION]=""
    [OS_CODENAME]=""
    [OS_PRETTY_NAME]=""
    [PKG_MANAGER]=""
    [PHP_VERSION]=""
    [WEB_USER]=""
    [WEB_GROUP]=""
    [WEB_SERVICE]=""
    [PHP_FPM_SERVICE]=""
    [PHP_INI_DIR]=""
    [TOTAL_MEMORY_MB]=0
    [AVAILABLE_DISK_GB]=0
    [CPU_CORES]=0
    [IP_ADDRESS]=""
)

declare -a ROLLBACK_ACTIONS=()
declare -a INSTALLED_PACKAGES=()
declare -i CURRENT_STEP=0
declare -i TOTAL_STEPS=12
declare INSTALL_STATE="init"
declare VERBOSE=false
declare DRY_RUN=false
declare FORCE=false
declare UNATTENDED=false
declare SKIP_CHECKS=false

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_MAGENTA='\033[0;35m'
readonly C_CYAN='\033[0;36m'
readonly C_WHITE='\033[0;37m'
readonly C_BG_RED='\033[41m'
readonly C_BG_GREEN='\033[42m'

init_logging() {
    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"
    exec 3>&1 4>&2
    exec 1> >(tee -a "${LOG_FILE}") 2>&1
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    local prefix=""
    
    case "${level}" in
        DEBUG)   color="${C_DIM}";      prefix="[DEBUG]" ;;
        INFO)    color="${C_BLUE}";     prefix="[INFO] " ;;
        SUCCESS) color="${C_GREEN}";    prefix="[OK]   " ;;
        WARN)    color="${C_YELLOW}";   prefix="[WARN] " ;;
        ERROR)   color="${C_RED}";      prefix="[ERROR]" ;;
        FATAL)   color="${C_BG_RED}";   prefix="[FATAL]" ;;
    esac
    
    if [[ "${level}" == "DEBUG" && "${VERBOSE}" != "true" ]]; then
        echo "[${timestamp}] ${prefix} ${message}" >> "${LOG_FILE}" 2>/dev/null || true
        return
    fi
    
    echo -e "${color}${prefix}${C_RESET} ${message}"
    echo "[${timestamp}] ${prefix} ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

debug() { log DEBUG "$@"; }
info()  { log INFO "$@"; }
success() { log SUCCESS "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }
fatal() { log FATAL "$@"; cleanup; exit 1; }

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
    ((CURRENT_STEP++)) || true
    local title="$1"
    local width=70
    local line=$(printf '═%.0s' $(seq 1 $width))
    
    echo ""
    echo -e "${C_CYAN}╔${line}╗${C_RESET}"
    printf "${C_CYAN}║${C_RESET} ${C_BOLD}[%02d/%02d]${C_RESET} %-$((width-10))s ${C_CYAN}║${C_RESET}\n" "${CURRENT_STEP}" "${TOTAL_STEPS}" "${title}"
    echo -e "${C_CYAN}╚${line}╝${C_RESET}"
    echo ""
}

print_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r  ${C_CYAN}[${C_GREEN}"
    printf '█%.0s' $(seq 1 $filled) 2>/dev/null || true
    printf "${C_DIM}"
    printf '░%.0s' $(seq 1 $empty) 2>/dev/null || true
    printf "${C_RESET}${C_CYAN}]${C_RESET} ${C_BOLD}%3d%%${C_RESET}" "$percentage"
}

spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}${spinchars:i++%${#spinchars}:1}${C_RESET} ${message}"
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    printf "\r%-$((${#message} + 10))s\r" " "
}

confirm() {
    local message="${1:-Continue?}"
    local default="${2:-n}"
    
    if [[ "${UNATTENDED}" == "true" ]]; then
        [[ "${default}" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
    
    # If not running interactively (piped), use default
    if [[ ! -t 0 ]]; then
        [[ "${default}" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
    
    local prompt
    [[ "${default}" =~ ^[Yy]$ ]] && prompt="[Y/n]" || prompt="[y/N]"
    
    while true; do
        read -rp "  ${C_YELLOW}?${C_RESET} ${message} ${prompt}: " answer </dev/tty
        answer="${answer:-$default}"
        case "${answer}" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer yes or no." ;;
        esac
    done
}

acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local old_pid=$(cat "${LOCK_FILE}" 2>/dev/null)
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            fatal "Another installation is already running (PID: ${old_pid})"
        fi
        warn "Removing stale lock file"
        rm -f "${LOCK_FILE}"
    fi
    
    echo "${SCRIPT_PID}" > "${LOCK_FILE}"
    debug "Lock acquired (PID: ${SCRIPT_PID})"
}

release_lock() {
    rm -f "${LOCK_FILE}" 2>/dev/null || true
    debug "Lock released"
}

save_state() {
    local state="$1"
    INSTALL_STATE="${state}"
    echo "${state}" > "${STATE_FILE}"
    debug "State saved: ${state}"
}

load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        INSTALL_STATE=$(cat "${STATE_FILE}")
        debug "State loaded: ${INSTALL_STATE}"
    fi
}

add_rollback() {
    ROLLBACK_ACTIONS+=("$1")
    debug "Rollback action added: $1"
}

execute_rollback() {
    if [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]]; then
        return
    fi
    
    warn "Executing rollback..."
    
    for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
        local action="${ROLLBACK_ACTIONS[i]}"
        debug "Rollback: ${action}"
        eval "${action}" 2>/dev/null || true
    done
    
    success "Rollback completed"
}

cleanup() {
    local exit_code=$?
    
    release_lock
    rm -f "${STATE_FILE}" 2>/dev/null || true
    
    if [[ ${exit_code} -ne 0 && "${INSTALL_STATE}" != "completed" ]]; then
        error "Installation failed at state: ${INSTALL_STATE}"
        if confirm "Do you want to rollback changes?" "y"; then
            execute_rollback
        fi
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    info "Total execution time: $((duration / 60))m $((duration % 60))s"
    info "Log file: ${LOG_FILE}"
}

trap cleanup EXIT
trap 'fatal "Installation interrupted by user"' INT TERM

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        fatal "This script must be run as root. Use: sudo ${SCRIPT_NAME}"
    fi
    debug "Root privileges confirmed"
}

check_network() {
    info "Checking network connectivity..."
    
    local reachable=0
    
    if curl -s --connect-timeout 5 -o /dev/null "https://github.com" </dev/null 2>/dev/null; then
        reachable=1
    elif curl -s --connect-timeout 5 -o /dev/null "https://api.github.com" </dev/null 2>/dev/null; then
        reachable=1
    elif ping -c 1 -W 3 "1.1.1.1" </dev/null &>/dev/null; then
        reachable=1
    fi
    
    if [[ ${reachable} -eq 0 ]]; then
        fatal "No network connectivity. Please check your internet connection."
    fi
    
    success "Network connectivity verified"
}

detect_system() {
    print_step "System Detection"
    
    if [[ ! -f /etc/os-release ]]; then
        fatal "Cannot detect OS: /etc/os-release not found"
    fi
    
    source /etc/os-release
    
    SYSTEM[OS_NAME]="${ID}"
    SYSTEM[OS_VERSION]="${VERSION_ID}"
    SYSTEM[OS_CODENAME]="${VERSION_CODENAME:-}"
    SYSTEM[OS_PRETTY_NAME]="${PRETTY_NAME}"
    
    case "${ID}" in
        debian|ubuntu)
            SYSTEM[OS_FAMILY]="debian"
            SYSTEM[PKG_MANAGER]="apt"
            SYSTEM[WEB_USER]="www-data"
            SYSTEM[WEB_GROUP]="www-data"
            SYSTEM[WEB_SERVICE]="apache2"
            ;;
        rhel|centos|rocky|almalinux|ol)
            SYSTEM[OS_FAMILY]="rhel"
            SYSTEM[PKG_MANAGER]="dnf"
            [[ "${VERSION_ID}" == "7"* ]] && SYSTEM[PKG_MANAGER]="yum"
            SYSTEM[WEB_USER]="apache"
            SYSTEM[WEB_GROUP]="apache"
            SYSTEM[WEB_SERVICE]="httpd"
            ;;
        fedora)
            SYSTEM[OS_FAMILY]="rhel"
            SYSTEM[PKG_MANAGER]="dnf"
            SYSTEM[WEB_USER]="apache"
            SYSTEM[WEB_GROUP]="apache"
            SYSTEM[WEB_SERVICE]="httpd"
            ;;
        *)
            fatal "Unsupported distribution: ${ID}"
            ;;
    esac
    
    local supported=false
    for os_spec in "${SUPPORTED_OS[@]}"; do
        local os_name="${os_spec%%:*}"
        local versions="${os_spec#*:}"
        if [[ "${ID}" == "${os_name}" ]]; then
            IFS=',' read -ra ver_array <<< "${versions}"
            for ver in "${ver_array[@]}"; do
                if [[ "${VERSION_ID}" == "${ver}"* ]]; then
                    supported=true
                    break 2
                fi
            done
        fi
    done
    
    if [[ "${supported}" != "true" && "${FORCE}" != "true" ]]; then
        warn "OS ${PRETTY_NAME} is not officially supported"
        if ! confirm "Continue anyway?" "n"; then
            fatal "Installation cancelled"
        fi
    fi
    
    SYSTEM[TOTAL_MEMORY_MB]=$(free -m | awk '/^Mem:/{print $2}')
    SYSTEM[AVAILABLE_DISK_GB]=$(df -BG / | awk 'NR==2{print int($4)}')
    SYSTEM[CPU_CORES]=$(nproc)
    SYSTEM[IP_ADDRESS]=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    
    case "${SYSTEM[OS_FAMILY]}" in
        debian)
            case "${ID}" in
                debian)
                    case "${VERSION_ID}" in
                        10) SYSTEM[PHP_VERSION]="7.3" ;;
                        11) SYSTEM[PHP_VERSION]="7.4" ;;
                        12) SYSTEM[PHP_VERSION]="8.2" ;;
                        13) SYSTEM[PHP_VERSION]="8.3" ;;
                        *) SYSTEM[PHP_VERSION]="8.3" ;;
                    esac
                    ;;
                ubuntu)
                    case "${VERSION_ID}" in
                        20.04) SYSTEM[PHP_VERSION]="7.4" ;;
                        22.04) SYSTEM[PHP_VERSION]="8.1" ;;
                        24.04) SYSTEM[PHP_VERSION]="8.3" ;;
                        *) SYSTEM[PHP_VERSION]="8.1" ;;
                    esac
                    ;;
            esac
            SYSTEM[PHP_FPM_SERVICE]="php${SYSTEM[PHP_VERSION]}-fpm"
            SYSTEM[PHP_INI_DIR]="/etc/php/${SYSTEM[PHP_VERSION]}"
            ;;
        rhel)
            case "${VERSION_ID}" in
                8*) SYSTEM[PHP_VERSION]="8.0" ;;
                9*) SYSTEM[PHP_VERSION]="8.2" ;;
                *) SYSTEM[PHP_VERSION]="8.2" ;;
            esac
            SYSTEM[PHP_FPM_SERVICE]="php-fpm"
            SYSTEM[PHP_INI_DIR]="/etc"
            ;;
    esac
    
    success "Detected: ${SYSTEM[OS_PRETTY_NAME]}"
    info "  ├─ Family: ${SYSTEM[OS_FAMILY]}"
    info "  ├─ Package Manager: ${SYSTEM[PKG_MANAGER]}"
    info "  ├─ PHP Version: ${SYSTEM[PHP_VERSION]}"
    info "  ├─ Memory: ${SYSTEM[TOTAL_MEMORY_MB]} MB"
    info "  ├─ Available Disk: ${SYSTEM[AVAILABLE_DISK_GB]} GB"
    info "  ├─ CPU Cores: ${SYSTEM[CPU_CORES]}"
    info "  └─ IP Address: ${SYSTEM[IP_ADDRESS]}"
}

check_requirements() {
    print_step "Requirements Check"
    
    local errors=0
    
    info "Checking memory requirements..."
    if [[ ${SYSTEM[TOTAL_MEMORY_MB]} -lt ${MIN_MEMORY_MB} ]]; then
        error "Insufficient memory: ${SYSTEM[TOTAL_MEMORY_MB]}MB < ${MIN_MEMORY_MB}MB required"
        ((errors++)) || true
    else
        success "Memory: ${SYSTEM[TOTAL_MEMORY_MB]}MB (minimum: ${MIN_MEMORY_MB}MB)"
    fi
    
    info "Checking disk space..."
    if [[ ${SYSTEM[AVAILABLE_DISK_GB]} -lt ${MIN_DISK_GB} ]]; then
        error "Insufficient disk space: ${SYSTEM[AVAILABLE_DISK_GB]}GB < ${MIN_DISK_GB}GB required"
        ((errors++)) || true
    else
        success "Disk space: ${SYSTEM[AVAILABLE_DISK_GB]}GB (minimum: ${MIN_DISK_GB}GB)"
    fi
    
    info "Checking for existing services..."
    for service in apache2 httpd nginx mysql mariadb; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            warn "Service ${service} is already running"
        fi
    done
    
    info "Checking for existing GLPI installation..."
    if [[ -d "${GLPI_INSTALL_DIR}" ]]; then
        warn "Existing GLPI installation found at ${GLPI_INSTALL_DIR}"
        if [[ "${FORCE}" != "true" ]]; then
            if ! confirm "Backup and replace existing installation?" "n"; then
                fatal "Installation cancelled"
            fi
        fi
    fi
    
    info "Checking required commands..."
    local required_cmds=(curl wget tar)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            warn "Required command not found: ${cmd} (will be installed)"
        fi
    done
    
    if [[ ${errors} -gt 0 && "${SKIP_CHECKS}" != "true" ]]; then
        fatal "Requirements check failed with ${errors} error(s)"
    fi
    
    success "All requirements verified"
}

fetch_latest_version() {
    print_step "Fetching Latest GLPI Version"
    
    info "Querying GitHub API..."
    
    local api_response
    local max_retries=3
    local retry=0
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        api_response=$(curl -sS --connect-timeout 10 --max-time 30 \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/glpi-project/glpi/releases/latest" 2>&1) && break
        ((retry++)) || true
        warn "API request failed, retrying (${retry}/${max_retries})..."
        sleep 2
    done
    
    if [[ ${retry} -eq ${max_retries} ]]; then
        fatal "Failed to fetch GLPI version from GitHub API after ${max_retries} attempts"
    fi
    
    CONFIG[GLPI_VERSION]=$(echo "${api_response}" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    
    if [[ -z "${CONFIG[GLPI_VERSION]}" ]]; then
        fatal "Could not parse GLPI version from API response"
    fi
    
    CONFIG[GLPI_DOWNLOAD_URL]="https://github.com/glpi-project/glpi/releases/download/${CONFIG[GLPI_VERSION]}/glpi-${CONFIG[GLPI_VERSION]}.tgz"
    
    info "Verifying download URL..."
    local http_code
    http_code=$(curl -sI -o /dev/null -w "%{http_code}" "${CONFIG[GLPI_DOWNLOAD_URL]}" 2>/dev/null)
    
    if [[ "${http_code}" != "200" && "${http_code}" != "302" ]]; then
        fatal "Download URL verification failed (HTTP ${http_code})"
    fi
    
    success "Latest version: ${CONFIG[GLPI_VERSION]}"
    debug "Download URL: ${CONFIG[GLPI_DOWNLOAD_URL]}"
}

install_packages_debian() {
    info "Updating package repositories..."
    apt-get update -qq
    
    info "Installing base packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        apache2 \
        mariadb-server \
        mariadb-client \
        curl \
        wget \
        tar \
        bzip2 \
        unzip \
        gnupg \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        cron \
        jq
    
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
        "php${SYSTEM[PHP_VERSION]}-common"
        "libapache2-mod-php${SYSTEM[PHP_VERSION]}"
    )
    
    local optional_packages=(
        "php${SYSTEM[PHP_VERSION]}-redis"
        "php${SYSTEM[PHP_VERSION]}-apcu"
        "php${SYSTEM[PHP_VERSION]}-xmlrpc"
        "php${SYSTEM[PHP_VERSION]}-cas"
    )
    
    info "Installing PHP ${SYSTEM[PHP_VERSION]} packages..."
    
    local total=${#php_packages[@]}
    local current=0
    
    for pkg in "${php_packages[@]}"; do
        ((current++)) || true
        print_progress ${current} ${total}
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" 2>/dev/null || {
            warn "Package ${pkg} not available, skipping..."
        }
    done
    echo ""
    
    for pkg in "${optional_packages[@]}"; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" 2>/dev/null || true
    done
    
    a2enmod rewrite proxy_fcgi setenvif ssl headers expires 2>/dev/null || true
}

install_packages_rhel() {
    info "Configuring repositories..."
    
    if [[ "${SYSTEM[OS_NAME]}" != "fedora" ]]; then
        ${SYSTEM[PKG_MANAGER]} install -y epel-release 2>/dev/null || true
        
        if [[ "${SYSTEM[OS_VERSION]}" == "8"* ]] || [[ "${SYSTEM[OS_VERSION]}" == "9"* ]]; then
            ${SYSTEM[PKG_MANAGER]} module reset php -y 2>/dev/null || true
            ${SYSTEM[PKG_MANAGER]} module enable php:remi-8.2 -y 2>/dev/null || \
            ${SYSTEM[PKG_MANAGER]} module enable php:8.2 -y 2>/dev/null || \
            ${SYSTEM[PKG_MANAGER]} module enable php:8.0 -y 2>/dev/null || true
        fi
        
        if [[ "${SYSTEM[OS_VERSION]}" == "8"* ]]; then
            ${SYSTEM[PKG_MANAGER]} config-manager --set-enabled powertools 2>/dev/null || \
            ${SYSTEM[PKG_MANAGER]} config-manager --set-enabled PowerTools 2>/dev/null || true
        elif [[ "${SYSTEM[OS_VERSION]}" == "9"* ]]; then
            ${SYSTEM[PKG_MANAGER]} config-manager --set-enabled crb 2>/dev/null || true
        fi
    fi
    
    info "Installing base packages..."
    ${SYSTEM[PKG_MANAGER]} install -y \
        httpd \
        mariadb-server \
        mariadb \
        curl \
        wget \
        tar \
        bzip2 \
        unzip \
        cronie \
        jq \
        policycoreutils-python-utils 2>/dev/null || \
    ${SYSTEM[PKG_MANAGER]} install -y \
        httpd \
        mariadb-server \
        mariadb \
        curl \
        wget \
        tar \
        bzip2 \
        unzip \
        cronie \
        jq
    
    local php_packages=(
        php
        php-fpm
        php-mysqlnd
        php-ldap
        php-imap
        php-curl
        php-gd
        php-mbstring
        php-xml
        php-intl
        php-zip
        php-bz2
        php-opcache
        php-cli
        php-common
    )
    
    info "Installing PHP packages..."
    
    local total=${#php_packages[@]}
    local current=0
    
    for pkg in "${php_packages[@]}"; do
        ((current++)) || true
        print_progress ${current} ${total}
        ${SYSTEM[PKG_MANAGER]} install -y "${pkg}" 2>/dev/null || true
    done
    echo ""
}

install_dependencies() {
    print_step "Installing Dependencies"
    
    save_state "installing_packages"
    
    case "${SYSTEM[OS_FAMILY]}" in
        debian) install_packages_debian ;;
        rhel)   install_packages_rhel ;;
    esac
    
    add_rollback "info 'Packages require manual removal'"
    
    success "All dependencies installed"
}

configure_php() {
    print_step "Configuring PHP"
    
    save_state "configuring_php"
    
    local php_ini=""
    
    if [[ "${SYSTEM[OS_FAMILY]}" == "debian" ]]; then
        for path in "${SYSTEM[PHP_INI_DIR]}/apache2/php.ini" \
                    "${SYSTEM[PHP_INI_DIR]}/fpm/php.ini" \
                    "${SYSTEM[PHP_INI_DIR]}/cli/php.ini"; do
            if [[ -f "${path}" ]]; then
                php_ini="${path}"
                break
            fi
        done
    else
        php_ini="/etc/php.ini"
    fi
    
    if [[ ! -f "${php_ini}" ]]; then
        warn "PHP configuration file not found, skipping PHP configuration"
        return
    fi
    
    info "Configuring ${php_ini}..."
    
    cp "${php_ini}" "${php_ini}.backup.$(date +%Y%m%d_%H%M%S)"
    add_rollback "mv '${php_ini}.backup.'* '${php_ini}' 2>/dev/null || true"
    
    declare -A php_settings=(
        [memory_limit]="256M"
        [upload_max_filesize]="100M"
        [post_max_size]="100M"
        [max_execution_time]="600"
        [max_input_vars]="5000"
        [max_input_time]="120"
        [session.cookie_httponly]="On"
        [session.cookie_secure]="On"
        [session.use_strict_mode]="1"
        [date.timezone]="${CONFIG[TIMEZONE]}"
        [opcache.enable]="1"
        [opcache.memory_consumption]="128"
        [opcache.interned_strings_buffer]="8"
        [opcache.max_accelerated_files]="10000"
        [opcache.revalidate_freq]="2"
    )
    
    for key in "${!php_settings[@]}"; do
        local value="${php_settings[$key]}"
        sed -i "s|^;*\s*${key}\s*=.*|${key} = ${value}|g" "${php_ini}"
        if ! grep -q "^${key}\s*=" "${php_ini}"; then
            echo "${key} = ${value}" >> "${php_ini}"
        fi
    done
    
    success "PHP configured successfully"
}

generate_secure_password() {
    local length=${1:-24}
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "${length}"
}

configure_database() {
    print_step "Configuring Database"
    
    save_state "configuring_database"
    
    info "Starting MariaDB service..."
    systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
    systemctl enable mariadb 2>/dev/null || systemctl enable mysql 2>/dev/null || true
    
    if [[ -z "${CONFIG[DB_PASS]}" ]]; then
        CONFIG[DB_PASS]=$(generate_secure_password 24)
    fi
    
    info "Creating database and user..."
    
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${CONFIG[DB_NAME]}\` 
              CHARACTER SET utf8mb4 
              COLLATE utf8mb4_unicode_ci;" || fatal "Failed to create database"
    
    mysql -e "CREATE USER IF NOT EXISTS '${CONFIG[DB_USER]}'@'${CONFIG[DB_HOST]}' 
              IDENTIFIED BY '${CONFIG[DB_PASS]}';" || fatal "Failed to create database user"
    
    mysql -e "GRANT ALL PRIVILEGES ON \`${CONFIG[DB_NAME]}\`.* 
              TO '${CONFIG[DB_USER]}'@'${CONFIG[DB_HOST]}';" || fatal "Failed to grant privileges"
    
    mysql -e "FLUSH PRIVILEGES;"
    
    add_rollback "mysql -e \"DROP DATABASE IF EXISTS \\\`${CONFIG[DB_NAME]}\\\`;\" 2>/dev/null || true"
    add_rollback "mysql -e \"DROP USER IF EXISTS '${CONFIG[DB_USER]}'@'${CONFIG[DB_HOST]}';\" 2>/dev/null || true"
    
    info "Configuring timezone support..."
    mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql mysql 2>/dev/null || true
    mysql -e "GRANT SELECT ON mysql.time_zone_name TO '${CONFIG[DB_USER]}'@'${CONFIG[DB_HOST]}';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;"
    
    success "Database configured successfully"
    info "  ├─ Database: ${CONFIG[DB_NAME]}"
    info "  ├─ User: ${CONFIG[DB_USER]}"
    info "  └─ Host: ${CONFIG[DB_HOST]}"
}

download_glpi() {
    print_step "Downloading GLPI ${CONFIG[GLPI_VERSION]}"
    
    save_state "downloading_glpi"
    
    local temp_dir=$(mktemp -d)
    local archive="${temp_dir}/glpi.tgz"
    
    info "Downloading from GitHub..."
    
    if ! wget --progress=bar:force:noscroll -O "${archive}" "${CONFIG[GLPI_DOWNLOAD_URL]}" 2>&1; then
        rm -rf "${temp_dir}"
        fatal "Failed to download GLPI"
    fi
    
    info "Verifying archive integrity..."
    if ! tar -tzf "${archive}" &>/dev/null; then
        rm -rf "${temp_dir}"
        fatal "Downloaded archive is corrupted"
    fi
    
    if [[ -d "${CONFIG[INSTALL_DIR]}" ]]; then
        info "Backing up existing installation..."
        local backup_path="${BACKUP_DIR}/glpi_backup_$(date +%Y%m%d_%H%M%S)"
        mv "${CONFIG[INSTALL_DIR]}" "${backup_path}"
        add_rollback "rm -rf '${CONFIG[INSTALL_DIR]}' && mv '${backup_path}' '${CONFIG[INSTALL_DIR]}'"
        success "Backup created: ${backup_path}"
    fi
    
    info "Extracting archive..."
    tar -xzf "${archive}" -C "${temp_dir}"
    mv "${temp_dir}/glpi" "${CONFIG[INSTALL_DIR]}"
    
    rm -rf "${temp_dir}"
    
    add_rollback "rm -rf '${CONFIG[INSTALL_DIR]}'"
    
    success "GLPI ${CONFIG[GLPI_VERSION]} downloaded and extracted"
}

configure_glpi_security() {
    print_step "Configuring GLPI Security"
    
    save_state "configuring_glpi"
    
    info "Setting up secure directory structure..."
    
    mkdir -p "${GLPI_VAR_DIR}"/{files,marketplace}
    mkdir -p "${GLPI_VAR_DIR}/files"/{_cron,_dumps,_graphs,_lock,_pictures,_plugins,_rss,_sessions,_tmp,_uploads,_cache}
    mkdir -p "${GLPI_LOG_DIR}"
    mkdir -p "${GLPI_CONFIG_DIR}"
    
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
    
    cat > "${CONFIG[INSTALL_DIR]}/inc/downstream.php" << 'DOWNSTREAM'
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
DOWNSTREAM

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
    
    chown -R "${SYSTEM[WEB_USER]}:${SYSTEM[WEB_GROUP]}" "${CONFIG[INSTALL_DIR]}"
    chown -R "${SYSTEM[WEB_USER]}:${SYSTEM[WEB_GROUP]}" "${GLPI_VAR_DIR}"
    chown -R "${SYSTEM[WEB_USER]}:${SYSTEM[WEB_GROUP]}" "${GLPI_LOG_DIR}"
    chown -R "${SYSTEM[WEB_USER]}:${SYSTEM[WEB_GROUP]}" "${GLPI_CONFIG_DIR}"
    
    find "${CONFIG[INSTALL_DIR]}" -type d -exec chmod 755 {} \;
    find "${CONFIG[INSTALL_DIR]}" -type f -exec chmod 644 {} \;
    chmod -R 770 "${GLPI_VAR_DIR}"
    chmod -R 770 "${GLPI_LOG_DIR}"
    chmod -R 770 "${GLPI_CONFIG_DIR}"
    
    add_rollback "rm -rf '${GLPI_VAR_DIR}' '${GLPI_LOG_DIR}' '${GLPI_CONFIG_DIR}'"
    
    success "GLPI security configuration completed"
}

generate_apache_config() {
    local config_file="$1"
    local server_name="${CONFIG[DOMAIN]:-glpi.local}"
    
    cat > "${config_file}" << APACHE_CONFIG
<VirtualHost *:80>
    ServerName ${server_name}
    ServerAdmin webmaster@${server_name}
    DocumentRoot ${CONFIG[INSTALL_DIR]}/public
    
    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
        Options -Indexes -ExecCGI
        
        <IfModule mod_php.c>
            php_value session.cookie_httponly On
            php_value session.cookie_secure On
        </IfModule>
    </Directory>
    
    <Directory ${CONFIG[INSTALL_DIR]}>
        Require all denied
    </Directory>
    
    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
    </Directory>
    
    <FilesMatch "\\.(htaccess|htpasswd|ini|log|sh|sql)$">
        Require all denied
    </FilesMatch>
    
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
    
    LogLevel warn
</VirtualHost>
APACHE_CONFIG
}

generate_apache_config_rhel() {
    local config_file="$1"
    local server_name="${CONFIG[DOMAIN]:-glpi.local}"
    
    cat > "${config_file}" << APACHE_CONFIG
<VirtualHost *:80>
    ServerName ${server_name}
    ServerAdmin webmaster@${server_name}
    DocumentRoot ${CONFIG[INSTALL_DIR]}/public
    
    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
        Options -Indexes -ExecCGI
        
        <IfModule mod_php.c>
            php_value session.cookie_httponly On
            php_value session.cookie_secure On
        </IfModule>
    </Directory>
    
    <Directory ${CONFIG[INSTALL_DIR]}>
        Require all denied
    </Directory>
    
    <Directory ${CONFIG[INSTALL_DIR]}/public>
        Require all granted
    </Directory>
    
    <FilesMatch "\\.(htaccess|htpasswd|ini|log|sh|sql)$">
        Require all denied
    </FilesMatch>
    
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    
    ErrorLog /var/log/httpd/glpi_error.log
    CustomLog /var/log/httpd/glpi_access.log combined
    
    LogLevel warn
</VirtualHost>
APACHE_CONFIG
}

configure_webserver() {
    print_step "Configuring Web Server"
    
    save_state "configuring_webserver"
    
    local config_file=""
    
    if [[ "${SYSTEM[OS_FAMILY]}" == "debian" ]]; then
        config_file="/etc/apache2/sites-available/glpi.conf"
        generate_apache_config "${config_file}"
        
        a2dissite 000-default.conf 2>/dev/null || true
        a2ensite glpi.conf
        a2enmod rewrite headers
        
        add_rollback "a2dissite glpi.conf; a2ensite 000-default.conf; rm -f '${config_file}'"
        
        info "Testing Apache configuration..."
        apache2ctl configtest || fatal "Apache configuration test failed"
        
    else
        config_file="/etc/httpd/conf.d/glpi.conf"
        generate_apache_config_rhel "${config_file}"
        
        add_rollback "rm -f '${config_file}'"
        
        if command -v getenforce &>/dev/null && [[ $(getenforce) != "Disabled" ]]; then
            info "Configuring SELinux..."
            setsebool -P httpd_can_network_connect on 2>/dev/null || true
            setsebool -P httpd_can_network_connect_db on 2>/dev/null || true
            setsebool -P httpd_can_sendmail on 2>/dev/null || true
            semanage fcontext -a -t httpd_sys_rw_content_t "${GLPI_VAR_DIR}(/.*)?" 2>/dev/null || true
            semanage fcontext -a -t httpd_log_t "${GLPI_LOG_DIR}(/.*)?" 2>/dev/null || true
            restorecon -Rv "${GLPI_VAR_DIR}" 2>/dev/null || true
            restorecon -Rv "${GLPI_LOG_DIR}" 2>/dev/null || true
        fi
        
        info "Testing Apache configuration..."
        httpd -t || fatal "Apache configuration test failed"
    fi
    
    success "Web server configured successfully"
}

configure_firewall() {
    print_step "Configuring Firewall"
    
    save_state "configuring_firewall"
    
    if command -v ufw &>/dev/null; then
        info "Configuring UFW firewall..."
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        success "UFW rules added"
    elif command -v firewall-cmd &>/dev/null; then
        info "Configuring firewalld..."
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        success "Firewalld rules added"
    else
        warn "No supported firewall detected, skipping configuration"
    fi
}

configure_cron() {
    print_step "Configuring Scheduled Tasks"
    
    save_state "configuring_cron"
    
    local cron_file="/etc/cron.d/glpi"
    
    cat > "${cron_file}" << CRON
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""

*/2 * * * * ${SYSTEM[WEB_USER]} /usr/bin/php ${CONFIG[INSTALL_DIR]}/front/cron.php &>/dev/null
CRON
    
    chmod 644 "${cron_file}"
    
    add_rollback "rm -f '${cron_file}'"
    
    success "Cron job configured (runs every 2 minutes)"
}

start_services() {
    print_step "Starting Services"
    
    save_state "starting_services"
    
    local services=("${SYSTEM[WEB_SERVICE]}" "mariadb")
    
    for service in "${services[@]}"; do
        info "Starting ${service}..."
        systemctl restart "${service}" 2>/dev/null || systemctl restart mysql 2>/dev/null || true
        systemctl enable "${service}" 2>/dev/null || true
        
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            success "${service} is running"
        else
            warn "${service} may not be running properly"
        fi
    done
    
    if systemctl list-unit-files | grep -q "${SYSTEM[PHP_FPM_SERVICE]}"; then
        info "Starting ${SYSTEM[PHP_FPM_SERVICE]}..."
        systemctl restart "${SYSTEM[PHP_FPM_SERVICE]}"
        systemctl enable "${SYSTEM[PHP_FPM_SERVICE]}"
    fi
}

verify_installation() {
    print_step "Verifying Installation"
    
    save_state "verifying"
    
    local errors=0
    
    info "Checking file structure..."
    local required_paths=(
        "${CONFIG[INSTALL_DIR]}/public/index.php"
        "${CONFIG[INSTALL_DIR]}/inc/downstream.php"
        "${GLPI_CONFIG_DIR}/local_define.php"
        "${GLPI_VAR_DIR}/files"
        "${GLPI_LOG_DIR}"
    )
    
    for path in "${required_paths[@]}"; do
        if [[ -e "${path}" ]]; then
            debug "Found: ${path}"
        else
            error "Missing: ${path}"
            ((errors++)) || true
        fi
    done
    
    info "Checking services..."
    local services=("${SYSTEM[WEB_SERVICE]}")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            debug "Service running: ${service}"
        else
            error "Service not running: ${service}"
            ((errors++)) || true
        fi
    done
    
    info "Checking database connection..."
    if mysql -u"${CONFIG[DB_USER]}" -p"${CONFIG[DB_PASS]}" -e "USE ${CONFIG[DB_NAME]};" 2>/dev/null; then
        debug "Database connection successful"
    else
        error "Database connection failed"
        ((errors++)) || true
    fi
    
    info "Checking web server response..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/glpi/" 2>/dev/null || echo "000")
    
    if [[ "${http_code}" =~ ^(200|301|302|303)$ ]]; then
        debug "Web server responding (HTTP ${http_code})"
    else
        warn "Web server returned HTTP ${http_code}"
    fi
    
    if [[ ${errors} -gt 0 ]]; then
        warn "Installation completed with ${errors} warning(s)"
    else
        success "All verification checks passed"
    fi
}

save_credentials() {
    local creds_file="/root/.glpi_credentials"
    
    cat > "${creds_file}" << CREDENTIALS
################################################################################
# GLPI Installation Credentials
# Generated: $(date)
# Script Version: ${SCRIPT_VERSION}
################################################################################

# Access URL
URL=http://${SYSTEM[IP_ADDRESS]}/glpi
VERSION=${CONFIG[GLPI_VERSION]}

# Database Configuration
DB_HOST=${CONFIG[DB_HOST]}
DB_PORT=${CONFIG[DB_PORT]}
DB_NAME=${CONFIG[DB_NAME]}
DB_USER=${CONFIG[DB_USER]}
DB_PASS=${CONFIG[DB_PASS]}

# Directory Structure
INSTALL_DIR=${CONFIG[INSTALL_DIR]}
VAR_DIR=${GLPI_VAR_DIR}
LOG_DIR=${GLPI_LOG_DIR}
CONFIG_DIR=${GLPI_CONFIG_DIR}

# Default GLPI Accounts (CHANGE IMMEDIATELY!)
# Super-Admin: glpi / glpi
# Admin: tech / tech
# Normal: normal / normal
# Post-only: post-only / post-only

################################################################################
# SECURITY WARNING: Change all default passwords after first login!
################################################################################
CREDENTIALS
    
    chmod 600 "${creds_file}"
    
    debug "Credentials saved to ${creds_file}"
}

print_summary() {
    save_state "completed"
    
    local duration=$(($(date +%s) - START_TIME))
    
    echo ""
    echo -e "${C_GREEN}"
    cat << 'SUCCESS_BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║    ██████╗ ██████╗ ███╗   ███╗██████╗ ██╗     ███████╗████████╗███████╗   ║
║   ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝╚══██╔══╝██╔════╝   ║
║   ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗     ██║   █████╗     ║
║   ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝     ██║   ██╔══╝     ║
║   ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗   ██║   ███████╗   ║
║    ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝   ╚══════╝   ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
SUCCESS_BANNER
    echo -e "${C_RESET}"
    
    echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}                          INSTALLATION SUMMARY${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Access URL:${C_RESET}        http://${SYSTEM[IP_ADDRESS]}/glpi"
    echo -e "  ${C_BOLD}GLPI Version:${C_RESET}      ${CONFIG[GLPI_VERSION]}"
    echo -e "  ${C_BOLD}Duration:${C_RESET}          $((duration / 60))m $((duration % 60))s"
    echo ""
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}                        DATABASE CONFIGURATION${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Host:${C_RESET}              ${CONFIG[DB_HOST]}"
    echo -e "  ${C_BOLD}Database:${C_RESET}          ${CONFIG[DB_NAME]}"
    echo -e "  ${C_BOLD}Username:${C_RESET}          ${CONFIG[DB_USER]}"
    echo -e "  ${C_BOLD}Password:${C_RESET}          ${CONFIG[DB_PASS]}"
    echo ""
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}                        DEFAULT GLPI ACCOUNTS${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Super-Admin:${C_RESET}       glpi / glpi"
    echo -e "  ${C_BOLD}Admin:${C_RESET}             tech / tech"
    echo -e "  ${C_BOLD}Normal:${C_RESET}            normal / normal"
    echo -e "  ${C_BOLD}Post-only:${C_RESET}         post-only / post-only"
    echo ""
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}                           DIRECTORY PATHS${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}───────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Application:${C_RESET}       ${CONFIG[INSTALL_DIR]}"
    echo -e "  ${C_BOLD}Data:${C_RESET}              ${GLPI_VAR_DIR}"
    echo -e "  ${C_BOLD}Logs:${C_RESET}              ${GLPI_LOG_DIR}"
    echo -e "  ${C_BOLD}Config:${C_RESET}            ${GLPI_CONFIG_DIR}"
    echo ""
    echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_YELLOW}${C_BOLD}⚠  POST-INSTALLATION ACTIONS REQUIRED:${C_RESET}"
    echo ""
    echo -e "     1. Open ${C_BOLD}http://${SYSTEM[IP_ADDRESS]}/glpi${C_RESET} to complete setup wizard"
    echo -e "     2. ${C_RED}${C_BOLD}CHANGE ALL DEFAULT PASSWORDS IMMEDIATELY!${C_RESET}"
    echo -e "     3. Remove install script: ${C_BOLD}rm ${CONFIG[INSTALL_DIR]}/install/install.php${C_RESET}"
    echo -e "     4. Configure HTTPS for production"
    echo -e "     5. Review security hardening guide"
    echo ""
    echo -e "${C_BOLD}${C_CYAN}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  ${C_GREEN}Credentials saved to:${C_RESET} /root/.glpi_credentials"
    echo -e "  ${C_GREEN}Installation log:${C_RESET}    ${LOG_FILE}"
    echo ""
}

show_help() {
    cat << HELP
${C_BOLD}GLPI Auto-Installer v${SCRIPT_VERSION}${C_RESET}

${C_BOLD}USAGE:${C_RESET}
    ${SCRIPT_NAME} [OPTIONS]

${C_BOLD}OPTIONS:${C_RESET}
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -y, --yes               Unattended mode (answer yes to all prompts)
    -f, --force             Force installation on unsupported systems
    -d, --dry-run           Show what would be done without making changes
    --skip-checks           Skip system requirements verification
    --db-name NAME          Set database name (default: glpi_db)
    --db-user USER          Set database user (default: glpi_user)
    --db-pass PASS          Set database password (auto-generated if not set)
    --timezone TZ           Set timezone (default: Europe/Paris)
    --domain DOMAIN         Set server domain name
    --version               Show script version

${C_BOLD}EXAMPLES:${C_RESET}
    sudo ${SCRIPT_NAME}                          Interactive installation
    sudo ${SCRIPT_NAME} -y                       Unattended installation
    sudo ${SCRIPT_NAME} --db-name myglpi         Custom database name
    sudo ${SCRIPT_NAME} -v --domain glpi.example.com

${C_BOLD}SUPPORTED SYSTEMS:${C_RESET}
    - Debian 10, 11, 12, 13
    - Ubuntu 20.04, 22.04, 24.04
    - RHEL/CentOS/Rocky/AlmaLinux 8, 9
    - Fedora 38, 39, 40, 41

${C_BOLD}AUTHOR:${C_RESET}
    Kofysh - https://github.com/Kofysh

${C_BOLD}DOCUMENTATION:${C_RESET}
    https://github.com/Kofysh/GLPI-Auto-Install

HELP
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -y|--yes)
                UNATTENDED=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-checks)
                SKIP_CHECKS=true
                shift
                ;;
            --db-name)
                CONFIG[DB_NAME]="$2"
                shift 2
                ;;
            --db-user)
                CONFIG[DB_USER]="$2"
                shift 2
                ;;
            --db-pass)
                CONFIG[DB_PASS]="$2"
                shift 2
                ;;
            --timezone)
                CONFIG[TIMEZONE]="$2"
                shift 2
                ;;
            --domain)
                CONFIG[DOMAIN]="$2"
                shift 2
                ;;
            --version)
                echo "GLPI Auto-Installer v${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    
    # Auto-detect non-interactive mode (piped input)
    if [[ ! -t 0 ]]; then
        UNATTENDED=true
    fi
    
    print_banner
    
    check_root
    init_logging
    acquire_lock
    
    info "Starting GLPI installation..."
    info "Log file: ${LOG_FILE}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "DRY RUN MODE - No changes will be made"
    fi
    
    if [[ "${UNATTENDED}" == "true" ]]; then
        info "Running in unattended mode"
    fi
    
    check_network
    detect_system
    check_requirements
    fetch_latest_version
    
    if [[ "${DRY_RUN}" != "true" ]]; then
        if [[ "${UNATTENDED}" != "true" ]]; then
            echo ""
            echo -e "${C_BOLD}Installation Configuration:${C_RESET}"
            echo -e "  GLPI Version:    ${CONFIG[GLPI_VERSION]}"
            echo -e "  Database:        ${CONFIG[DB_NAME]}"
            echo -e "  Timezone:        ${CONFIG[TIMEZONE]}"
            echo -e "  Install Path:    ${CONFIG[INSTALL_DIR]}"
            echo ""
            
            if ! confirm "Proceed with installation?" "y"; then
                fatal "Installation cancelled by user"
            fi
        fi
        
        install_dependencies
        configure_php
        configure_database
        download_glpi
        configure_glpi_security
        configure_webserver
        configure_firewall
        configure_cron
        start_services
        verify_installation
        save_credentials
        print_summary
    else
        success "Dry run completed successfully"
        info "The following steps would be executed:"
        echo "  1. Install system packages"
        echo "  2. Configure PHP"
        echo "  3. Setup MariaDB database"
        echo "  4. Download GLPI ${CONFIG[GLPI_VERSION]}"
        echo "  5. Configure security settings"
        echo "  6. Setup Apache web server"
        echo "  7. Configure firewall rules"
        echo "  8. Setup cron jobs"
        echo "  9. Start and enable services"
    fi
}

main "$@"
