#!/bin/sh

# Pterodactyl Panel Installer for Alpine Linux
# Dynamic input when running the script - Without SSL for local use

set -e

# Ask user inputs with more validation
echo "=== Pterodactyl Panel Installer (Local Version) ==="
while [ -z "$PANEL_DOMAIN" ]; do
    read -p "Masukkan host untuk panel (contoh: localhost atau IP): " PANEL_DOMAIN
done

while [ -z "$MYSQL_ROOT_PASS" ]; do
    read -p "Masukkan password root MySQL yang akan dibuat: " MYSQL_ROOT_PASS
done

while [ -z "$PANEL_DB_NAME" ]; do
    read -p "Masukkan nama database panel (default: panel): " PANEL_DB_NAME
    PANEL_DB_NAME=${PANEL_DB_NAME:-panel}
done

while [ -z "$PANEL_DB_USER" ]; do
    read -p "Masukkan nama user database (default: pterodactyl): " PANEL_DB_USER
    PANEL_DB_USER=${PANEL_DB_USER:-pterodactyl}
done

while [ -z "$PANEL_DB_PASS" ]; do
    read -p "Masukkan password user database: " PANEL_DB_PASS
done

# Update & install dependencies
echo "[*] Updating system and installing dependencies..."
apk update
apk add --no-cache \
  nginx \
  php81 \
  php81-fpm \
  php81-common \
  php81-curl \
  php81-cli \
  php81-mysqlnd \
  php81-mbstring \
  php81-tokenizer \
  php81-xml \
  php81-gd \
  php81-zip \
  php81-bcmath \
  php81-opcache \
  php81-pdo \
  php81-pdo_mysql \
  php81-fileinfo \
  php81-ctype \
  php81-json \
  php81-session \
  php81-dom \
  php81-simplexml \
  php81-openssl \
  php81-phar \
  mariadb mariadb-client \
  redis \
  curl \
  unzip \
  composer \
  git

# Fix MariaDB directory permissions
echo "[*] Setting up MariaDB directory permissions..."
mkdir -p /var/lib/mysql /run/mysqld
chown -R mysql:mysql /var/lib/mysql /run/mysqld
chmod 777 /run/mysqld

# Try to install Redis extension using PECL if available
echo "[*] Attempting to install Redis extension..."
apk add --no-cache php81-pecl-redis 2>/dev/null || apk add --no-cache php81-redis 2>/dev/null || echo "Redis extension not found, continuing without it..."

# Make sure services directories exist
mkdir -p /run/nginx
mkdir -p /run/php
chown nobody:nobody /run/php

# Configure PHP-FPM to use UNIX socket
echo "[*] Configuring PHP-FPM..."
sed -i 's/listen = 127.0.0.1:9000/listen = \/run\/php\/php8.1-fpm.sock/g' /etc/php81/php-fpm.d/www.conf 2>/dev/null || echo "PHP-FPM config not found at expected location, using default TCP socket"

# Start services properly with better error handling
echo "[*] Starting services..."

# Stop and remove any existing MariaDB files if there are issues
if [ -f /var/lib/mysql/mysql/user.frm ]; then
    echo "MariaDB data directory already exists. Checking if MariaDB is running..."
    if ! pgrep mysqld >/dev/null; then
        echo "MariaDB files exist but service is not running. Cleaning up..."
        killall -9 mysqld 2>/dev/null || true
        rm -f /var/lib/mysql/mysql.sock /run/mysqld/mysqld.sock 2>/dev/null || true
    fi
fi

# Start MariaDB properly
echo "[*] Initializing MariaDB..."
rc-update add mariadb default 2>/dev/null || true
rc-update add redis default 2>/dev/null || true
rc-update add php-fpm81 default 2>/dev/null || true
rc-update add nginx default 2>/dev/null || true

# Stop MariaDB first in case it's running with problems
rc-service mariadb stop 2>/dev/null || true

# Initialize MariaDB if needed
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "[*] First time MariaDB setup..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql || {
        echo "Failed to initialize MariaDB. Trying alternative method...";
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql || {
            echo "ERROR: Could not initialize MariaDB database. Please check your system.";
            exit 1;
        }
    }
