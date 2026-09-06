#!/usr/bin/env bash

# Interactive Debian server/PHP installer (v7).
# Run as root. The script intentionally targets Debian because the PHP and
# MongoDB repository definitions below are Debian-specific.

set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Populated by choose_optional_php_extensions(). These globals are used by
# install_php() and the later php -m health check.
PHP_OPTIONAL_PACKAGES_SELECTED=()
PHP_OPTIONAL_MODULES_SELECTED=()
ADDITIONAL_TOOLS_SELECTED=()
DB_UTILITY_PACKAGES_SELECTED=()

info()    { echo -e "${YELLOW}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
error()   { echo -e "${RED}$*${NC}" >&2; }

die() {
    error "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

ask_yes_no() {
    local prompt="$1"
    local answer
    read -r -p "$prompt [y/n]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

run_apt_install() {
    (( $# > 0 )) || return 0
    DEBIAN_FRONTEND=noninteractive apt install -y "$@"
}

require_root() {
    if (( EUID != 0 )); then
        die "This script must be run as root (for example: sudo bash $0)."
    fi
}

require_debian() {
    [[ -r /etc/os-release ]] || die "Cannot determine the operating system."

    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "debian" ]]; then
        die "This refactored installer targets Debian. Detected OS: ${PRETTY_NAME:-unknown}."
    fi

    command_exists apt || die "The apt package manager is required."
}

configure_web_firewall() {
    local server="$1"

    command_exists ufw || return 0

    case "$server" in
        apache)
            ufw allow 'Apache Full' >/dev/null 2>&1 || error "Warning: failed to add the Apache UFW rule."
            ;;
        nginx)
            ufw allow 'Nginx Full' >/dev/null 2>&1 || error "Warning: failed to add the Nginx UFW rule."
            ;;
        caddy|frankenphp|angie|lighttpd|openlitespeed)
            ufw allow 80/tcp >/dev/null 2>&1 || error "Warning: failed to allow TCP/80 in UFW."
            ufw allow 443/tcp >/dev/null 2>&1 || error "Warning: failed to allow TCP/443 in UFW."
            ;;
    esac

    ufw reload >/dev/null 2>&1 || true
}

configure_database_firewall() {
    local port="$1"

    command_exists ufw || return 0

    # Database ports are intentionally NOT opened automatically. Exposing a
    # database to the network should be an explicit administrator decision.
    info "Database port ${port}/tcp was not opened in UFW automatically."
}

install_apache() {
    if command_exists apache2; then
        success "Apache is already installed."
        return 0
    fi

    ask_yes_no "Install Apache?" || return 1
    info "Installing Apache..."
    run_apt_install apache2 || return 1
    systemctl enable --now apache2 || return 1
    configure_web_firewall apache
    success "Apache installed."
}

install_nginx() {
    if command_exists nginx; then
        success "Nginx is already installed."
        return 0
    fi

    ask_yes_no "Install Nginx?" || return 1
    info "Installing Nginx..."
    run_apt_install nginx || return 1
    systemctl enable --now nginx || return 1
    configure_web_firewall nginx
    success "Nginx installed."
}

install_angie() {
    if command_exists angie; then
        success "Angie is already installed."
        return 0
    fi

    ask_yes_no "Install Angie Web Server?" || return 1
    info "Installing Angie Web Server from the official Angie repository..."

    run_apt_install ca-certificates curl || return 1

    curl -fsSL -o /etc/apt/trusted.gpg.d/angie-signing.gpg \
        'https://angie.software/keys/angie-signing.gpg' || return 1
    chmod 0644 /etc/apt/trusted.gpg.d/angie-signing.gpg || return 1

    # Angie documents this repository layout for Debian/Ubuntu.
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ -n "${VERSION_ID:-}" && -n "${VERSION_CODENAME:-}" ]] || {
        error "Unable to determine Debian version/codename for the Angie repository."
        return 1
    }

    printf 'deb https://download.angie.software/angie/%s/%s %s main\n' \
        "$ID" "$VERSION_ID" "$VERSION_CODENAME" \
        > /etc/apt/sources.list.d/angie.list || return 1

    apt update || return 1
    run_apt_install angie || return 1
    systemctl enable --now angie || return 1
    configure_web_firewall angie
    success "Angie Web Server installed."
}

install_lighttpd() {
    if command_exists lighttpd; then
        success "Lighttpd is already installed."
        return 0
    fi

    ask_yes_no "Install Lighttpd?" || return 1
    info "Installing Lighttpd..."
    run_apt_install lighttpd || return 1
    systemctl enable --now lighttpd || return 1
    configure_web_firewall lighttpd
    success "Lighttpd installed."
}

add_litespeed_repository() {
    if package_available openlitespeed; then
        return 0
    fi

    info "Adding the official LiteSpeed repository..."
    run_apt_install ca-certificates curl || return 1

    local repo_script='/tmp/litespeed-repo.sh'
    curl -fsSL 'https://repo.litespeed.sh' -o "$repo_script" || return 1
    bash "$repo_script" || {
        rm -f "$repo_script"
        return 1
    }
    rm -f "$repo_script"
    apt update || return 1
    package_available openlitespeed
}

install_openlitespeed() {
    if [[ -x /usr/local/lsws/bin/openlitespeed ]] || package_installed openlitespeed; then
        success "OpenLiteSpeed is already installed."
        return 0
    fi

    ask_yes_no "Install OpenLiteSpeed?" || return 1
    info "Installing OpenLiteSpeed from the official LiteSpeed repository..."
    add_litespeed_repository || return 1
    run_apt_install openlitespeed || return 1
    systemctl enable --now lsws || return 1
    configure_web_firewall openlitespeed
    success "OpenLiteSpeed installed."
    info "OpenLiteSpeed WebAdmin remains on port 7080 and is not opened in UFW automatically."
}

install_caddy() {
    if command_exists caddy; then
        success "Caddy is already installed."
        return 0
    fi

    ask_yes_no "Install Caddy?" || return 1
    info "Installing Caddy..."

    run_apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1

    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 1

    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-stable.list || return 1

    apt update || return 1
    run_apt_install caddy || return 1
    systemctl enable --now caddy || return 1
    configure_web_firewall caddy
    success "Caddy installed."
}

install_frankenphp() {
    if command_exists frankenphp; then
        success "FrankenPHP is already installed."
        return 0
    fi

    ask_yes_no "Install FrankenPHP?" || return 1

    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "x86_64" ]]; then
        error "Automatic FrankenPHP binary installation in this script supports x86_64 only (detected: $arch)."
        return 1
    fi

    info "Installing FrankenPHP (downloading binary)..."
    if ! curl -fL --retry 3 \
        -o /usr/local/bin/frankenphp \
        'https://github.com/dunglas/frankenphp/releases/latest/download/frankenphp-linux-x86_64'; then
        rm -f /usr/local/bin/frankenphp
        return 1
    fi

    chmod 0755 /usr/local/bin/frankenphp || return 1
    configure_web_firewall frankenphp
    success "FrankenPHP installed. Run it manually, e.g. frankenphp php-server --root /var/www/html."
}

