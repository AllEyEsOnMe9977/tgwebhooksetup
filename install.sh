#!/usr/bin/env bash
###############################################################################
# install.sh — Setup Script for Modular Telegram Bot Template
###############################################################################
set -euo pipefail
IFS=$'\n\t'

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/templates" && pwd)"
COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"

msg()   { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*";  }
warn()  { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()   { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
validate_domain() { local d=$1; [[ $d =~ ^https://[a-zA-Z0-9.-]+$ ]]; }
validate_token() { local t=$1; [[ $t =~ ^[0-9]{6,10}:[A-Za-z0-9_-]{35}$ ]]; }

need_root
msg "🌐  Telegram Modular Bot Bootstrapper"

read -rp "Telegram bot token: " BOT_TOKEN
validate_token "$BOT_TOKEN" || die "Token format invalid."

default_domain="https://$(hostname -f)"
read -rp "Public HTTPS domain for webhook [$default_domain]: " WEBHOOK_DOMAIN
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN:-$default_domain}
validate_domain "$WEBHOOK_DOMAIN" || die "Domain format invalid (MUST start with https://)"

read -rp "Numeric Telegram admin user ID (optional): " ADMIN_ID
ADMIN_ID=${ADMIN_ID:-0}

default_folder="tg-bot-$(date +%Y%m%d)"
read -rp "Project folder name [$default_folder]: " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-$default_folder}
PROJECT_PATH="/opt/$PROJECT_DIR"

read -rp "Custom port for Node.js (default 3000): " PORT
PORT=${PORT:-3000}

read -rp "MariaDB root password (for setup): " MYSQL_ROOT_PASS
read -rp "Database name [botdb]: " DB_NAME
DB_NAME=${DB_NAME:-botdb}
read -rp "Database user [botuser]: " DB_USER
DB_USER=${DB_USER:-botuser}
read -rp "Database password (auto-generate if empty): " DB_PASS
if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(openssl rand -base64 18)
    msg "Generated password: $DB_PASS"
fi

msg "Installing MariaDB server/client …"
apt-get install -y -qq mariadb-server mariadb-client

msg "Creating MariaDB database and user …"
mysql -u root -p"$MYSQL_ROOT_PASS" <<EOFMYSQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOFMYSQL

msg "Summary
────────────────────────────────
  Bot token         : $BOT_TOKEN
  Webhook domain    : $WEBHOOK_DOMAIN
  Admin user ID     : $ADMIN_ID
  Project directory : $PROJECT_PATH
  Node.js port      : $PORT
  Database          : MariaDB
────────────────────────────────"
read -rp "Press <Enter> to continue … "

msg "Updating system packages …"
apt-get update -qq && apt-get dist-upgrade -y -qq

msg "Installing Node.js (LTS) …"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y -qq nodejs build-essential

msg "Installing PM2 globally …"
npm install -g pm2 >/dev/null

msg "Installing/Upgrading Nginx …"
apt-get install -y -qq nginx

msg "Installing Certbot …"
apt-get install -y -qq certbot python3-certbot-nginx

# ----------- PROJECT SCAFFOLD ----------- #
msg "Copying bot template to $PROJECT_PATH …"
mkdir -p "$PROJECT_PATH"
cp -r "$TEMPLATE_DIR/." "$PROJECT_PATH/"

cd "$PROJECT_PATH"

cat > .env <<EOF
BOT_TOKEN="$BOT_TOKEN"
WEBHOOK_DOMAIN="$WEBHOOK_DOMAIN"
PORT=$PORT
ADMIN_ID=$ADMIN_ID
DB_TYPE="mariadb"
DB_HOST="localhost"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
EOF

chmod 600 .env

msg "Installing npm dependencies …"
npm install --silent

# ----------- NGINX CONFIG (Certbot) ----------- #
SITE_CONF="/etc/nginx/sites-available/$PROJECT_DIR.conf"
sudo rm -f "/etc/nginx/sites-available/$PROJECT_DIR.conf" "/etc/nginx/sites-enabled/$PROJECT_DIR.conf"
sudo rm -f "/etc/nginx/sites-available/${WEBHOOK_DOMAIN#https://}.conf" "/etc/nginx/sites-enabled/${WEBHOOK_DOMAIN#https://}.conf"

msg "Configuring Nginx (HTTP-only for Certbot)..."
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};
    location / { return 200 "ok"; }
}
EOF
ln -sf "$SITE_CONF" "/etc/nginx/sites-enabled/$PROJECT_DIR.conf"
nginx -t || { die "Nginx test failed (HTTP-only, pre-certbot)."; }
systemctl reload nginx

msg "Requesting Let’s Encrypt certificate (HTTP-only stage) …"
certbot --nginx -d "${WEBHOOK_DOMAIN#https://}" --non-interactive --agree-tos -m admin@"${WEBHOOK_DOMAIN#https://}"

msg "Writing final HTTPS Nginx config …"
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${WEBHOOK_DOMAIN#https://};

    ssl_certificate     /etc/letsencrypt/live/${WEBHOOK_DOMAIN#https://}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${WEBHOOK_DOMAIN#https://}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location / {
        allow 149.154.160.0/20;
        allow 91.108.4.0/22;
        deny all;
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
nginx -t || { die "Nginx test failed (after certbot)."; }
systemctl reload nginx

# ----------- PM2 PROCESS MANAGEMENT ----------- #
read -rp "Start the bot now with PM2 and enable boot‑start? (Y/n): " PM2_START
PM2_START=${PM2_START,,}
if [[ $PM2_START != "n" ]]; then
    pm2 start src/index.js --name "$PROJECT_DIR" --watch --cwd "$PROJECT_PATH"
    pm2 save
    pm2 startup systemd -u "$(logname)" --hp "/home/$(logname)" >/dev/null
fi

# ----------- RUN sethook ONLY after all is ready ----------- #
msg "Registering webhook with Telegram (final step)…"
WEBHOOK_RESULT=$(npm run sethook 2>&1 || true)
echo "$WEBHOOK_RESULT"
if echo "$WEBHOOK_RESULT" | grep -q '"ok":true'; then
    msg "✅ Webhook successfully set!"
else
    warn "⚠️  Webhook registration failed. See above. Run again after DNS and HTTPS are fully ready:"
    echo "    npm run sethook"
fi

cat <<EOF

══════════════════════════════════════════════════════════════════════
✅  Setup complete!

Project path      : $PROJECT_PATH
Node.js port      : $PORT
Webhook URL       : $WEBHOOK_DOMAIN/bot$BOT_TOKEN
Nginx conf        : $SITE_CONF
.ENV file         : $(realpath .env)
PM2 process name  : $PROJECT_DIR

Next steps:
  • Edit src/index.js to add bot logic.
  • If you change the domain or token, run "npm run sethook" again.
  • Use "pm2 logs $PROJECT_DIR" to follow live logs.
  • Use "pm2 restart $PROJECT_DIR" after code changes (auto‑reload if --watch).
  • Use "curl -vk -X POST \"$WEBHOOK_DOMAIN/bot$BOT_TOKEN\"" to test end-to-end.

══════════════════════════════════════════════════════════════════════
EOF
exit 0