fi

# Start services with extended error handling
echo "[*] Starting MariaDB..."
rc-service mariadb start
if ! pgrep mysqld >/dev/null; then
    echo "ERROR: MariaDB failed to start. Checking logs..."
    cat /var/log/mysql/error.log 2>/dev/null || echo "No MariaDB error log found"
    echo "Trying alternative method to start MariaDB..."
    mkdir -p /var/log/mysql
    chown -R mysql:mysql /var/log/mysql
    /usr/bin/mariadbd-safe --user=mysql --datadir=/var/lib/mysql &
    sleep 5
    if ! pgrep mysqld >/dev/null; then
        echo "ERROR: Could not start MariaDB using alternative method. Installation cannot continue."
        exit 1
    else
        echo "MariaDB started successfully using alternative method."
    fi
else
    echo "MariaDB started successfully."
fi

echo "[*] Starting Redis..."
rc-service redis start || echo "Failed to start Redis, continuing anyway..."

echo "[*] Starting PHP-FPM..."
rc-service php-fpm81 start || {
    echo "Failed to start PHP-FPM. Trying to fix socket configuration...";
    sed -i 's/listen = \/run\/php\/php8.1-fpm.sock/listen = 127.0.0.1:9000/g' /etc/php81/php-fpm.d/www.conf 2>/dev/null;
    rc-service php-fpm81 restart || echo "ERROR: Could not start PHP-FPM. Please check your PHP configuration.";
}

echo "[*] Starting Nginx..."
rc-service nginx start || echo "Failed to start Nginx, continuing anyway..."

# Wait for MariaDB to fully start
echo "[*] Waiting for MariaDB to initialize..."
sleep 5

# Check if MariaDB is running
if ! pgrep mysqld >/dev/null; then
    echo "ERROR: MariaDB is not running after waiting. Installation cannot continue."
    exit 1
fi

# Set root password with better error handling
echo "[*] Setting MariaDB root password..."
if mysqladmin -u root password "$MYSQL_ROOT_PASS" 2>/dev/null; then
    echo "Root password set successfully"
else
    echo "Alternative method for setting root password..."
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';" 2>/dev/null || 
    mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$MYSQL_ROOT_PASS');" 2>/dev/null ||
    echo "WARNING: Could not set root password. You may need to set it manually."
fi

# Test MySQL connection with the new password
if mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    echo "Successfully connected to MariaDB with new root password."
else
    echo "WARNING: Could not connect with new root password. Trying without password..."
    if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
        echo "Connected to MariaDB without password. Will proceed without password."
        MYSQL_ROOT_PASS=""
    else
        echo "ERROR: Cannot connect to MariaDB. Please check your MariaDB installation."
        exit 1
    fi
fi

# Secure MariaDB with proper error handling
echo "[*] Securing MariaDB..."
mysql -u root ${MYSQL_ROOT_PASS:+-p"$MYSQL_ROOT_PASS"} <<EOF || echo "Warning: Some MariaDB security operations failed, continuing..."
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Create Database & User with better error handling
echo "[*] Creating database and user..."
mysql -u root ${MYSQL_ROOT_PASS:+-p"$MYSQL_ROOT_PASS"} <<MYSQL_SCRIPT || echo "Warning: Database creation had errors, continuing..."
CREATE DATABASE IF NOT EXISTS $PANEL_DB_NAME;
CREATE USER IF NOT EXISTS '$PANEL_DB_USER'@'127.0.0.1' IDENTIFIED BY '$PANEL_DB_PASS';
CREATE USER IF NOT EXISTS '$PANEL_DB_USER'@'localhost' IDENTIFIED BY '$PANEL_DB_PASS';
GRANT ALL PRIVILEGES ON $PANEL_DB_NAME.* TO '$PANEL_DB_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON $PANEL_DB_NAME.* TO '$PANEL_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Download Pterodactyl with better error handling
echo "[*] Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

for i in {1..3}; do
    if curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz; then
        break
    else
        echo "Download attempt $i failed. Retrying..."
        [ $i -eq 3 ] && { echo "Failed to download Pterodactyl panel"; exit 1; }
        sleep 2
    fi
done

