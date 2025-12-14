#!/bin/bash

# Warning: This script requires root privileges to install packages and manage services.
# Run it as root (e.g., 'sudo bash script.sh') or with sudo.
echo -e "\033[0;31mWARNING: This script requires root privileges. If not run as root or with sudo, it will fail.\033[0m"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

clear
echo -e "${GREEN}PHP Server Installer (Web/App Server, Database, PHP)${NC}"
echo -e "${YELLOW}This script will update packages and install components if not present.${NC}"

# Check for Debian-based system
if ! command -v apt > /dev/null 2>&1; then
    echo -e "${RED}Error: This script requires a Debian-based system with apt.${NC}"
    exit 1
fi

# Update packages
echo -e "${YELLOW}Updating package list...${NC}"
apt update -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Update failed! Check your network or privileges.${NC}"
    exit 1
fi
apt upgrade -y
if [ $? -ne 0 ]; then
    echo -e "${RED}Upgrade failed! Check your network or privileges.${NC}"
    exit 1
fi

# Choose web/app server
echo -e "${YELLOW}Choose web/app server:${NC}"
echo "1) Apache (default - LAMP)"
echo "2) Nginx (LEMP)"
echo "3) Caddy"
echo "4) FrankenPHP"
echo "5) Skip server installation"
read -p "Enter choice [1-5] (default 1): " server_choice
server_choice=${server_choice:-1}

case $server_choice in
    1) server_type="apache" ;;
    2) server_type="nginx" ;;
    3) server_type="caddy" ;;
    4) server_type="frankenphp" ;;
    5) server_type="skip" ;;
    *) echo -e "${RED}Invalid choice. Defaulting to Apache.${NC}"; server_type="apache" ;;
esac

# Install chosen server
if [ "$server_type" != "skip" ]; then
    case $server_type in
        apache)
            if command -v apache2 > /dev/null 2>&1; then
                echo -e "${GREEN}Apache is already installed.${NC}"
            else
                read -p "Install Apache? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing Apache...${NC}"
                    apt install -y apache2
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start apache2 || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable apache2 > /dev/null 2>&1
                    echo -e "${GREEN}Apache installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 'Apache Full' > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        nginx)
            if command -v nginx > /dev/null 2>&1; then
                echo -e "${GREEN}Nginx is already installed.${NC}"
            else
                read -p "Install Nginx? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing Nginx...${NC}"
                    apt install -y nginx
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start nginx || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable nginx > /dev/null 2>&1
                    echo -e "${GREEN}Nginx installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 'Nginx Full' > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        caddy)
            if command -v caddy > /dev/null 2>&1; then
                echo -e "${GREEN}Caddy is already installed.${NC}"
            else
                read -p "Install Caddy? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing Caddy...${NC}"
                    apt install -y debian-keyring debian-archive-keyring apt-transport-https
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
                    apt update
                    apt install -y caddy
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start caddy || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable caddy > /dev/null 2>&1
                    echo -e "${GREEN}Caddy installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow http > /dev/null 2>&1; ufw allow https > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        frankenphp)
            if command -v frankenphp > /dev/null 2>&1; then
                echo -e "${GREEN}FrankenPHP is already installed.${NC}"
            else
                read -p "Install FrankenPHP? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing FrankenPHP (downloading binary)...${NC}"
                    curl -Lo /usr/local/bin/frankenphp https://github.com/dunglas/frankenphp/releases/latest/download/frankenphp-linux-x86_64
                    chmod +x /usr/local/bin/frankenphp
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    echo -e "${GREEN}FrankenPHP installed. Run it manually (e.g., frankenphp php-server /path/to/app).${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow http > /dev/null 2>&1; ufw allow https > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
    esac
else
    echo -e "${YELLOW}Skipping server installation.${NC}"
fi

# Choose database
echo -e "${YELLOW}Choose database:${NC}"
echo "1) MariaDB (default)"
echo "2) MySQL"
echo "3) PostgreSQL"
echo "4) MongoDB"
echo "5) SQLite (PHP extension only - no server)"
echo "6) Skip database installation"
read -p "Enter choice [1-6] (default 1): " db_choice
db_choice=${db_choice:-1}

