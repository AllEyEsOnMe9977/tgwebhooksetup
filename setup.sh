#!/usr/bin/env bash
###############################################################################
# nginx-webhook-setup.sh — Nginx + Telegram Webhook Setup (no systemd)
# - Debian/Ubuntu (apt-get)
# - TLS with fallback to HTTP-only if certbot fails
# - Optional Telegram IP allowlist (snippet)
# - Writes: .env, scripts/webhook-manage.sh, intital_test.js, package.json
# - Optional: run npm install (express, telegraf, dotenv)
# - Enforces: ONE server{} per (domain,port). Aborts if duplicates exist.
# - NEW: Auto-pick a random FREE localhost port if you press Enter at prompt
###############################################################################
set -euo pipefail
IFS=$'\n\t'

COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"
msg()  { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*"; }
warn() { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()  { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
have() { command -v "$1" >/dev/null 2>&1; }
validate_domain() { [[ $1 =~ ^https://[a-z0-9.-]+$ ]]; }
validate_token()  { [[ $1 =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; }

# Choose a free high port on 127.0.0.1. Prefers Python for atomic bind to port 0.
pick_free_port() {
  if have python3; then
    local p
    p="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
print(port)
PY
)"
    # sanity: avoid 80/443 just in case
    if [[ "$p" -eq 80 || "$p" -eq 443 ]]; then
      echo 0; return
    fi
    echo "$p"; return
  fi
  # fallback: random within 20000-60999 and check with ss
  local try
  for _ in $(seq 1 100); do
    try=$(shuf -i 20000-60999 -n1)
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${try}$"; then
      echo "$try"; return
    fi
  done
  echo 0
}

# Verify port is free on localhost (best-effort)
port_is_free() {
  local p="$1"
  ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:${p}$|:${p}$"
}

# ---------- preflight ----------
need_root
have apt-get || die "This script targets Debian/Ubuntu (apt-get)."
msg "🌐 Telegram Webhook + Nginx Setup"

# ---------- input ----------
read -rp "Telegram bot token: " BOT_TOKEN
validate_token "$BOT_TOKEN" || die "Token format invalid."

default_domain="https://$(hostname -f | tr '[:upper:]' '[:lower:]')"
read -rp "Public HTTPS domain [$default_domain]: " WEBHOOK_DOMAIN
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN:-$default_domain}
validate_domain "$WEBHOOK_DOMAIN" || die "Domain must start with https:// and contain only a hostname."
DOMAIN_CLEAN="${WEBHOOK_DOMAIN#https://}"

# Auto-pick port if user presses Enter
read -rp "Backend port (Enter to auto-pick a free one): " PORT
if [[ -z "${PORT:-}" ]]; then
  PORT="$(pick_free_port)"
  [[ "$PORT" -gt 1024 ]] || die "Failed to auto-pick a free port."
  if ! port_is_free "$PORT"; then
    die "Selected port $PORT is not free. Re-run the script."
  fi
  msg "🔢 Auto-picked free port: $PORT"
else
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -gt 0 && "$PORT" -le 65535 ]] || die "Invalid port number."
  if ! port_is_free "$PORT"; then
    die "Port $PORT is already in use. Re-run and pick another (or press Enter to auto-pick)."
  fi
fi

default_project="telegram-bot"
read -rp "Project name [$default_project]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-$default_project}

read -rp "Custom webhook path (default /bot<TOKEN>): " CUSTOM_PATH
if [[ -n "${CUSTOM_PATH:-}" ]]; then
  [[ "$CUSTOM_PATH" =~ ^/ ]] || CUSTOM_PATH="/$CUSTOM_PATH"
  WEBHOOK_PATH="$CUSTOM_PATH"
else
  WEBHOOK_PATH="/bot$BOT_TOKEN"
fi

read -rp "Place project under /opt/$PROJECT_NAME? (y/N): " USE_OPT
USE_OPT=${USE_OPT,,}
if [[ "$USE_OPT" == "y" ]]; then
  PROJECT_DIR="/opt/$PROJECT_NAME"
  mkdir -p "$PROJECT_DIR"
else
  PROJECT_DIR="$(pwd)/$PROJECT_NAME"
  mkdir -p "$PROJECT_DIR"
fi

read -rp "Secret token for webhook verification (optional): " SECRET_TOKEN
SECRET_TOKEN=${SECRET_TOKEN:-}

read -rp "Restrict to Telegram IP ranges? (y/N): " USE_TG_IPS
USE_TG_IPS=${USE_TG_IPS,,}

default_email="admin@$DOMAIN_CLEAN"
read -rp "Email for Let's Encrypt [$default_email]: " CERTBOT_EMAIL
CERTBOT_EMAIL=${CERTBOT_EMAIL:-$default_email}

read -rp "Run npm install (express telegraf dotenv) after writing files? (y/N): " DO_NPM
DO_NPM=${DO_NPM,,}

# ---------- dependencies ----------
msg "📦 Installing nginx + certbot"
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ca-certificates

systemctl enable --now nginx

# ---------- enforce single server{} per domain ----------
ENABLED_DIR="/etc/nginx/sites-enabled"
EXISTING=()
while IFS= read -r -d '' f; do
  if grep -qE "^\s*server_name\s+$DOMAIN_CLEAN\s*;" "$f"; then
    EXISTING+=("$f")
  fi
done < <(find "$ENABLED_DIR" -maxdepth 1 -type l -print0 2>/dev/null)

if (( ${#EXISTING[@]} > 0 )); then
  echo
  warn "Found existing enabled server{} for $DOMAIN_CLEAN:"
  printf ' - %s\n' "${EXISTING[@]}"
  die "Consolidate to ONE server{} for $DOMAIN_CLEAN. Merge your webhook locations and disable duplicates."
fi

# ---------- choose per-domain config filename ----------
SITE_CONF="/etc/nginx/sites-available/${DOMAIN_CLEAN}.conf"
ENABLED_LINK="/etc/nginx/sites-enabled/${DOMAIN_CLEAN}.conf"
SNIPPET="/etc/nginx/snippets/${PROJECT_NAME}-telegram_allowlist.conf"

# ---------- bootstrap nginx (HTTP) ----------
msg "⚙️ Configuring nginx (bootstrap HTTP)"
rm -f "$SITE_CONF" "$ENABLED_LINK"

cat > "$SITE_CONF" <<EOF
# === AUTO-GENERATED: ${DOMAIN_CLEAN} (bootstrap) ===
server {
    listen 80;
    server_name $DOMAIN_CLEAN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 200 "Ready for SSL";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf "$SITE_CONF" "$ENABLED_LINK"
nginx -t && systemctl reload nginx

# ---------- certbot ----------
msg "🔐 Getting SSL cert..."
CERT_OK=0
if certbot --nginx -d "$DOMAIN_CLEAN" --non-interactive --agree-tos \
  --email "$CERTBOT_EMAIL" --redirect --hsts; then
  CERT_OK=1
else
  warn "Certbot failed; proceeding HTTP-only."
fi

# ---------- allowlist snippet ----------
if [[ "$USE_TG_IPS" == "y" ]]; then
  cat > "$SNIPPET" <<'EOF'
# Telegram published IP ranges (update when they change)
allow 149.154.160.0/20;
allow 91.108.4.0/22;
allow 91.108.56.0/22;
allow 149.154.164.0/22;
allow 149.154.168.0/22;
allow 149.154.172.0/22;
deny all;
EOF
else
  echo "# no IP restrictions" > "$SNIPPET"
fi

# ---------- final nginx config (single per-domain server) ----------
msg "📝 Writing final nginx config"
SECRET_BLOCK=""
if [[ -n "$SECRET_TOKEN" ]]; then
  SECRET_BLOCK=$'        proxy_set_header X-Telegram-Bot-Api-Secret-Token '"$SECRET_TOKEN;"$'\n'
fi

if [[ $CERT_OK -eq 1 ]]; then
  cat > "$SITE_CONF" <<EOF
# === AUTO-GENERATED: ${DOMAIN_CLEAN} (TLS) ===
server {
    listen 80;
    server_name $DOMAIN_CLEAN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN_CLEAN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN_CLEAN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CLEAN/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    client_max_body_size 1m;
    proxy_buffering off;

    # --- WEBHOOK LOCATIONS ---
    location = $WEBHOOK_PATH {
        include $SNIPPET;

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90s;
        gzip off;
${SECRET_BLOCK}    }

    location = /health {
        add_header Cache-Control "no-store";
        return 200 "OK";
    }

    location / { return 404; }
}
EOF
else
  cat > "$SITE_CONF" <<EOF
# === AUTO-GENERATED: ${DOMAIN_CLEAN} (HTTP-only) ===
server {
    listen 80;
    server_name $DOMAIN_CLEAN;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    client_max_body_size 1m;
    proxy_buffering off;

    # --- WEBHOOK LOCATIONS ---
    location = $WEBHOOK_PATH {
        include $SNIPPET;

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90s;
        gzip off;
${SECRET_BLOCK}    }

    location = /health {
        add_header Cache-Control "no-store";
        return 200 "OK";
    }

    location / { return 404; }
}
EOF
fi

nginx -t && systemctl reload nginx
chmod 640 "$SITE_CONF" || true
[[ -f "$SNIPPET" ]] && chmod 640 "$SNIPPET" || true
msg "✅ nginx configured at $SITE_CONF (single server for $DOMAIN_CLEAN)"

# ---------- .env ----------
msg "🗝️ Writing .env"
umask 077
cat > "$PROJECT_DIR/.env" <<EOF
# --- Bot config ---
TELEGRAM_TOKEN=$BOT_TOKEN
TELEGRAM_SECRET=$SECRET_TOKEN
BOT_OWNER_CHAT_ID=   # <- fill with your user or group/chat id

# --- Webhook / server ---
WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN
WEBHOOK_PATH=$WEBHOOK_PATH
PORT=$PORT
EOF
chmod 600 "$PROJECT_DIR/.env"

# ---------- helper scripts ----------
msg "🔧 Writing helper script"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
umask 077
cat > "$SCRIPTS_DIR/webhook-manage.sh" <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
# shellcheck disable=SC1091
source "$DIR/.env"

usage() { echo "Usage: $0 {info|delete|set|test}"; }

case "${1:-}" in
  info)
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getWebhookInfo" | python3 -m json.tool
    ;;
  delete)
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/deleteWebhook" | python3 -m json.tool
    ;;
  set)
    PARAMS="url=${WEBHOOK_DOMAIN}${WEBHOOK_PATH}"
    if [[ -n "${TELEGRAM_SECRET:-}" ]]; then
      PARAMS="${PARAMS}&secret_token=${TELEGRAM_SECRET}"
    fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook" \
      -H "Content-Type: application/x-www-form-urlencoded" -d "$PARAMS" | python3 -m json.tool
    ;;
  test)
    curl -s -X POST "${WEBHOOK_DOMAIN}${WEBHOOK_PATH}" \
      -H "Content-Type: application/json" \
      -H "X-Telegram-Bot-Api-Secret-Token: ${TELEGRAM_SECRET:-}" \
      -d '{"update_id":1,"message":{"message_id":1,"text":"test","chat":{"id":1}}}'
    ;;
  *) usage; exit 1;;
esac
EOFSCRIPT
chmod 700 "$SCRIPTS_DIR" "$SCRIPTS_DIR/webhook-manage.sh"

# ---------- intital_test.js (DO NOT RUN AUTOMATICALLY) ----------
msg "🧪 Writing intital_test.js (not executed)"
cat > "$PROJECT_DIR/intital_test.js" <<'EOF'
import 'dotenv/config';
import express from 'express';
import { Telegraf } from 'telegraf';

const BOT_TOKEN = process.env.TELEGRAM_TOKEN;
const SECRET_TOKEN = process.env.TELEGRAM_SECRET;
const PORT = process.env.PORT || '3000';
const OWNER_CHAT_ID = process.env.BOT_OWNER_CHAT_ID;
const WEBHOOK_PATH = process.env.WEBHOOK_PATH;
const WEBHOOK_DOMAIN = process.env.WEBHOOK_DOMAIN;

if (!BOT_TOKEN || !SECRET_TOKEN || !OWNER_CHAT_ID) {
  throw new Error("Missing TELEGRAM_TOKEN, TELEGRAM_SECRET, or BOT_OWNER_CHAT_ID in .env");
}
if (!WEBHOOK_PATH || !WEBHOOK_DOMAIN) {
  throw new Error("Missing WEBHOOK_PATH or WEBHOOK_DOMAIN in .env");
}

const bot = new Telegraf(BOT_TOKEN);
const app = express();

app.use(express.json());

// 401 if missing/incorrect secret header
app.post(WEBHOOK_PATH, (req, res, next) => {
  const header = req.get('x-telegram-bot-api-secret-token');
  if (header !== SECRET_TOKEN) return res.status(401).json({ ok: false, error: 'Unauthorized' });
  return next();
});

// Hand off to Telegraf
app.post(WEBHOOK_PATH, bot.webhookCallback(WEBHOOK_PATH));

// Simple health
app.get('/health', (_, res) => res.send('OK'));

// NOTE: This file is NOT executed by the setup script.
// Run it manually after filling .env: `node intital_test.js`
app.listen(PORT, '127.0.0.1', async () => {
  console.log(`Listening on http://127.0.0.1:${PORT}`);
  console.log(`Webhook path: ${WEBHOOK_PATH}`);

  // Set Telegram webhook to your configured domain
  const resp = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/setWebhook`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      url: `${WEBHOOK_DOMAIN}${WEBHOOK_PATH}`,
      secret_token: SECRET_TOKEN,
    }),
  });
  console.log('setWebhook response:', await resp.json());

  // Notify owner the bot is ready
  try {
    const readyResp = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: OWNER_CHAT_ID, text: "🤖 Bot is ready and webhook set!" }),
    });
    const readyData = await readyResp.json();
    if (!readyData.ok) throw new Error(readyData.description);
    console.log("✅ Bot is ready message sent!");
  } catch (err) {
    console.error("❌ Failed to send ready notification:", err.message);
  }
});
EOF
chmod 600 "$PROJECT_DIR/intital_test.js"

# ---------- package.json ----------
msg "📦 Writing package.json"
cat > "$PROJECT_DIR/package.json" <<'EOF'
{
  "name": "telegram-webhook-bot",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node intital_test.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "telegraf": "^4.16.3"
  }
}
EOF

# ---------- .gitignore ----------
cat > "$PROJECT_DIR/.gitignore" <<'EOF'
node_modules/
.env
npm-debug.log*
EOF

# ---------- npm install (optional) ----------
if [[ "$DO_NPM" == "y" ]]; then
  if have npm; then
    msg "📥 Installing npm dependencies (express, telegraf, dotenv)"
    (cd "$PROJECT_DIR" && npm install)
  else
    warn "npm not found. Skipping npm install. Install Node.js and run: cd \"$PROJECT_DIR\" && npm install"
  fi
else
  msg "⏭️ Skipping npm install (run later: cd \"$PROJECT_DIR\" && npm install)"
fi

# ---------- final notes ----------
msg "🎉 Setup complete!"
echo "Webhook URL: ${WEBHOOK_DOMAIN}${WEBHOOK_PATH}"
echo "Project directory: $PROJECT_DIR"
echo "Helper: $SCRIPTS_DIR/webhook-manage.sh"
echo "intital_test.js and package.json written (not executed)."
echo
echo "👉 IMPORTANT: Keep a SINGLE nginx server{} for $DOMAIN_CLEAN. Add more webhooks as more 'location =' blocks in $SITE_CONF."