install_mariadb() {
    if package_installed mariadb-server; then
        success "MariaDB server is already installed."
        return 0
    fi

    ask_yes_no "Install MariaDB?" || return 1
    info "Installing MariaDB..."
    run_apt_install mariadb-server || return 1
    systemctl enable --now mariadb || return 1

    if command_exists mariadb-secure-installation; then
        info "Securing MariaDB... Please follow the prompts."
        mariadb-secure-installation || error "Warning: MariaDB secure-installation did not complete successfully."
    elif command_exists mysql_secure_installation; then
        info "Securing MariaDB... Please follow the prompts."
        mysql_secure_installation || error "Warning: MariaDB secure-installation did not complete successfully."
    fi

    configure_database_firewall 3306
    success "MariaDB installed."
}

install_mysql() {
    if package_installed mysql-server; then
        success "MySQL server is already installed."
        return 0
    fi

    ask_yes_no "Install MySQL?" || return 1
    info "Installing MySQL..."
    run_apt_install mysql-server || return 1
    systemctl enable --now mysql || return 1

    if command_exists mysql_secure_installation; then
        info "Securing MySQL... Please follow the prompts."
        mysql_secure_installation || error "Warning: mysql_secure_installation did not complete successfully."
    fi

    configure_database_firewall 3306
    success "MySQL installed."
}