case $db_choice in
    1) db_type="mariadb" ;;
    2) db_type="mysql" ;;
    3) db_type="postgres" ;;
    4) db_type="mongodb" ;;
    5) db_type="sqlite" ;;
    6) db_type="skip" ;;
    *) echo -e "${RED}Invalid choice. Defaulting to MariaDB.${NC}"; db_type="mariadb" ;;
esac

# Install chosen database
if [ "$db_type" != "skip" ]; then
    case $db_type in
        mariadb)
            if command -v mariadb > /dev/null 2>&1; then
                echo -e "${GREEN}MariaDB is already installed.${NC}"
            else
                read -p "Install MariaDB? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing MariaDB...${NC}"
                    apt install -y mariadb-server
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start mariadb || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable mariadb > /dev/null 2>&1
                    echo -e "${YELLOW}Securing MariaDB... Please follow the prompts.${NC}"
                    mysql_secure_installation
                    echo -e "${GREEN}MariaDB installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 3306/tcp > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        mysql)
            if command -v mysql > /dev/null 2>&1; then
                echo -e "${GREEN}MySQL is already installed.${NC}"
            else
                read -p "Install MySQL? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing MySQL...${NC}"
                    apt install -y mysql-server
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start mysql || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable mysql > /dev/null 2>&1
                    echo -e "${YELLOW}Securing MySQL... Please follow the prompts.${NC}"
                    mysql_secure_installation
                    echo -e "${GREEN}MySQL installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 3306/tcp > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        postgres)
            if command -v psql > /dev/null 2>&1; then
                echo -e "${GREEN}PostgreSQL is already installed.${NC}"
            else
                read -p "Install PostgreSQL? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing PostgreSQL...${NC}"
                    apt install -y postgresql postgresql-contrib
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed!${NC}"; exit 1; fi
                    systemctl start postgresql || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable postgresql > /dev/null 2>&1
                    echo -e "${YELLOW}Setting postgres user password...${NC}"
                    read -s -p "Enter new password for postgres database user: " pg_pass
                    echo # new line after password input
                    sudo -u postgres PGPASSWORD="$pg_pass" psql -c "ALTER USER postgres WITH PASSWORD '$pg_pass';"
                    echo -e "${GREEN}PostgreSQL installed.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 5432/tcp > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        mongodb)
            if command -v mongod > /dev/null 2>&1; then
                echo -e "${GREEN}MongoDB is already installed.${NC}"
            else
                read -p "Install MongoDB? [y/n]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Installing MongoDB...${NC}"
                    apt install -y gnupg curl
                    curl -fsSL https://pgp.mongodb.com/server-6.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0-archive-keyring.gpg
                    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0-archive-keyring.gpg ] https://repo.mongodb.org/apt/debian $(lsb_release -cs)/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list > /dev/null
                    apt update
                    apt install -y mongodb-org
                    if [ $? -ne 0 ]; then echo -e "${RED}Installation failed! The MongoDB repo might not yet support your OS version.${NC}"; exit 1; fi
                    systemctl start mongod || { echo -e "${RED}Start failed!${NC}"; exit 1; }
                    systemctl enable mongod > /dev/null 2>&1
                    echo -e "${GREEN}MongoDB installed. Use 'mongosh' for shell access.${NC}"
                    if command -v ufw > /dev/null 2>&1; then ufw allow 27017/tcp > /dev/null 2>&1; ufw reload > /dev/null 2>&1; echo -e "${GREEN}Firewall configured.${NC}"; fi
                else
                    echo -e "${RED}Skipping.${NC}"
                fi
            fi
            ;;
        sqlite)
            echo -e "${YELLOW}SQLite is serverless; only installing PHP extension (if PHP is installed later).${NC}"
            ;;
    esac
else
    echo -e "${YELLOW}Skipping database installation.${NC}"