tar -xzvf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 /var/www/pterodactyl

# Install PHP dependencies with better error handling
echo "[*] Installing PHP dependencies..."
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction || {
    echo "Composer install failed. Trying with --ignore-platform-reqs";
    composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-reqs;
}

# Set permissions
chown -R nobody:nobody /var/www/pterodactyl
find /var/www/pterodactyl/storage -type d -exec chmod 755 {} \;
find /var/www/pterodactyl/storage -type f -exec chmod 644 {} \;

# Setup Environment
cp -f .env.example .env

# Set environment values
sed -i "s|APP_URL=.*|APP_URL=http://$PANEL_DOMAIN|" .env
sed -i "s/APP_ENVIRONMENT=.*/APP_ENVIRONMENT=production/" .env
sed -i "s/LOG_CHANNEL=.*/LOG_CHANNEL=daily/" .env
sed -i "s/DB_HOST=.*/DB_HOST=127.0.0.1/" .env
sed -i "s/DB_PORT=.*/DB_PORT=3306/" .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=$PANEL_DB_NAME/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=$PANEL_DB_USER/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$PANEL_DB_PASS/" .env
sed -i "s/CACHE_DRIVER=.*/CACHE_DRIVER=file/" .env
sed -i "s/SESSION_DRIVER=.*/SESSION_DRIVER=file/" .env
sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=sync/" .env

# Generate app key
php artisan key:generate --force

# Setup database with better error handling
echo "[*] Setting up database..."
php artisan migrate --seed --force || {
    echo "Database migration failed. Checking connection...";
    php artisan db:show || echo "Database connection issue detected";
    echo "Retrying migration with fresh option...";
    php artisan migrate:fresh --seed --force || {
        echo "ERROR: Database migration still failing. Please check your database configuration.";
        echo "You may need to manually run: php artisan migrate --seed --force";
    }
}

# Create admin user
echo "[*] Creating admin user..."
php artisan p:user:make

# Setup cron job
echo "[*] Setting up cron job..."
echo "* * * * * cd /var/www/pterodactyl && php artisan schedule:run >> /dev/null 2>&1" > /etc/crontabs/nobody
rc-service crond restart || rc-service cron restart || echo "Could not restart cron service"

# Configure Nginx with better socket configuration
echo "[*] Configuring Nginx..."

# Check if PHP-FPM is using TCP or socket
PHP_FPM_LISTEN=$(grep -E "^listen\s*=" /etc/php81/php-fpm.d/www.conf | awk '{print $3}')
if [[ "$PHP_FPM_LISTEN" == "/run/php/php8.1-fpm.sock" ]]; then
    # Using socket
    FASTCGI_PASS="unix:/run/php/php8.1-fpm.sock"
else
    # Fallback to TCP
    FASTCGI_PASS="127.0.0.1:9000"
fi

cat <<EOF > /etc/nginx/http.d/pterodactyl.conf
server {
    listen 80;
    server_name $PANEL_DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php index.html index.htm;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass $FASTCGI_PASS;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
    }

    location ~ /\.ht {
        deny all;
    }
    
    location ~ /\.(?!well-known).* {
        deny all;
    }
    
    # Additional security headers
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
}
EOF

# Restart services
echo "[*] Restarting services..."
rc-service php-fpm81 restart || echo "Could not restart PHP-FPM"
rc-service nginx restart || echo "Could not restart Nginx"

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Akses Panel: http://$PANEL_DOMAIN"
echo "Database: $PANEL_DB_NAME | User: $PANEL_DB_USER | Password: $PANEL_DB_PASS"
echo ""
echo "Jika terjadi masalah akses panel, pastikan:"
echo "1. Host $PANEL_DOMAIN dapat diakses"
echo "2. Port 80 sudah terbuka di firewall" 
echo "3. Jalankan 'rc-service nginx restart' jika diperlukan"
echo ""
echo "Status layanan:"
ps aux | grep -E 'nginx|php-fpm|mysql|maria'
echo ""
echo "Untuk memastikan queue worker berjalan, jalankan ini secara manual jika diperlukan:"
echo "cd /var/www/pterodactyl && php artisan queue:work --queue=high,standard,low"
