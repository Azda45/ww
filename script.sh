#!/bin/sh

# Pterodactyl Panel Installer for Alpine Linux (Simplified Version)
# For local installation without SSL

set -e

# Basic configuration
echo "=== Pterodactyl Panel Installer (Simplified) ==="
while [ -z "$PANEL_DOMAIN" ]; do
    read -p "Masukkan host untuk panel (contoh: localhost atau IP): " PANEL_DOMAIN
done

while [ -z "$PANEL_DB_PASS" ]; do
    read -p "Masukkan password untuk database: " PANEL_DB_PASS
done

# Use fixed names for simplicity
PANEL_DB_NAME="pterodactyl"
PANEL_DB_USER="pterodactyl"

# Update system and install needed packages
echo "[*] Installing dependencies..."
apk update
apk add --no-cache \
  nginx \
  php81 \
  php81-fpm \
  php81-common \
  php81-pdo \
  php81-pdo_mysql \
  php81-mbstring \
  php81-xml \
  php81-tokenizer \
  php81-gd \
  php81-zip \
  php81-bcmath \
  php81-curl \
  php81-ctype \
  php81-fileinfo \
  php81-json \
  php81-session \
  php81-dom \
  php81-openssl \
  php81-simplexml \
  curl \
  unzip \
  git \
  composer \
  sqlite \
  php81-pdo_sqlite

# Fix issues with PHP-FPM socket
mkdir -p /run/php
chown nobody:nobody /run/php

# Start and enable PHP-FPM and Nginx
echo "[*] Starting web services..."
rc-update add php-fpm81 default
rc-update add nginx default

# Stop services to ensure clean start
rc-service php-fpm81 stop
rc-service nginx stop

# Create Pterodactyl directory
echo "[*] Setting up Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

# Download and extract Pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
rm -f panel.tar.gz

# Set permissions
chown -R nobody:nobody /var/www/pterodactyl
find /var/www/pterodactyl/storage -type d -exec chmod 755 {} \;
find /var/www/pterodactyl/storage -type f -exec chmod 644 {} \;

# Install PHP dependencies
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction

# Setup environment file for SQLite
cp -f .env.example .env
sed -i "s|APP_URL=.*|APP_URL=http://$PANEL_DOMAIN|" .env
sed -i "s/APP_ENVIRONMENT=.*/APP_ENVIRONMENT=production/" .env
sed -i "s/LOG_CHANNEL=.*/LOG_CHANNEL=daily/" .env

# Switch to SQLite since we're having MariaDB issues
sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=sqlite/" .env
sed -i "s/CACHE_DRIVER=.*/CACHE_DRIVER=file/" .env
sed -i "s/SESSION_DRIVER=.*/SESSION_DRIVER=file/" .env
sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=sync/" .env

# Create SQLite database
touch database/database.sqlite
chown nobody:nobody database/database.sqlite

# Generate app key
php artisan key:generate --force

# Run migrations
echo "[*] Setting up database..."
php artisan migrate --seed --force

# Create admin user
echo "[*] Creating admin user..."
php artisan p:user:make

# Setup cron job
echo "[*] Setting up cron job..."
echo "* * * * * cd /var/www/pterodactyl && php artisan schedule:run >> /dev/null 2>&1" > /etc/crontabs/nobody
rc-service crond restart || true

# Configure Nginx
echo "[*] Configuring web server..."
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
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Start services
echo "[*] Starting services..."
rc-service php-fpm81 start
rc-service nginx start

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Akses Panel: http://$PANEL_DOMAIN"
echo ""
echo "Informasi Database:"
echo "Tipe: SQLite (file lokal)"
echo "File: /var/www/pterodactyl/database/database.sqlite"
echo ""
echo "Jika terjadi masalah akses panel, pastikan:"
echo "1. Host $PANEL_DOMAIN dapat diakses"
echo "2. Port 80 sudah terbuka di firewall" 
echo "3. Coba jalankan: rc-service php-fpm81 restart && rc-service nginx restart"