fi

# Initialize php_version variable
php_version=""

# Add PHP repository
echo -e "${YELLOW}Adding Ondřej Surý's PHP repository...${NC}"
apt install -y lsb-release curl ca-certificates gnupg
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install dependencies for repo addition!${NC}"
    exit 1
fi
curl -sS https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php-archive-keyring.gpg
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download PHP repo key! Check your network.${NC}"
    exit 1
fi
echo "deb [signed-by=/usr/share/keyrings/sury-php-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list > /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to add PHP repo to sources.list!${NC}"
    exit 1
fi
apt update
if [ $? -ne 0 ]; then
    echo -e "${RED}Update after adding PHP repository failed!${NC}"
    exit 1
fi
echo -e "${GREEN}PHP repository added.${NC}"

# Dynamically detect available PHP versions from apt cache
echo -e "${YELLOW}Detecting available PHP versions...${NC}"
available_versions=$(apt-cache search '^php[0-9]\.[0-9]+$' | awk '{print $1}' | sort -Vr)
if [ -z "$available_versions" ]; then
    echo -e "${RED}No PHP versions found in apt cache. Ensure the repo is set up correctly.${NC}"
    exit 1
fi

# Present menu of available versions
echo -e "${YELLOW}Available PHP versions:${NC}"
i=1
mapfile -t versions_array <<< "$available_versions"
for ver in "${versions_array[@]}"; do
    echo "$i) $ver"
    i=$((i+1))
done
read -p "Choose PHP version (default 1 for newest): " php_choice
php_choice=${php_choice:-1}
php_index=$((php_choice-1))

if [[ ! "${versions_array[$php_index]}" ]]; then
    echo -e "${RED}Invalid selection. Exiting.${NC}"
    exit 1
fi
php_full="${versions_array[$php_index]}"
php_version=$(echo "$php_full" | sed 's/php//')

# Install chosen PHP version if not already installed
if command -v "$php_full" > /dev/null 2>&1; then
    echo -e "${GREEN}PHP $php_version is already installed.${NC}"
else
    read -p "Install PHP $php_version with common extensions? [y/n]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installing PHP $php_version and extensions...${NC}"
        php_packages="$php_full $php_full-cli $php_full-curl $php_full-gd $php_full-intl $php_full-mbstring $php_full-xml $php_full-zip $php_full-bcmath $php_full-soap $php_full-opcache $php_full-imagick $php_full-ldap"
        
        if [ "$server_type" = "nginx" ] || [ "$server_type" = "caddy" ]; then
            php_packages="$php_packages $php_full-fpm"
        elif [ "$server_type" = "apache" ]; then
            php_packages="$php_packages libapache2-mod-$php_full"
        fi

        case $db_type in
            mariadb|mysql) php_packages="$php_packages $php_full-mysql" ;;
            postgres) php_packages="$php_packages $php_full-pgsql" ;;
            mongodb) 
                php_packages="$php_packages php-pear $php_full-dev"
                ;;
            sqlite) php_packages="$php_packages $php_full-sqlite3" ;;
        esac

        apt install -y $php_packages
        if [ $? -ne 0 ]; then
            echo -e "${RED}PHP $php_version installation failed (some extensions may not be available for this version)!${NC}"
            exit 1
        fi

        if [ "$db_type" = "mongodb" ]; then
            echo -e "${YELLOW}Installing MongoDB PHP extension via PECL...${NC}"
            pecl install mongodb
            if [ $? -ne 0 ]; then
                echo -e "${RED}MongoDB PECL extension install failed for $php_version!${NC}"; exit 1
            else
                echo "extension=mongodb.so" > "/etc/php/$php_version/mods-available/mongodb.ini"
                phpenmod -v "$php_version" mongodb
            fi
        fi
        
        case $server_type in
            apache) a2enmod "proxy_fcgi setenvif" && a2enconf "$php_full-fpm"; systemctl restart apache2 > /dev/null 2>&1 ;;
            nginx)
                echo -e "${YELLOW}Configuring Nginx for PHP. Default site will be overwritten.${NC}"
                cat > /etc/nginx/sites-available/default <<EOF
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
        fastcgi_pass unix:/run/php/$php_full-fpm.sock;
    }
}
EOF
                systemctl restart "$php_full-fpm" > /dev/null 2>&1 && systemctl restart nginx > /dev/null 2>&1
                ;;
            caddy)
                echo -e "${YELLOW}Configuring Caddy for PHP. Your Caddyfile will be overwritten.${NC}"
                cat > /etc/caddy/Caddyfile <<EOF