set_postgres_password() {
    local pg_pass pg_pass_sql

    read -r -s -p "Enter new password for postgres database user (leave empty to skip): " pg_pass
    echo

    [[ -n "$pg_pass" ]] || {
        info "PostgreSQL password change skipped."
        return 0
    }

    # SQL string literals escape a single quote by doubling it.
    pg_pass_sql=${pg_pass//\'/\'\'}

    if command_exists runuser; then
        printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$pg_pass_sql" \
            | runuser -u postgres -- psql -v ON_ERROR_STOP=1 >/dev/null
    else
        die "runuser is required to configure the postgres account."
    fi
}

install_postgresql() {
    if package_installed postgresql; then
        success "PostgreSQL server is already installed."
        return 0
    fi

    ask_yes_no "Install PostgreSQL?" || return 1
    info "Installing PostgreSQL..."
    run_apt_install postgresql postgresql-contrib || return 1
    systemctl enable --now postgresql || return 1

    info "Setting postgres user password..."
    set_postgres_password || return 1

    configure_database_firewall 5432
    success "PostgreSQL installed."
}

install_mongodb() {
    if package_installed mongodb-org || command_exists mongod; then
        success "MongoDB is already installed."
        return 0
    fi

    ask_yes_no "Install MongoDB?" || return 1
    info "Installing MongoDB..."

    run_apt_install gnupg curl lsb-release ca-certificates || return 1

    curl -fsSL 'https://pgp.mongodb.com/server-6.0.asc' \
        | gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-6.0-archive-keyring.gpg || return 1

    local codename
    codename="$(lsb_release -cs)"
    [[ -n "$codename" ]] || return 1

    printf '%s\n' \
        "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0-archive-keyring.gpg] https://repo.mongodb.org/apt/debian ${codename}/mongodb-org/6.0 main" \
        > /etc/apt/sources.list.d/mongodb-org-6.0.list || return 1

    apt update || return 1
    run_apt_install mongodb-org || {
        error "MongoDB installation failed. The pinned MongoDB 6.0 repository may not support this Debian release."
        return 1
    }

    systemctl enable --now mongod || return 1
    configure_database_firewall 27017
    success "MongoDB installed. Use 'mongosh' for shell access."
}

install_redis() {
    if package_installed valkey-server || command_exists valkey-server; then
        error "Valkey is already installed. Redis and Valkey both use TCP/6379 by default; remove/disable Valkey first or keep Valkey."
        return 1
    fi

    if package_installed redis-server || command_exists redis-server; then
        success "Redis Open Source is already installed."
        return 0
    fi

    ask_yes_no "Install Redis Open Source?" || return 1
    info "Installing Redis Open Source from the official Redis APT repository..."

    run_apt_install lsb-release curl gpg ca-certificates || return 1

    curl -fsSL 'https://packages.redis.io/gpg' \
        | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg || return 1
    chmod 0644 /usr/share/keyrings/redis-archive-keyring.gpg || return 1

    local codename
    codename="$(lsb_release -cs)"
    [[ -n "$codename" ]] || return 1

    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${codename} main" \
        > /etc/apt/sources.list.d/redis.list || return 1

    apt update || return 1
    run_apt_install redis || return 1
    systemctl enable --now redis-server || return 1

    configure_database_firewall 6379
    success "Redis Open Source installed."
}

ensure_valkey_repository() {
    # Debian 13 contains Valkey in the regular repository. Debian 12 provides
    # it through bookworm-backports. Add backports only when the package is
    # otherwise unavailable.
    package_available valkey-server && return 0

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${VERSION_CODENAME:-}" == 'bookworm' ]]; then
        info "Valkey is not available in the active APT sources; enabling Debian bookworm-backports..."
        printf '%s\n' \
            'deb http://deb.debian.org/debian bookworm-backports main' \
            > /etc/apt/sources.list.d/bookworm-backports.list || return 1
        apt update || return 1
    fi

    package_available valkey-server
}

install_valkey() {
    if package_installed redis-server || command_exists redis-server; then
        error "Redis Open Source is already installed. Redis and Valkey both use TCP/6379 by default; remove/disable Redis first or keep Redis."
        return 1
    fi

    if package_installed valkey-server || command_exists valkey-server; then
        success "Valkey is already installed."
        return 0
    fi

    ask_yes_no "Install Valkey?" || return 1
    info "Installing Valkey from Debian packages..."

    ensure_valkey_repository || {
        error "Valkey is not available from the configured Debian repositories."
        return 1
    }

    run_apt_install valkey-server valkey-tools || return 1
    systemctl enable --now valkey-server || return 1

    configure_database_firewall 6379
    success "Valkey installed."
}

detect_lsphp_versions() {
    apt-cache search --names-only '^lsphp[0-9][0-9]$' \
        | awk '{print $1}' \
        | grep -E '^lsphp[0-9][0-9]$' \
        | sort -Vr
}

choose_lsphp_version() {
    local -n out_full="$1"
    local -n out_version="$2"
    local available_versions choice index i digits ver
    local -a versions_array

    add_litespeed_repository || return 1
    info "Detecting available LiteSpeed PHP (LSPHP) versions..."
    available_versions="$(detect_lsphp_versions)"
    [[ -n "$available_versions" ]] || {
        error "No LSPHP versions were found in the LiteSpeed repository."
        return 1
    }

    mapfile -t versions_array <<< "$available_versions"
    info "Available LSPHP versions:"
    i=1
    for ver in "${versions_array[@]}"; do
        digits="${ver#lsphp}"
        echo "$i) $ver (PHP ${digits:0:1}.${digits:1})"
        ((i++))
    done

    read -r -p "Choose LSPHP version (default 1 for newest): " choice
    choice=${choice:-1}
    if ! [[ "$choice" =~ ^[0-9]+$ ]] \
        || (( choice < 1 || choice > ${#versions_array[@]} )); then
        error "Invalid LSPHP selection."
        return 1
    fi

    index=$((choice - 1))
    out_full="${versions_array[$index]}"
    digits="${out_full#lsphp}"
    out_version="${digits:0:1}.${digits:1}"
}

install_lsphp() {
    local lsphp_full="$1"
    local php_version="$2"
    local database="$3"
    local cache="$4"
    local package suffix
    local -a recommended_suffixes=(curl gd intl mbstring xml zip bcmath bz2 gmp opcache readline imagick)
    local -a recommended_packages=("$lsphp_full" "${lsphp_full}-common")
    local -a database_packages=()
    local -a cache_packages=()
    local -a all_packages=()
    local -a unavailable_recommended=()

    if package_installed "$lsphp_full" || [[ -x "/usr/local/lsws/${lsphp_full}/bin/lsphp" ]]; then
        success "LSPHP $php_version is already installed; checking extension groups."
    else
        info "Installing LSPHP $php_version with recommended extensions..."
    fi

    for suffix in "${recommended_suffixes[@]}"; do
        package="${lsphp_full}-${suffix}"
        if package_available "$package"; then
            recommended_packages+=("$package")
        else
            unavailable_recommended+=("$suffix")
        fi
    done

    choose_optional_php_extensions "$lsphp_full"

    case "$database" in
        mariadb|mysql) package="${lsphp_full}-mysql" ;;
        postgres)      package="${lsphp_full}-pgsql" ;;
        sqlite)        package="${lsphp_full}-sqlite3" ;;
        mongodb)       package="${lsphp_full}-mongodb" ;;
        *)             package='' ;;
    esac
    if [[ -n "$package" ]]; then
        if package_available "$package"; then
            database_packages+=("$package")
        else
            error "LSPHP database package $package is not available and will be skipped."
        fi
    fi

    case "$cache" in
        redis|valkey)
            package="${lsphp_full}-redis"
            if package_available "$package"; then
                cache_packages+=("$package")
            else
                error "LSPHP Redis/Valkey package $package is not available and will be skipped."
            fi
            ;;
    esac

    all_packages=(
        "${recommended_packages[@]}"
        "${database_packages[@]}"
        "${cache_packages[@]}"
        "${PHP_OPTIONAL_PACKAGES_SELECTED[@]}"
    )

    echo
    info "LSPHP extension/package groups:"
    echo "  Recommended: curl gd intl mbstring xml zip bcmath bz2 gmp opcache readline imagick"
    (( ${#unavailable_recommended[@]} == 0 )) || echo "  Unavailable recommended packages: ${unavailable_recommended[*]}"
    (( ${#database_packages[@]} == 0 )) || echo "  Database: ${database_packages[*]}"
    (( ${#cache_packages[@]} == 0 )) || echo "  Cache/KV: ${cache_packages[*]}"
    if (( ${#PHP_OPTIONAL_MODULES_SELECTED[@]} > 0 )); then
        echo "  Optional: ${PHP_OPTIONAL_MODULES_SELECTED[*]}"
    else
        echo "  Optional: none"
    fi

    run_apt_install "${all_packages[@]}" || {
        error "LSPHP $php_version installation failed."
        return 1
    }

    local binary="/usr/local/lsws/${lsphp_full}/bin/lsphp"
    [[ -x "$binary" ]] || {
        error "Expected LSPHP binary was not found at $binary."
        return 1
    }

    mkdir -p /usr/local/lsws/fcgi-bin || return 1
    ln -sfn "$binary" /usr/local/lsws/fcgi-bin/lsphp || return 1
    success "LSPHP $php_version and requested extension groups installed."
}

configure_openlitespeed_lsphp() {
    local lsphp_full="$1"
    local conf='/usr/local/lsws/conf/httpd_config.conf'

    [[ -x /usr/local/lsws/bin/openlitespeed ]] || return 1
    [[ -x "/usr/local/lsws/${lsphp_full}/bin/lsphp" ]] || return 1
    [[ -f "$conf" ]] || return 1

    cp -a "$conf" "${conf}.installer-backup" || return 1
    sed -i -E 's/(address[[:space:]]+\*:)[[:space:]]*8088/\180/' "$conf" || return 1

    /usr/local/lsws/bin/openlitespeed -t || {
        cp -a "${conf}.installer-backup" "$conf" || true
        return 1
    }
    systemctl restart lsws || return 1
}

add_php_repository() {
    info "Adding Ondřej Surý's PHP repository..."

    run_apt_install lsb-release curl ca-certificates gnupg || return 1

    curl -fsSL 'https://packages.sury.org/php/apt.gpg' \
        | gpg --dearmor --yes -o /usr/share/keyrings/sury-php-archive-keyring.gpg || return 1

    local codename
    codename="$(lsb_release -sc)"
    [[ -n "$codename" ]] || return 1

    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/sury-php-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main" \
        > /etc/apt/sources.list.d/sury-php.list || return 1

    apt update || return 1
    success "PHP repository added."
}

detect_php_versions() {
    apt-cache search --names-only '^php[0-9]+\.[0-9]+$' \
        | awk '{print $1}' \
        | grep -E '^php[0-9]+\.[0-9]+$' \
        | sort -Vr
}

choose_php_version() {
    local -n out_full="$1"
    local -n out_version="$2"
    local available_versions php_choice php_index i
    local -a versions_array

    info "Detecting available PHP versions..."
    available_versions="$(detect_php_versions)"
    [[ -n "$available_versions" ]] || return 1

    mapfile -t versions_array <<< "$available_versions"

    info "Available PHP versions:"
    i=1
    for ver in "${versions_array[@]}"; do
        echo "$i) $ver"
        ((i++))
    done

    read -r -p "Choose PHP version (default 1 for newest): " php_choice
    php_choice=${php_choice:-1}

    if ! [[ "$php_choice" =~ ^[0-9]+$ ]] \
        || (( php_choice < 1 || php_choice > ${#versions_array[@]} )); then
        error "Invalid PHP selection."
        return 1
    fi

    php_index=$((php_choice - 1))
    out_full="${versions_array[$php_index]}"
    out_version="${out_full#php}"
}

choose_optional_php_extensions() {
    local php_full="$1"
    local choice
    local answer
    local module
    local package

    PHP_OPTIONAL_PACKAGES_SELECTED=()
    PHP_OPTIONAL_MODULES_SELECTED=()
ADDITIONAL_TOOLS_SELECTED=()
DB_UTILITY_PACKAGES_SELECTED=()

    echo
    info "Optional PHP extensions:"
    echo "1) None (default)"
    echo "2) All (ldap, soap, tidy, snmp)"
    echo "3) Select individually"
    read -r -p "Choose optional PHP extensions [1-3] (default 1): " choice
    choice=${choice:-1}

    case "$choice" in
        1)
            success "No optional PHP extensions selected."
            return 0
            ;;
        2)
            PHP_OPTIONAL_MODULES_SELECTED=(ldap soap tidy snmp)
            ;;
        3)
            for module in ldap soap tidy snmp; do
                read -r -p "Install PHP extension '$module'? [y/n]: " answer
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    PHP_OPTIONAL_MODULES_SELECTED+=("$module")
                fi
            done
            ;;
        *)
            error "Invalid optional-extension selection. No optional extensions will be installed."
            return 0
            ;;
    esac

    for module in "${PHP_OPTIONAL_MODULES_SELECTED[@]}"; do
        package="${php_full}-${module}"
        if package_available "$package"; then
            PHP_OPTIONAL_PACKAGES_SELECTED+=("$package")
        else
            error "Selected optional PHP package $package is not available and will be skipped."
        fi
    done

    if (( ${#PHP_OPTIONAL_MODULES_SELECTED[@]} == 0 )); then
        success "No optional PHP extensions selected."
    else
        info "Selected optional PHP extensions: ${PHP_OPTIONAL_MODULES_SELECTED[*]}"
    fi
}

install_php() {
    local php_full="$1"
    local php_version="$2"
    local server="$3"
    local database="$4"
    local cache="$5"

    local -a php_recommended_packages
    local -a php_database_packages=()
    local -a php_cache_packages=()
    local -a php_server_packages=()
    local -a php_packages

    if package_installed "${php_full}-cli" || command_exists "$php_full"; then
        success "PHP $php_version is already installed; checking extension groups and integration packages."
    else
        info "Installing PHP $php_version and extensions..."
    fi

    # Recommended extensions for common PHP web/application workloads.
    php_recommended_packages=(
        "$php_full"
        "${php_full}-cli"
        "${php_full}-common"
        "${php_full}-curl"
        "${php_full}-gd"
        "${php_full}-intl"
        "${php_full}-mbstring"
        "${php_full}-xml"
        "${php_full}-zip"
        "${php_full}-bcmath"
        "${php_full}-bz2"
        "${php_full}-gmp"
        "${php_full}-opcache"
        "${php_full}-readline"
        "${php_full}-imagick"
    )

    # Let the administrator decide which non-essential extensions to install.
    choose_optional_php_extensions "$php_full"

    # Web-server integration packages.
    case "$server" in
        nginx|caddy|angie|lighttpd)
            php_server_packages+=("${php_full}-fpm")
            ;;
        apache)
            php_server_packages+=("libapache2-mod-${php_full}")
            ;;
    esac

    # Database-specific extensions.
    case "$database" in
        mariadb|mysql)
            php_database_packages+=("${php_full}-mysql")
            ;;
        postgres)
            php_database_packages+=("${php_full}-pgsql")
            ;;
        sqlite)
            php_database_packages+=("${php_full}-sqlite3")
            ;;
        mongodb)
            if package_available "${php_full}-mongodb"; then
                php_database_packages+=("${php_full}-mongodb")
            else
                error "The package ${php_full}-mongodb is not available; MongoDB PHP extension will not be installed automatically."
            fi
            ;;
    esac

    # Redis extension works with both Redis Open Source and Valkey.
    case "$cache" in
        redis|valkey)
            if package_available "${php_full}-redis"; then
                php_cache_packages+=("${php_full}-redis")
            else
                error "The package ${php_full}-redis is not available; the PHP Redis/Valkey extension will not be installed automatically."
            fi
            ;;
    esac

    php_packages=(
        "${php_recommended_packages[@]}"
        "${php_database_packages[@]}"
        "${php_cache_packages[@]}"
        "${PHP_OPTIONAL_PACKAGES_SELECTED[@]}"
        "${php_server_packages[@]}"
    )

    echo
    info "PHP extension/package groups:"
    echo "  Recommended: curl gd intl mbstring xml zip bcmath bz2 gmp opcache readline imagick"
    if (( ${#php_database_packages[@]} > 0 )); then
        echo "  Database:    ${php_database_packages[*]}"
    else
        echo "  Database:    none"
    fi
    if (( ${#php_cache_packages[@]} > 0 )); then
        echo "  Cache/KV:    ${php_cache_packages[*]}"
    else
        echo "  Cache/KV:    none"
    fi
    if (( ${#PHP_OPTIONAL_MODULES_SELECTED[@]} > 0 )); then
        echo "  Optional:    ${PHP_OPTIONAL_MODULES_SELECTED[*]}"
    else
        echo "  Optional:    none"
    fi

    run_apt_install "${php_packages[@]}" || {
        error "PHP $php_version installation failed. One or more extensions may be unavailable for this PHP version."
        return 1
    }

    success "PHP $php_version and requested extension groups installed."
}

php_extension_health_check() {
    local php_full="$1"
    local php_version="$2"
    local database="$3"
    local cache="$4"
    local php_modules
    local module
    local missing=0
    local checked=0

    local -a recommended_modules=(
        curl gd intl mbstring dom SimpleXML xml zip bcmath bz2 gmp "Zend OPcache" readline imagick
    )
    local -a database_modules=()
    local -a cache_modules=()

    if [[ "$php_full" == */* ]]; then
        [[ -x "$php_full" ]] || {
            error "PHP health check cannot run: $php_full was not found."
            return 1
        }
    elif ! command_exists "$php_full"; then
        error "PHP health check cannot run: $php_full was not found."
        return 1
    fi

    php_modules=$("$php_full" -m 2>/dev/null) || {
        error "PHP health check failed: '$php_full -m' returned an error."
        return 1
    }

    case "$database" in
        mariadb|mysql)
            database_modules=(mysqli pdo_mysql)
            ;;
        postgres)
            database_modules=(pgsql pdo_pgsql)
            ;;
        sqlite)
            database_modules=(sqlite3 pdo_sqlite)
            ;;
        mongodb)
            database_modules=(mongodb)
            ;;
    esac

    case "$cache" in
        redis|valkey)
            cache_modules=(redis)
            ;;
    esac

    echo
    info "PHP $php_version extension health check ($php_full -m):"

    check_module_group() {
        local group_name="$1"
        shift
        local ext

        echo "  ${group_name}:"
        if (( $# == 0 )); then
            echo "    (none selected)"
            return 0
        fi

        for ext in "$@"; do
            ((checked++))
            if grep -Fxiq -- "$ext" <<< "$php_modules"; then
                echo -e "    ${GREEN}[OK]${NC} $ext"
            else
                echo -e "    ${RED}[MISSING]${NC} $ext"
                ((missing++))
            fi
        done
    }

    check_module_group "Recommended" "${recommended_modules[@]}"
    check_module_group "Database" "${database_modules[@]}"
    check_module_group "Cache / KV" "${cache_modules[@]}"
    check_module_group "Optional" "${PHP_OPTIONAL_MODULES_SELECTED[@]}"

    if (( missing == 0 )); then
        success "PHP health check passed: all $checked expected modules are loaded."
        return 0
    fi

    error "PHP health check completed with $missing missing module(s) out of $checked checked."
    return 1
}

configure_php_for_server() {
    local server="$1"
    local php_full="$2"
    local php_version="$3"

    case "$server" in
        apache)
            command_exists apache2 || return 1
            a2enmod "php${php_version}" >/dev/null || return 1
            systemctl restart apache2 || return 1
            ;;

        nginx)
            command_exists nginx || return 1
            package_installed "${php_full}-fpm" || return 1

            info "Configuring Nginx for PHP. The default site will be overwritten."
            cat > /etc/nginx/sites-available/default <<EOF_NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/${php_full}-fpm.sock;
    }
}
EOF_NGINX

            nginx -t || return 1
            systemctl restart "${php_full}-fpm" || return 1
            systemctl restart nginx || return 1
            ;;

        angie)
            command_exists angie || return 1
            package_installed "${php_full}-fpm" || return 1

            info "Configuring Angie for PHP. /etc/angie/http.d/default.conf will be overwritten."
            mkdir -p /etc/angie/http.d || return 1
            cat > /etc/angie/http.d/default.conf <<EOF_ANGIE
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.php index.html index.htm;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/${php_full}-fpm.sock;
    }
}
EOF_ANGIE

            angie -t || return 1
            systemctl restart "${php_full}-fpm" || return 1
            systemctl restart angie || return 1
            ;;

        caddy)
            command_exists caddy || return 1
            package_installed "${php_full}-fpm" || return 1

            info "Configuring Caddy for PHP. /etc/caddy/Caddyfile will be overwritten."
            cat > /etc/caddy/Caddyfile <<EOF_CADDY
:80 {
    root * /var/www/html
    php_fastcgi unix//run/php/${php_full}-fpm.sock
    file_server
}
EOF_CADDY

            caddy validate --config /etc/caddy/Caddyfile || return 1
            systemctl restart "${php_full}-fpm" || return 1
            systemctl restart caddy || return 1
            ;;

        lighttpd)
            command_exists lighttpd || return 1
            package_installed "${php_full}-fpm" || return 1

            info "Configuring Lighttpd for PHP-FPM."
            cat > /etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf <<EOF_LIGHTTPD
server.modules += ( "mod_fastcgi" )
fastcgi.server += ( ".php" => ((
    "socket" => "/run/php/${php_full}-fpm.sock",
    "broken-scriptfilename" => "enable"
)) )
EOF_LIGHTTPD
            lighty-enable-mod fastcgi-php-fpm >/dev/null || return 1
            lighttpd -tt -f /etc/lighttpd/lighttpd.conf || return 1
            systemctl restart "${php_full}-fpm" || return 1
            systemctl restart lighttpd || return 1
            ;;

        frankenphp|openlitespeed|skip|"")
            # No external PHP-FPM configuration is required here.
            ;;
    esac
}

install_composer() {
    local php_binary="$1"
    local runtime="${2:-standard}"
    local installer='/tmp/composer-setup.php'
    local expected_checksum=''
    local actual_checksum=''
    local composer_dir='/usr/local/lib/composer'
    local composer_phar="${composer_dir}/composer.phar"
    local composer_wrapper='/usr/local/bin/composer'
    local php_exec=''

    if command_exists composer && composer --version >/dev/null 2>&1; then
        success "Composer is already installed and usable."
        return 0
    fi

    if [[ "$runtime" == 'lsphp' ]]; then
        php_exec="$php_binary"
    else
        php_exec="$(command -v "$php_binary" 2>/dev/null || true)"
    fi

    [[ -n "$php_exec" && -x "$php_exec" ]] || {
        error "Cannot install Composer because the selected PHP runtime is not executable: $php_binary"
        return 1
    }

    info "Installing Composer using the selected PHP runtime..."

    # Composer's documented programmatic installation flow: fetch the current
    # installer signature and verify the downloaded installer with SHA-384.
    expected_checksum="$("$php_exec" -r "copy('https://composer.github.io/installer.sig', 'php://stdout');" 2>/dev/null)" || {
        error "Failed to download the Composer installer checksum."
        return 1
    }

    [[ -n "$expected_checksum" ]] || {
        error "Composer installer checksum is empty."
        return 1
    }

    if ! "$php_exec" -r "copy('https://getcomposer.org/installer', '$installer');"; then
        rm -f "$installer"
        error "Failed to download the Composer installer."
        return 1
    fi

    actual_checksum="$("$php_exec" -r "echo hash_file('sha384', '$installer');")" || {
        rm -f "$installer"
        error "Failed to calculate the Composer installer checksum."
        return 1
    }

    if [[ "$expected_checksum" != "$actual_checksum" ]]; then
        rm -f "$installer"
        error "Composer installer checksum verification failed."
        return 1
    fi

    mkdir -p "$composer_dir" || {
        rm -f "$installer"
        return 1
    }

    if ! "$php_exec" "$installer" --quiet --install-dir="$composer_dir" --filename=composer.phar; then
        rm -f "$installer"
        error "Composer installation failed."
        return 1
    fi
    rm -f "$installer"

    # Use a wrapper tied to the selected runtime. This is especially important
    # for an OpenLiteSpeed-only installation where /usr/bin/php may not exist.
    cat > "$composer_wrapper" <<EOF_COMPOSER_WRAPPER
#!/usr/bin/env bash
exec "$php_exec" "$composer_phar" "\$@"
EOF_COMPOSER_WRAPPER
    chmod 0755 "$composer_wrapper" || return 1

    if "$composer_wrapper" --version >/dev/null 2>&1; then
        success "Composer installed and verified."
        return 0
    fi

    error "Composer was installed but failed its runtime check."
    return 1
}

create_php_test_file() {
    local server="$1"

    ask_yes_no "Create a test PHP file (/var/www/html/info.php) for verification?" || return 0

    mkdir -p /var/www/html || return 1
    printf '%s\n' '<?php phpinfo(); ?>' > /var/www/html/info.php || return 1

    success "Test file created at /var/www/html/info.php."

    case "$server" in
        apache|nginx|caddy|angie|lighttpd)
            echo -e "Open ${GREEN}http://<your_server_ip>/info.php${NC} in your browser."
            ;;
        openlitespeed)
            mkdir -p /usr/local/lsws/Example/html || return 1
            cp /var/www/html/info.php /usr/local/lsws/Example/html/info.php || return 1
            echo -e "Open ${GREEN}http://<your_server_ip>/info.php${NC} in your browser."
            ;;
        frankenphp)
            echo "FrankenPHP must be run manually:"
            echo -e "  ${GREEN}frankenphp php-server --root /var/www/html${NC}"
            echo -e "Then open ${GREEN}http://localhost/info.php${NC}."
            ;;
        skip|"")
            echo "No web server is installed/configured by this script. Configure one manually to view the file."
            ;;
    esac
}

install_package_set_if_available() {
    local label="$1"
    shift
    local packages=()
    local pkg

    for pkg in "$@"; do
        if package_available "$pkg"; then
            packages+=("$pkg")
        else
            error "Warning: $label package '$pkg' is not available in the configured APT repositories."
        fi
    done

    (( ${#packages[@]} > 0 )) || return 0
    info "Installing $label: ${packages[*]}"
    run_apt_install "${packages[@]}"
}

choose_additional_tools() {
    local choice answer tool
    local recommended=(rsync cron unzip dnsutils net-tools wget curl tar zip git mc btop jq htop ncdu lsof logrotate)
    local diagnostics=(iotop iftop nload strace tree tcpdump iproute2)
    local all=("${recommended[@]}" "${diagnostics[@]}")

    ADDITIONAL_TOOLS_SELECTED=()
    echo
    info "Additional server tools:"
    echo "1) Recommended tools (default)"
    echo "2) Recommended + diagnostics/monitoring CLI tools"
    echo "3) Select individually"
    echo "4) None"
    read -r -p "Enter choice [1-4] (default 1): " choice
    choice=${choice:-1}

    case "$choice" in
        1) ADDITIONAL_TOOLS_SELECTED=("${recommended[@]}") ;;
        2) ADDITIONAL_TOOLS_SELECTED=("${all[@]}") ;;
        3)
            for tool in "${all[@]}"; do
                read -r -p "Install '$tool'? [y/n]: " answer
                [[ "$answer" =~ ^[Yy]$ ]] && ADDITIONAL_TOOLS_SELECTED+=("$tool")
            done
            ;;
        4) ;;
        *)
            error "Invalid choice. Defaulting to Recommended tools."
            ADDITIONAL_TOOLS_SELECTED=("${recommended[@]}")
            ;;
    esac

    (( ${#ADDITIONAL_TOOLS_SELECTED[@]} > 0 )) \
        && install_package_set_if_available "additional server tools" "${ADDITIONAL_TOOLS_SELECTED[@]}"
}

install_msmtp_tools() {
    echo
    ask_yes_no "Install msmtp SMTP client/relay tools?" || return 0
    install_package_set_if_available "msmtp" msmtp msmtp-mta ca-certificates
}

install_db_utilities() {
    local db="$1"
    local cache="$2"
    local pkg
    DB_UTILITY_PACKAGES_SELECTED=()

    echo
    ask_yes_no "Install database/cache command-line utilities?" || return 0

    case "$db" in
        mariadb) DB_UTILITY_PACKAGES_SELECTED+=(mariadb-client) ;;
        mysql)
            if package_available mysql-client; then
                DB_UTILITY_PACKAGES_SELECTED+=(mysql-client)
            else
                DB_UTILITY_PACKAGES_SELECTED+=(default-mysql-client)
            fi
            ;;
        postgres) DB_UTILITY_PACKAGES_SELECTED+=(postgresql-client) ;;
        mongodb)
            if package_available mongodb-mongosh; then
                DB_UTILITY_PACKAGES_SELECTED+=(mongodb-mongosh)
            elif package_available mongosh; then
                DB_UTILITY_PACKAGES_SELECTED+=(mongosh)
            fi
            ;;
        sqlite) DB_UTILITY_PACKAGES_SELECTED+=(sqlite3) ;;
    esac

    case "$cache" in
        redis) DB_UTILITY_PACKAGES_SELECTED+=(redis-tools) ;;
        valkey) DB_UTILITY_PACKAGES_SELECTED+=(valkey-tools) ;;
    esac

    if (( ${#DB_UTILITY_PACKAGES_SELECTED[@]} == 0 )); then
        info "No database/cache utility packages are required for the selected components."
        return 0
    fi

    install_package_set_if_available "database/cache utilities" "${DB_UTILITY_PACKAGES_SELECTED[@]}"
}

install_supervisor_tool() {
    echo
    ask_yes_no "Install Supervisor process manager (useful for queues/workers)?" || return 0
    run_apt_install supervisor || return 1
    systemctl enable --now supervisor || return 1
    success "Supervisor installed and running."
}

install_unattended_upgrades_tool() {
    echo
    ask_yes_no "Install and enable unattended security upgrades?" || return 0
    run_apt_install unattended-upgrades apt-listchanges || return 1
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || \
        error "Warning: unattended-upgrades package installed, but automatic configuration returned an error."
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    success "Unattended upgrades installed."
}

install_security_tools() {
    local choice
    echo
    info "Security tools:"
    echo "1) Fail2ban"
    echo "2) CrowdSec + firewall bouncer"
    echo "3) Both"
    echo "4) None (default)"
    read -r -p "Enter choice [1-4] (default 4): " choice
    choice=${choice:-4}

    if [[ "$choice" == 1 || "$choice" == 3 ]]; then
        info "Installing Fail2ban..."
        if run_apt_install fail2ban; then
            systemctl enable --now fail2ban || error "Warning: Fail2ban was installed but could not be started."
        else
            error "Fail2ban installation failed."
        fi
    fi

    if [[ "$choice" == 2 || "$choice" == 3 ]]; then
        info "Installing CrowdSec from its official repository..."
        if run_apt_install curl gnupg apt-transport-https debian-archive-keyring; then
            mkdir -p /etc/apt/keyrings
            if curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
                | gpg --dearmor --yes -o /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg; then
                cat > /etc/apt/sources.list.d/crowdsec_crowdsec.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main
EOF
                if apt update && run_apt_install crowdsec; then
                    systemctl enable --now crowdsec || error "Warning: CrowdSec was installed but could not be started."
                    if package_available crowdsec-firewall-bouncer-iptables; then
                        run_apt_install crowdsec-firewall-bouncer-iptables \
                            || error "Warning: CrowdSec firewall bouncer installation failed."
                    else
                        error "Warning: CrowdSec firewall bouncer package is unavailable. CrowdSec will detect threats but may not enforce decisions."
                    fi
                else
                    error "CrowdSec installation failed."
                fi
            else
                error "Failed to add the CrowdSec signing key."
            fi
        fi
    fi

    [[ "$choice" =~ ^[1-4]$ ]] || error "Invalid security choice; no security package was installed."
}

install_netdata_tool() {
    echo
    ask_yes_no "Install Netdata monitoring agent?" || return 0

    info "Installing Netdata using the official native-package installer..."
    local installer='/tmp/netdata-kickstart.sh'
    if ! curl -fsSL https://get.netdata.cloud/kickstart.sh -o "$installer"; then
        error "Failed to download Netdata installer."
        return 1
    fi
    if ! sh "$installer" --stable-channel --native-only --non-interactive; then
        rm -f "$installer"
        error "Netdata installation failed."
        return 1
    fi
    rm -f "$installer"
    systemctl enable --now netdata >/dev/null 2>&1 || true
    success "Netdata installed. Its web UI is intentionally not opened in UFW automatically."
}

install_certbot_tool() {
    local server="$1"
    local packages=(certbot)

    echo
    if [[ "$server" == 'caddy' ]]; then
        info "Caddy provides automatic HTTPS natively; Certbot is usually unnecessary."
    fi
    ask_yes_no "Install Certbot tooling for TLS certificates?" || return 0

    case "$server" in
        apache) packages+=(python3-certbot-apache) ;;
        nginx) packages+=(python3-certbot-nginx) ;;
        *)
            info "No dedicated Certbot plugin is selected for $server; base Certbot will be installed for webroot/standalone/manual use."
            ;;
    esac

    install_package_set_if_available "Certbot" "${packages[@]}" || return 1
    success "Certbot tooling installed. Certificate issuance is not run automatically because it requires a real DNS name and deployment choice."
}

service_health_line() {
    local label="$1" service="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} $label ($service)"
    else
        echo -e "  ${RED}[FAIL]${NC} $label ($service)"
    fi
}

port_health_line() {
    local port="$1"
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
        echo -e "  ${GREEN}[OK]${NC} TCP/$port listening"
    else
        echo -e "  ${YELLOW}[WARN]${NC} TCP/$port not listening"
    fi
}

server_health_check() {
    local server="$1" db="$2" cache="$3" php_installed="$4" php_binary="$5"
    local service=''

    echo
    success "-------------------------------------"
    success "       Final Server Health Check"
    success "-------------------------------------"

    if service="$(server_service_name "$server" 2>/dev/null)"; then
        service_health_line "Web server" "$service"
    elif [[ "$server" == 'frankenphp' ]]; then
        command_exists frankenphp \
            && echo -e "  ${GREEN}[OK]${NC} FrankenPHP binary" \
            || echo -e "  ${RED}[FAIL]${NC} FrankenPHP binary"
    else
        echo "  [SKIP] Web server"
    fi

    if [[ "$php_installed" == true ]]; then
        if [[ -x "$php_binary" ]] || command_exists "$php_binary"; then
            echo -e "  ${GREEN}[OK]${NC} PHP runtime ($php_binary)"
        else
            echo -e "  ${RED}[FAIL]${NC} PHP runtime ($php_binary)"
        fi
        case "$server" in
            nginx|caddy|angie|lighttpd)
                service_health_line "PHP-FPM" "$(basename "$php_binary")-fpm"
                ;;
        esac
    fi

    case "$db" in
        mariadb) service_health_line "MariaDB" mariadb ;;
        mysql) service_health_line "MySQL" mysql ;;
        postgres) service_health_line "PostgreSQL" postgresql ;;
        mongodb) service_health_line "MongoDB" mongod ;;
        sqlite) echo -e "  ${GREEN}[OK]${NC} SQLite is serverless" ;;
    esac

    case "$cache" in
        redis) service_health_line "Redis" redis-server ;;
        valkey) service_health_line "Valkey" valkey-server ;;
    esac

    command_exists ss && port_health_line 80
    command_exists ss && port_health_line 443

    if command_exists curl && [[ "$server" != 'skip' && "$server" != 'frankenphp' ]]; then
        if curl -fsSI --max-time 5 http://127.0.0.1/ >/dev/null 2>&1; then
            echo -e "  ${GREEN}[OK]${NC} HTTP request to 127.0.0.1"
        else
            echo -e "  ${YELLOW}[WARN]${NC} HTTP request to 127.0.0.1 failed"
        fi
    fi

    if command_exists composer && composer --version >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} Composer"
    else
        echo -e "  ${YELLOW}[WARN]${NC} Composer not installed or not usable"
    fi

    if command_exists ufw; then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            echo -e "  ${GREEN}[OK]${NC} UFW active"
        else
            echo -e "  ${YELLOW}[WARN]${NC} UFW installed but inactive"
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} UFW not installed"
    fi

    if package_installed unattended-upgrades; then
        echo -e "  ${GREEN}[OK]${NC} unattended-upgrades installed"
    else
        echo -e "  ${YELLOW}[WARN]${NC} unattended-upgrades not installed"
    fi

    if package_installed fail2ban; then service_health_line "Fail2ban" fail2ban; fi
    if package_installed crowdsec; then service_health_line "CrowdSec" crowdsec; fi
    if package_installed supervisor; then service_health_line "Supervisor" supervisor; fi
    if command_exists netdata || package_installed netdata; then service_health_line "Netdata" netdata; fi
}

server_service_name() {
    case "$1" in
        apache) echo apache2 ;;
        nginx) echo nginx ;;
        caddy) echo caddy ;;
        angie) echo angie ;;
        lighttpd) echo lighttpd ;;
        openlitespeed) echo lsws ;;
        *) return 1 ;;
    esac
}

main() {
    local server_selected='skip'
    local server_active='skip'
    local server_installed=false
    local db_selected='skip'
    local db_active='skip'
    local db_installed=false
    local cache_selected='skip'
    local cache_active='skip'
    local cache_installed=false
    local php_full=''
    local php_version=''
    local php_installed=false
    local composer_installed=false
    local server_choice db_choice cache_choice

    clear || true
    success "PHP Server Installer (Web/App Server, Database, PHP)"
    info "This script will update packages and install components if not present."

    require_root
    require_debian

    info "Updating package list..."
    apt update || die "Package list update failed. Check network access and repositories."

    info "Upgrading installed packages..."
    DEBIAN_FRONTEND=noninteractive apt upgrade -y \
        || die "Package upgrade failed."

    echo
    info "Choose web/app server:"
    echo "1) Apache (default - LAMP)"
    echo "2) Nginx (LEMP)"
    echo "3) Caddy"
    echo "4) FrankenPHP"
    echo "5) Angie Web Server"
    echo "6) Lighttpd"
    echo "7) OpenLiteSpeed (native LSPHP runtime)"
    echo "8) Skip server installation"
    read -r -p "Enter choice [1-8] (default 1): " server_choice
    server_choice=${server_choice:-1}

    case "$server_choice" in
        1) server_selected='apache' ;;
        2) server_selected='nginx' ;;
        3) server_selected='caddy' ;;
        4) server_selected='frankenphp' ;;
        5) server_selected='angie' ;;
        6) server_selected='lighttpd' ;;
        7) server_selected='openlitespeed' ;;
        8) server_selected='skip' ;;
        *)
            error "Invalid choice. Defaulting to Apache."
            server_selected='apache'
            ;;
    esac

    case "$server_selected" in
        apache)
            if install_apache; then server_active='apache'; server_installed=true; else info "Apache installation skipped or failed."; fi
            ;;
        nginx)
            if install_nginx; then server_active='nginx'; server_installed=true; else info "Nginx installation skipped or failed."; fi
            ;;
        caddy)
            if install_caddy; then server_active='caddy'; server_installed=true; else info "Caddy installation skipped or failed."; fi
            ;;
        frankenphp)
            if install_frankenphp; then server_active='frankenphp'; server_installed=true; else info "FrankenPHP installation skipped or failed."; fi
            ;;
        angie)
            if install_angie; then server_active='angie'; server_installed=true; else info "Angie installation skipped or failed."; fi
            ;;
        lighttpd)
            if install_lighttpd; then server_active='lighttpd'; server_installed=true; else info "Lighttpd installation skipped or failed."; fi
            ;;
        openlitespeed)
            if install_openlitespeed; then server_active='openlitespeed'; server_installed=true; else info "OpenLiteSpeed installation skipped or failed."; fi
            ;;
        skip)
            info "Skipping server installation."
            ;;
    esac

    echo
    info "Choose database:"
    echo "1) MariaDB (default)"
    echo "2) MySQL"
    echo "3) PostgreSQL"
    echo "4) MongoDB"
    echo "5) SQLite (PHP extension only - no server)"
    echo "6) Skip database installation"
    read -r -p "Enter choice [1-6] (default 1): " db_choice
    db_choice=${db_choice:-1}

    case "$db_choice" in
        1) db_selected='mariadb' ;;
        2) db_selected='mysql' ;;
        3) db_selected='postgres' ;;
        4) db_selected='mongodb' ;;
        5) db_selected='sqlite' ;;
        6) db_selected='skip' ;;
        *)
            error "Invalid choice. Defaulting to MariaDB."
            db_selected='mariadb'
            ;;
    esac

    case "$db_selected" in
        mariadb)
            if install_mariadb; then db_active='mariadb'; db_installed=true; else info "MariaDB installation skipped or failed."; fi
            ;;
        mysql)
            if install_mysql; then db_active='mysql'; db_installed=true; else info "MySQL installation skipped or failed."; fi
            ;;
        postgres)
            if install_postgresql; then db_active='postgres'; db_installed=true; else info "PostgreSQL installation skipped or failed."; fi
            ;;
        mongodb)
            if install_mongodb; then db_active='mongodb'; db_installed=true; else info "MongoDB installation skipped or failed."; fi
            ;;
        sqlite)
            db_active='sqlite'
            db_installed=true
            info "SQLite is serverless; the matching PHP extension will be selected if PHP is installed."
            ;;
        skip)
            info "Skipping database installation."
            ;;
    esac

    echo
    info "Choose cache / key-value store:"
    echo "1) Redis Open Source"
    echo "2) Valkey"
    echo "3) Skip cache/key-value store installation (default)"
    read -r -p "Enter choice [1-3] (default 3): " cache_choice
    cache_choice=${cache_choice:-3}

    case "$cache_choice" in
        1) cache_selected='redis' ;;
        2) cache_selected='valkey' ;;
        3) cache_selected='skip' ;;
        *)
            error "Invalid choice. Defaulting to Skip."
            cache_selected='skip'
            ;;
    esac

    case "$cache_selected" in
        redis)
            if install_redis; then cache_active='redis'; cache_installed=true; else info "Redis installation skipped or failed."; fi
            ;;
        valkey)
            if install_valkey; then cache_active='valkey'; cache_installed=true; else info "Valkey installation skipped or failed."; fi
            ;;
        skip)
            info "Skipping cache/key-value store installation."
            ;;
    esac

    echo
    local php_binary=''
    local php_runtime='standard'
    local php_requested=false
    local composer_requested=false

    if ask_yes_no "Install PHP?"; then
        php_requested=true

        if [[ "$server_active" == 'openlitespeed' ]]; then
            php_runtime='lsphp'
            # OpenLiteSpeed uses its own LiteSpeed PHP packages/repository path;
            # the Surý PHP repository is deliberately not added here.
            choose_lsphp_version php_full php_version || die "No valid LSPHP version was selected."
            php_binary="/usr/local/lsws/${php_full}/bin/lsphp"

            if install_lsphp "$php_full" "$php_version" "$db_active" "$cache_active"; then
                php_installed=true
                if configure_openlitespeed_lsphp "$php_full"; then
                    success "Native LSPHP integration for OpenLiteSpeed configured."
                else
                    error "LSPHP is installed, but OpenLiteSpeed configuration failed."
                fi
            else
                info "LSPHP installation skipped or failed."
            fi
        else
            # Only add the external PHP repository after the administrator has
            # explicitly requested PHP installation.
            add_php_repository || die "Failed to configure the PHP repository."
            choose_php_version php_full php_version || die "No valid PHP version was selected."
            php_binary="$php_full"

            if install_php "$php_full" "$php_version" "$server_active" "$db_active" "$cache_active"; then
                php_installed=true

                if [[ "$server_installed" == true ]]; then
                    if configure_php_for_server "$server_active" "$php_full" "$php_version"; then
                        success "PHP integration for ${server_active} configured."
                    else
                        error "PHP is installed, but configuration for ${server_active} failed."
                    fi
                fi
            else
                info "PHP installation skipped or failed."
            fi
        fi
    else
        info "Skipping PHP installation. No PHP repository will be added."
    fi

    if [[ "$php_installed" == true ]]; then
        echo
        if ask_yes_no "Install Composer?"; then
            composer_requested=true
            if install_composer "$php_binary" "$php_runtime"; then
                composer_installed=true
            else
                error "Composer installation failed."
            fi
        else
            info "Skipping Composer installation."
        fi

        php_extension_health_check "$php_binary" "$php_version" "$db_active" "$cache_active" \
            || error "One or more expected PHP extensions are not loaded. Review the health-check output above."

        echo
        create_php_test_file "$server_active" || error "Failed to create the PHP test file."
    elif [[ "$php_requested" == true ]]; then
        error "PHP was requested but is not available; Composer and PHP-specific checks were skipped."
    fi

    # Optional server administration and operations tooling.
    choose_additional_tools || error "One or more additional server tools failed to install."
    install_db_utilities "$db_active" "$cache_active" || error "One or more database/cache utilities failed to install."
    install_msmtp_tools || error "msmtp installation failed."
    install_supervisor_tool || error "Supervisor installation failed."
    install_unattended_upgrades_tool || error "Unattended upgrades setup failed."
    install_security_tools || error "One or more security tools failed to install."
    install_netdata_tool || error "Netdata installation failed."
    install_certbot_tool "$server_active" || error "Certbot installation failed."

    info "Cleaning up unused packages..."
    apt autoremove -y || error "Warning: apt autoremove failed."

    server_health_check "$server_active" "$db_active" "$cache_active" "$php_installed" "$php_binary"

    echo
    success "-------------------------------------"
    success "       Installation Summary"
    success "-------------------------------------"

    if [[ "$server_installed" == true ]]; then
        echo -e "${YELLOW}Web Server:${NC} $server_active (installed/detected)"
    else
        echo -e "${YELLOW}Web Server:${NC} Not installed by this run (selected: $server_selected)"
    fi

    if [[ "$db_installed" == true ]]; then
        if [[ "$db_active" == 'sqlite' ]]; then
            echo -e "${YELLOW}Database:${NC} SQLite selected (serverless)"
        else
            echo -e "${YELLOW}Database:${NC} $db_active (installed/detected)"
        fi
    else
        echo -e "${YELLOW}Database:${NC} Not installed by this run (selected: $db_selected)"
    fi

    if [[ "$cache_installed" == true ]]; then
        echo -e "${YELLOW}Cache / KV Store:${NC} $cache_active (installed/detected)"
    else
        echo -e "${YELLOW}Cache / KV Store:${NC} Not installed by this run (selected: $cache_selected)"
    fi

    if [[ "$php_installed" == true ]]; then
        if [[ "$php_runtime" == 'lsphp' ]]; then
            echo -e "${YELLOW}PHP Runtime:${NC} LSPHP $php_version (${php_full})"
        else
            echo -e "${YELLOW}PHP Runtime:${NC} PHP $php_version (${php_full})"
        fi
        if [[ "$composer_installed" == true ]] || { command_exists composer && composer --version >/dev/null 2>&1; }; then
            echo -e "${YELLOW}Composer:${NC} Installed"
        elif [[ "$composer_requested" == true ]]; then
            echo -e "${YELLOW}Composer:${NC} Installation requested but not usable"
        else
            echo -e "${YELLOW}Composer:${NC} Not selected"
        fi
    else
        if [[ "$php_requested" == true ]]; then
            echo -e "${YELLOW}PHP Version:${NC} Requested but installation failed/skipped"
        else
            echo -e "${YELLOW}PHP Version:${NC} Not selected"
        fi
        echo -e "${YELLOW}Composer:${NC} Not available without PHP runtime"
    fi

    local service_name=''
    if service_name="$(server_service_name "$server_active" 2>/dev/null)"; then
        echo "Service status command: systemctl status $service_name"
    elif [[ "$server_active" == 'frankenphp' ]]; then
        echo "FrankenPHP was installed as a standalone binary; no systemd service was created."
    fi

    success "Installation complete. Review the summary and test your services."
}

main "$@"
