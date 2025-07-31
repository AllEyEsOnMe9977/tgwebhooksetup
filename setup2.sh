#!/usr/bin/env bash
###############################################################################
#  new-tg-bot.sh — Interactive one‑shot bootstrapper for Telegram bot stacks
#  Author : <you>
#  Version: 1.0.0  (2025‑07‑31)
#
#  • Creates an opinionated, production‑ready Node.js project
#  • Installs/updates system packages, Node.js LTS, Nginx, PM2, Certbot
#  • Obtains a Let’s Encrypt certificate and configures secure reverse proxy
#  • Scaffolds code for either “node‑telegram‑bot‑api” or “Telegraf”
#  • Generates .env, webhook setter, systemd/PM2 files
#  • Can self‑update   ( ./new-tg-bot.sh --self-update )
#
#  Tested on Ubuntu 20.04+ (but most functions are distro‑agnostic)
###############################################################################

set -euo pipefail
IFS=$'\n\t'

#---------------------------  GLOBALS  --------------------------------------#
VER="1.0.0"
SCRIPT_NAME="$(basename "$0")"
NODE_LTS="lts/*"           # “lts/*” resolves to latest LTS via NodeSource
NGINX_SITE_DIR=/etc/nginx/sites-available
NGINX_SITE_LINK=/etc/nginx/sites-enabled
COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"

#--------------------  UTILITY & SAFETY FUNCTIONS  --------------------------#
msg()   { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*";  }
warn()  { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()   { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }

command_exists() { command -v "$1" &>/dev/null; }

pause() { read -rp "Press <Enter> to continue … "; }

validate_domain() {
    local domain=$1
    [[ $domain =~ ^https?://[a-zA-Z0-9.-]+$ ]] || return 1
}

validate_token() {
    local token=$1
    [[ $token =~ ^[0-9]{6,10}:[A-Za-z0-9_-]{35}$ ]] || return 1
}

#--------------------  SELF‑UPDATE (optional nicety) ------------------------#
if [[ ${1:-} == "--self-update" ]]; then
    need_root
    if command_exists curl; then
        curl -fsSL "https://raw.githubusercontent.com/yourrepo/$SCRIPT_NAME/main/$SCRIPT_NAME" \
        -o "/usr/local/bin/$SCRIPT_NAME" && chmod +x "/usr/local/bin/$SCRIPT_NAME" \
        && msg "Script updated." || die "Self‑update failed."
        exit 0
    else die "curl not found."; fi
fi

#--------------------  INTERACTIVE PROMPTS  ---------------------------------#
need_root
msg "🌐  Telegram Bot Environment Bootstrapper v$VER"
echo "Answer the following questions. Default values are shown in [brackets]."

read -rp "1) Telegram bot token: " BOT_TOKEN
validate_token "$BOT_TOKEN" || die "Token format invalid."

default_domain="https://$(hostname -f)"
read -rp "2) Public HTTPS domain for webhook [$default_domain]: " WEBHOOK_DOMAIN
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN:-$default_domain}
validate_domain "$WEBHOOK_DOMAIN" || die "Domain format invalid (include https://)"

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

read -rp "Allow Nginx access only from Telegram IPs? (y/N): " TG_IP_RESTRICT
TG_IP_RESTRICT=${TG_IP_RESTRICT,,}  # to lower
[[ $TG_IP_RESTRICT == "y" ]] && RESTRICT_IPS=true || RESTRICT_IPS=false

msg "Summary
────────────────────────────────
  Bot token         : $BOT_TOKEN
  Webhook domain    : $WEBHOOK_DOMAIN
  Admin user ID     : $ADMIN_ID
  Project directory : $PROJECT_PATH
  Library           : $LIBRARY_SLUG
  Node.js port      : $PORT
  Restrict to TG IP : $RESTRICT_IPS
────────────────────────────────"
pause

#--------------------  SYSTEM UPDATE & DEPENDENCIES -------------------------#
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

#--------------------  PROJECT SCAFFOLDING ----------------------------------#
msg "Creating project at $PROJECT_PATH …"
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH"

cat > .env <<EOF
# ==================  Generated $(date -Iseconds)  ==================
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

export default bot;   // allow import in other modules
app.post(`/bot${BOT_TOKEN}`, (req, res) => { bot.processUpdate(req.body); res.sendStatus(200); });
app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));
EOF
else
    npm i telegraf dotenv express
    cat > src/index.js <<'EOF'
import { Telegraf } from 'telegraf';
import express from 'express';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const bot = new Telegraf(BOT_TOKEN);
bot.start(ctx => ctx.reply('👋 Bot ready!'));
if (ADMIN_ID && ADMIN_ID !== '0') bot.telegram.sendMessage(ADMIN_ID, '🚀 Bot started');

const app = express();
app.use(express.json());
app.use(bot.webhookCallback(`/bot${BOT_TOKEN}`));
bot.telegram.setWebhook(`${process.env.WEBHOOK_DOMAIN}/bot${BOT_TOKEN}`);
app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));
EOF
fi

# webhook setter utility
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

#--------------------  NGINX CONFIGURATION ----------------------------------#
SITE_CONF="$NGINX_SITE_DIR/$PROJECT_DIR"
msg "Configuring Nginx reverse proxy …"
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};

    location / {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    # Optional: only allow Telegram and your server to reach webhook
    $( $RESTRICT_IPS && cat <<'BLOCK'
    allow 149.154.160.0/20;    # Telegram IP ranges
    allow 91.108.4.0/22;
    deny all;
BLOCK
)

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy no-referrer-when-downgrade;
}
EOF

ln -s "$SITE_CONF" "$NGINX_SITE_LINK/$PROJECT_DIR" || true
nginx -t || { die "Nginx test failed."; }
systemctl reload nginx

msg "Requesting Let’s Encrypt certificate …"
certbot --nginx -d "${WEBHOOK_DOMAIN#https://}" --non-interactive --agree-tos -m admin@"${WEBHOOK_DOMAIN#https://}"

# Certbot installs a renewal timer automatically.

#--------------------  PM2 PROCESS ------------------------------------------#
read -rp "Start the bot now with PM2 and enable boot‑start? (Y/n): " PM2_START
PM2_START=${PM2_START,,}
if [[ $PM2_START != "n" ]]; then
    pm2 start src/index.js --name "$PROJECT_DIR" --watch
    pm2 save
    pm2 startup systemd -u "$(logname)" --hp "/home/$(logname)" >/dev/null
fi

#--------------------  SUMMARY ----------------------------------------------#
cat <<EOF

══════════════════════════════════════════════════════════════════════
✅  Setup complete!

Project path      : $PROJECT_PATH
Node.js port      : $PORT
Webhook URL       : $WEBHOOK_DOMAIN/bot$BOT_TOKEN
Nginx conf        : $SITE_CONF
.ENV file         : $(realpath .env)
PM2 process name  : $PROJECT_DIR
SSL renewal       : handled by certbot.timer

Next steps:
  • Edit src/index.js to add bot logic.
  • Run "npm run sethook" if you change the domain or token.
  • Use "pm2 logs $PROJECT_DIR" to follow live logs.
  • Use "pm2 restart $PROJECT_DIR" after code changes (auto‑reload if --watch).
══════════════════════════════════════════════════════════════════════
EOF
exit 0
