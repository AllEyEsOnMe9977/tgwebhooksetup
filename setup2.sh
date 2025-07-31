#!/usr/bin/env bash
###############################################################################
# new-tg-bot.sh — Telegram Bot Setup Script (robust, reliable, repeatable)
# Author: You!
# Version: 2.0 (2025-07-31)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

VER="2.0"
NODE_LTS="lts/*"
NGINX_SITE_DIR=/etc/nginx/sites-available
NGINX_SITE_LINK=/etc/nginx/sites-enabled
COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"

msg()   { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*";  }
warn()  { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()   { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
command_exists() { command -v "$1" &>/dev/null; }
pause() { read -rp "Press <Enter> to continue … "; }
validate_domain() { local d=$1; [[ $d =~ ^https://[a-zA-Z0-9.-]+$ ]]; }
validate_token() { local t=$1; [[ $t =~ ^[0-9]{6,10}:[A-Za-z0-9_-]{35}$ ]]; }

need_root
msg "🌐  Telegram Bot Bootstrapper v$VER"
echo "Answer the following questions. Default values are shown in [brackets]."

read -rp "1) Telegram bot token: " BOT_TOKEN
validate_token "$BOT_TOKEN" || die "Token format invalid."

default_domain="https://$(hostname -f)"
read -rp "2) Public HTTPS domain for webhook [$default_domain]: " WEBHOOK_DOMAIN
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN:-$default_domain}
validate_domain "$WEBHOOK_DOMAIN" || die "Domain format invalid (MUST start with https://)"

read -rp "3) Numeric Telegram admin user ID (optional): " ADMIN_ID
ADMIN_ID=${ADMIN_ID:-0}

default_folder="tg-bot-$(date +%Y%m%d)"
read -rp "4) Project folder name [$default_folder]: " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-$default_folder}
PROJECT_PATH="/opt/$PROJECT_DIR"

echo "5) Choose Telegram library:"
select LIBRARY in "node-telegram-bot-api (official)" "Telegraf" "Quit"; do
    case $REPLY in
        1) LIBRARY_SLUG="telegram-api"; break ;;
        2) LIBRARY_SLUG="telegraf"; break ;;
        *) die "Aborted."; ;;
    esac
done

read -rp "Custom port for Node.js (default 3000): " PORT
PORT=${PORT:-3000}

echo "6) Database support:"
select DATABASE in "None" "MariaDB" "Quit"; do
    case $REPLY in
        1) DB_TYPE="none"; break ;;
        2) DB_TYPE="mariadb"; break ;;
        *) die "Aborted."; ;;
    esac
done

if [[ $DB_TYPE == "mariadb" ]]; then
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
fi

msg "Summary
────────────────────────────────
  Bot token         : $BOT_TOKEN
  Webhook domain    : $WEBHOOK_DOMAIN
  Admin user ID     : $ADMIN_ID
  Project directory : $PROJECT_PATH
  Library           : $LIBRARY_SLUG
  Node.js port      : $PORT
  Database          : $DB_TYPE
────────────────────────────────"
pause

# ----------- SYSTEM SETUP ----------- #
msg "Updating system packages …"
apt-get update -qq && apt-get dist-upgrade -y -qq

if ! command_exists curl; then apt-get install -y -qq curl; fi
if ! command_exists gnupg; then apt-get install -y -qq gnupg ca-certificates; fi

msg "Installing Node.js $NODE_LTS …"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y -qq nodejs build-essential

msg "Installing PM2 globally …"
npm install -g pm2 >/dev/null

msg "Installing / upgrading Nginx …"
apt-get install -y -qq nginx

msg "Installing Certbot …"
apt-get install -y -qq certbot python3-certbot-nginx

# ----------- PROJECT SCAFFOLD ----------- #
msg "Creating project at $PROJECT_PATH …"
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH"

cat > .env <<EOF
# ========== Generated $(date -Iseconds) ==========
BOT_TOKEN="$BOT_TOKEN"
WEBHOOK_DOMAIN="$WEBHOOK_DOMAIN"
PORT=$PORT
ADMIN_ID=$ADMIN_ID
EOF

if [[ $DB_TYPE == "mariadb" ]]; then
cat >> .env <<EOF
DB_TYPE="mariadb"
DB_HOST="localhost"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
EOF
fi

chmod 600 .env

cat > package.json <<'EOF'
{ "name": "telegram-bot", "version": "1.0.0", "type": "module",
  "scripts": { "start": "node src/index.js", "sethook": "node setWebhook.js" } }
EOF

mkdir -p src

# ------------ ADDITION: CREATE db.js -------------
if [[ $DB_TYPE == "mariadb" ]]; then
cat > src/db.js <<'EOF'
import mariadb from 'mariadb';
import * as dotenv from 'dotenv';
dotenv.config();

const pool = mariadb.createPool({
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  connectionLimit: 5
});