:80 {
    root * /var/www/html
    php_fastcgi unix//run/php/$php_full-fpm.sock
    file_server
}
EOF
                systemctl restart "$php_full-fpm" > /dev/null 2>&1 && systemctl restart caddy > /dev/null 2>&1
                ;;
        esac
        echo -e "${GREEN}PHP $php_version installed.${NC}"
        
        echo -e "${YELLOW}Automatically installing Composer...${NC}"
        if ! command -v composer > /dev/null 2>&1; then
            apt install -y composer
            if [ $? -ne 0 ]; then
                echo -e "${YELLOW}Apt install failed; downloading Composer manually...${NC}"
                php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
                php composer-setup.php --install-dir=/usr/local/bin --filename=composer
                rm composer-setup.php
                if [ $? -ne 0 ]; then echo -e "${RED}Composer installation failed!${NC}"; fi
            fi
            if command -v composer > /dev/null 2>&1; then echo -e "${GREEN}Composer installed.${NC}"; fi
        else
            echo -e "${GREEN}Composer is already installed.${NC}"
        fi
    else
        echo -e "${RED}Skipping PHP installation.${NC}"
    fi
fi

# Create PHP Test File if PHP was installed
if [ -n "$php_version" ]; then
    echo -e "${YELLOW}-------------------------------------${NC}"
    read -p "Create a test PHP file (/var/www/html/info.php) for verification? [y/n]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        mkdir -p /var/www/html
        echo "<?php phpinfo(); ?>" > /var/www/html/info.php
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create test file! Check permissions.${NC}"
        else
            echo -e "${GREEN}Test file created at /var/www/html/info.php.${NC}"
            echo -e "${YELLOW}To test it, follow the instructions for your server:${NC}"
            
            case $server_type in
                apache|nginx|caddy)
                    echo -e "-> Open ${GREEN}http://<your_server_ip>/info.php${NC} in your browser."
                    ;;
                frankenphp)
                    echo "-> FrankenPHP must be run manually from the command line."
                    echo "   Run the following command:"
                    echo -e "   ${GREEN}frankenphp php-server --root /var/www/html${NC}"
                    echo -e "-> Then open ${GREEN}http://localhost/info.php${NC} in your browser (on the server itself)."
                    ;;
                skip|*)
                    echo "-> No web server was installed. You will need to configure one manually to view the file."
                    ;;
            esac
        fi
    fi
fi

# Cleanup unused packages
echo -e "${YELLOW}Cleaning up unused packages...${NC}"
apt autoremove -y

# Post-Installation Summary
echo -e "${GREEN}-------------------------------------${NC}"
echo -e "${GREEN}       Installation Summary          ${NC}"
echo -e "${GREEN}-------------------------------------${NC}"
echo -e "${YELLOW}Web Server:${NC} ${server_type:-None installed}"
echo -e "${YELLOW}Database:${NC} ${db_type:-None installed}"
if [[ -n "$php_version" ]]; then
    echo -e "${YELLOW}PHP Version:${NC} $php_version"
    echo -e "${YELLOW}Composer:${NC} $(command -v composer >/dev/null 2>&1 && echo "Installed" || echo "Not installed")"
else
    echo -e "${YELLOW}PHP Version:${NC} Not installed"
fi
echo ""
echo -e "${GREEN}Installation complete! Review the summary and test your services.${NC}"
echo "Example: systemctl status ${server_type:-apache2}"
