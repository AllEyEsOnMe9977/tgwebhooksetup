#!/usr/bin/env bash
###############################################################################
# new-tg-bot.sh — Robust Telegram Bot Bootstrapper
# version 1.1 (2025-07-31)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ----------- GLOBALS ---------------- #
VER="1.1"
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

msg "Summary
────────────────────────────────
  Bot token         : $BOT_TOKEN
  Webhook domain    : $WEBHOOK_DOMAIN
  Admin user ID     : $ADMIN_ID
  Project directory : $PROJECT_PATH
  Library           : $LIBRARY_SLUG
  Node.js port      : $PORT
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
chmod 600 .env

cat > package.json <<'EOF'
{ "name": "telegram-bot", "version": "1.0.0", "type": "module",
  "scripts": { "start": "node src/index.js", "sethook": "node setWebhook.js" } }
EOF

mkdir -p src

if [[ $LIBRARY_SLUG == "telegram-api" ]]; then
    npm i node-telegram-bot-api express dotenv
    # -------- Node-telegram-bot-api index.js --------
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
EOF

else
    npm i telegraf dotenv express
    # -------- TELEGRAF index.js — With All Fixes --------
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

// Debug logger: show all incoming updates
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

// ONLY intercept POSTs to exactly /bot<TOKEN>
app.post(\`/bot\${BOT_TOKEN}\`, bot.webhookCallback(\`/bot\${BOT_TOKEN}\`));

// EVERYTHING ELSE → 404
app.use((req, res) => {
  console.warn(\`⚠️ Unmatched \${req.method} \${req.path}\`);
  res.sendStatus(404);
});

app.listen(PORT, () => {
  console.log(\`⚡️ Express listening on port \${PORT}\`);
  const url = \`\${WEBHOOK_DOMAIN}/bot\${BOT_TOKEN}\`;
  bot.telegram
    .setWebhook(url)
    .then(() => console.log(\`✅ Webhook registered: \${url}\`))
    .catch(err => console.error('❌ setWebhook error:', err));
});
EOF

fi

# ----------- Webhook setter utility -----------
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

# ----------- NGINX CONFIG FIXED: Single server block, location / only -----------
SITE_CONF="$NGINX_SITE_DIR/$PROJECT_DIR.conf"
msg "Configuring Nginx reverse proxy …"
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

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # ALL requests (including /bot<token>) go to Node.js
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

# Remove any old/conflicting Nginx site links for this domain
for f in "$NGINX_SITE_LINK"/*; do
    grep -q "${WEBHOOK_DOMAIN#https://}" "$f" 2>/dev/null && sudo rm "$f"
done

ln -sf "$SITE_CONF" "$NGINX_SITE_LINK/$PROJECT_DIR.conf"
nginx -t || { die "Nginx test failed."; }
systemctl reload nginx

msg "Requesting Let’s Encrypt certificate …"
certbot --nginx -d "${WEBHOOK_DOMAIN#https://}" --non-interactive --agree-tos -m admin@"${WEBHOOK_DOMAIN#https://}"

# ----------- PM2 PROCESS MANAGEMENT -----------
read -rp "Start the bot now with PM2 and enable boot‑start? (Y/n): " PM2_START
PM2_START=${PM2_START,,}
if [[ $PM2_START != "n" ]]; then
    pm2 start src/index.js --name "$PROJECT_DIR" --watch --cwd "$PROJECT_PATH"
    pm2 save
    pm2 startup systemd -u "$(logname)" --hp "/home/$(logname)" >/dev/null
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
  • Run "npm run sethook" if you change the domain or token.
  • Use "pm2 logs $PROJECT_DIR" to follow live logs.
  • Use "pm2 restart $PROJECT_DIR" after code changes (auto‑reload if --watch).
  • Use "curl -vk -X POST \"$WEBHOOK_DOMAIN/bot$BOT_TOKEN\"" to test end-to-end.
══════════════════════════════════════════════════════════════════════
EOF
exit 0