export async function testDb() {
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.query(`
      CREATE TABLE IF NOT EXISTS test_table (
        id INT AUTO_INCREMENT PRIMARY KEY,
        value VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    await conn.query("INSERT INTO test_table(value) VALUES (?)", ['Sample Data']);
    const rows = await conn.query("SELECT * FROM test_table ORDER BY id DESC LIMIT 1");
    return rows[0];
  } catch (err) {
    console.error("MariaDB error:", err);
    throw err;
  } finally {
    if (conn) conn.release();
  }
}
EOF
fi

if [[ $LIBRARY_SLUG == "telegram-api" ]]; then
    npm i node-telegram-bot-api express dotenv
    if [[ $DB_TYPE == "mariadb" ]]; then
        npm i mariadb
    fi
    cat > src/index.js <<'EOF'
import TelegramBot from 'node-telegram-bot-api';
import express from 'express';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const app = express();
app.use(express.json());

const bot = new TelegramBot(BOT_TOKEN, { webHook: { port: PORT }});
bot.onText(/\/start/, msg => bot.sendMessage(msg.chat.id, '👋 Bot ready!'));
if (ADMIN_ID && ADMIN_ID !== '0') bot.sendMessage(ADMIN_ID, '🚀 Bot started');

export default bot;

app.post(`/bot${BOT_TOKEN}`, (req, res) => { bot.processUpdate(req.body); res.sendStatus(200); });
app.use((req, res) => res.sendStatus(404));
app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));

/* --- MariaDB integration (optional) --- */
${DB_TYPE:-none} === "mariadb" ? (async () => {
  try {
    const { testDb } = await import('./db.js');
    const latest = await testDb();
    console.log("✅ MariaDB test success! Latest row:", latest);
  } catch (e) {
    console.error("❌ MariaDB integration failed:", e);
  }
})() : null;
EOF

else
    npm i telegraf dotenv express
    if [[ $DB_TYPE == "mariadb" ]]; then
        npm i mariadb
    fi
    cat > src/index.js <<EOF
import express from 'express';
import { Telegraf } from 'telegraf';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, WEBHOOK_DOMAIN, ADMIN_ID } = process.env;
if (!BOT_TOKEN || !WEBHOOK_DOMAIN || !PORT) {
  console.error('❌ Missing .env values.');
  process.exit(1);
}
const bot = new Telegraf(BOT_TOKEN);

bot.use((ctx, next) => {
  console.log('📥 Incoming update:', JSON.stringify(ctx.update, null, 2));
  return next();
});

bot.start(async ctx => {
  console.log('▶️ /start from', ctx.from.username || ctx.from.id);
  try {
    await ctx.reply('👋 Bot ready!');
  } catch (err) {
    console.error('Reply error:', err);
  }
});

if (ADMIN_ID && ADMIN_ID !== '0') {
  bot.telegram
    .sendMessage(ADMIN_ID, \`🚀 Bot started at \${new Date().toISOString()}\`)
    .catch(err => console.error('Admin notify error:', err));
}

const app = express();
app.use(express.json());

app.post(\`/bot\${BOT_TOKEN}\`, bot.webhookCallback(\`/bot\${BOT_TOKEN}\`));
app.use((req, res) => {
  console.warn(\`⚠️ Unmatched \${req.method} \${req.path}\`);
  res.sendStatus(404);
});

app.listen(PORT, () => {
  console.log(\`⚡️ Express listening on port \${PORT}\`);
});

/* --- MariaDB integration (optional) --- */
${DB_TYPE:-none} === "mariadb" ? (async () => {
  try {
    const { testDb } = await import('./db.js');
    const latest = await testDb();
    console.log("✅ MariaDB test success! Latest row:", latest);
  } catch (e) {
    console.error("❌ MariaDB integration failed:", e);
  }
})() : null;
EOF
fi

cat > setWebhook.js <<'EOF'
import fetch from 'node-fetch';
import * as dotenv from 'dotenv';
dotenv.config();
const { BOT_TOKEN, WEBHOOK_DOMAIN } = process.env;
const setHookURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=${WEBHOOK_DOMAIN}/bot${BOT_TOKEN}`;
const res = await fetch(setHookURL);
console.log(await res.json());
EOF
npm i node-fetch@3 dotenv >/dev/null

# ----------- 2-STAGE NGINX CONFIG FOR CERTBOT ----------- #
SITE_CONF="$NGINX_SITE_DIR/$PROJECT_DIR.conf"
sudo rm -f "$NGINX_SITE_DIR/$PROJECT_DIR.conf" "$NGINX_SITE_LINK/$PROJECT_DIR.conf"
sudo rm -f "$NGINX_SITE_DIR/${WEBHOOK_DOMAIN#https://}.conf" "$NGINX_SITE_LINK/${WEBHOOK_DOMAIN#https://}.conf"

msg "Configuring Nginx (HTTP-only for Certbot)..."
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};
    location / { return 200 "ok"; }
}
EOF
ln -sf "$SITE_CONF" "$NGINX_SITE_LINK/$PROJECT_DIR.conf"
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
