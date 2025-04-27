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

# Try to install supervisor
echo "[*] Installing supervisor..."
apk add --no-cache supervisor 2>/dev/null || { 
    echo "Supervisor not available. Installing from community repository..."; 
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
    apk update
    apk add --no-cache supervisor || echo "Supervisor installation failed, continuing without it..."
}

# Try to install Redis extension using PECL if available
echo "[*] Attempting to install Redis extension..."
apk add --no-cache php81-pecl-redis 2>/dev/null || apk add --no-cache php81-redis 2>/dev/null || echo "Redis extension not found, continuing without it..."

# Make sure services directories exist
mkdir -p /run/mysqld /run/nginx

# Configure PHP-FPM to use UNIX socket
sed -i 's/listen = 127.0.0.1:9000/listen = \/run\/php\/php8.1-fpm.sock/g' /etc/php81/php-fpm.d/www.conf
mkdir -p /run/php
chown nobody:nobody /run/php

# Start services and enable them at boot
echo "[*] Starting and enabling services..."
rc-update add mariadb default
rc-update add redis default
rc-update add php-fpm81 default
rc-update add nginx default

# Add supervisor to boot if it exists
if [ -f /etc/init.d/supervisor ]; then
    rc-update add supervisor default
fi

rc-service mariadb setup
rc-service mariadb start || { echo "Failed to start MariaDB"; exit 1; }
rc-service redis start || { echo "Failed to start Redis"; exit 1; }
rc-service php-fpm81 start || { echo "Failed to start PHP-FPM"; exit 1; }
rc-service nginx start || { echo "Failed to start Nginx"; exit 1; }

# Start supervisor if available
if [ -f /etc/init.d/supervisor ]; then
    rc-service supervisor start || echo "Failed to start Supervisor, continuing..."
elif command -v supervisord >/dev/null 2>&1; then
    supervisord -c /etc/supervisord.conf &
    echo "Started supervisor manually"
fi

# Wait for MariaDB to fully start
echo "[*] Waiting for MariaDB to initialize..."
sleep 5

# Secure MariaDB automatically with better method
echo "[*] Securing MariaDB..."
if mysqladmin -u root password "$MYSQL_ROOT_PASS" 2>/dev/null; then
    echo "Root password set successfully"
else
    echo "Setting root password with alternative method..."
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
fi

mysql -u root -p"$MYSQL_ROOT_PASS" <<EOF || { echo "MariaDB security setup failed"; exit 1; }
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Create Database & User with error handling
echo "[*] Creating database and user..."
mysql -u root -p"$MYSQL_ROOT_PASS" <<MYSQL_SCRIPT || { echo "Database creation failed"; exit 1; }
CREATE DATABASE IF NOT EXISTS $PANEL_DB_NAME;
CREATE USER IF NOT EXISTS '$PANEL_DB_USER'@'127.0.0.1' IDENTIFIED BY '$PANEL_DB_PASS';
CREATE USER IF NOT EXISTS '$PANEL_DB_USER'@'localhost' IDENTIFIED BY '$PANEL_DB_PASS';
GRANT ALL PRIVILEGES ON $PANEL_DB_NAME.* TO '$PANEL_DB_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON $PANEL_DB_NAME.* TO '$PANEL_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Download Pterodactyl with error handling
echo "[*] Downloading Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
if ! curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz; then
    echo "Failed to download Pterodactyl panel"
    exit 1
fi

tar -xzvf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 /var/www/pterodactyl

# Install PHP dependencies with timeout
echo "[*] Installing PHP dependencies..."
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction

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
php artisan migrate --seed --force || { echo "Database migration failed"; exit 1; }

# Create admin user
echo "[*] Creating admin user..."
php artisan p:user:make

# Set up queue worker with supervisor if available
if [ -d /etc/supervisor.d ]; then
    echo "[*] Setting up queue worker with supervisor..."
    cat <<EOF > /etc/supervisor.d/pterodactyl.ini
[program:pterodactyl-worker]
process_name=%(program_name)s
command=php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
autostart=true
autorestart=true
user=nobody
redirect_stderr=true
stdout_logfile=/var/www/pterodactyl/storage/logs/worker.log
stopwaitsecs=10
EOF

    # Try to reload supervisor configuration
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl reread
        supervisorctl update
    fi
else
    # Alternative: Create a simple script to run the queue worker
    echo "[*] Creating queue worker script (supervisor not available)..."
    cat <<EOF > /usr/local/bin/pterodactyl-worker
#!/bin/sh
cd /var/www/pterodactyl
while true; do
    php artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
    sleep 5
done
EOF
    chmod +x /usr/local/bin/pterodactyl-worker
    
    # Create a simple init script
    cat <<EOF > /etc/init.d/pterodactyl-worker
#!/sbin/openrc-run

name="Pterodactyl Queue Worker"
command="/usr/local/bin/pterodactyl-worker"
command_background="yes"
pidfile="/run/pterodactyl-worker.pid"
user="nobody"
group="nobody"

depend() {
    need net
    after mariadb redis
}
EOF
    chmod +x /etc/init.d/pterodactyl-worker
    rc-update add pterodactyl-worker default
    rc-service pterodactyl-worker start
fi

# Setup cron job
echo "[*] Setting up cron job..."
echo "* * * * * cd /var/www/pterodactyl && php artisan schedule:run >> /dev/null 2>&1" > /etc/crontabs/nobody
rc-service crond restart

# Configure Nginx with better socket configuration
echo "[*] Configuring Nginx..."
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
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
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
rc-service php-fpm81 restart
rc-service nginx restart

# If supervisor is running, restart it
if [ -f /etc/init.d/supervisor ]; then
    rc-service supervisor restart
fi

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
echo "Queue worker running: "
if [ -f /etc/init.d/supervisor ]; then
    echo "Via supervisor"
elif [ -f /etc/init.d/pterodactyl-worker ]; then
    echo "Via custom service (pterodactyl-worker)"
else
    echo "WARNING: Queue worker not running. You may need to start it manually."
fi
