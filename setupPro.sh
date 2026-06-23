#!/usr/bin/env bash
###############################################################################
# nginx-webhook-setup.sh — Nginx + Telegram Webhook Setup (no systemd units)
# - Debian/Ubuntu (apt-get)
# - TLS via certbot; uses HTTPS-only for Telegram (required by Telegram)
# - Per-domain server; per-webhook location snippets under /etc/nginx/locations-<domain>/
# - Writes: .env, scripts/webhook-manage.sh, bot.js, package.json
# - Optional: run npm install (express, telegraf, dotenv)
# - Auto-pick free port; auto-generate secret if blank; smart webhook path
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

# SIGPIPE-proof random suffix (6 [A-Za-z0-9])
rand_suffix() {
  if have python3; then
    python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(6)))
PY
  else
    local _old
    _old="$(set +o | grep -E '^set \+o pipefail$' || true)"
    set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6
    eval "${_old:-:}"
  fi
}

gen_uuid() {
  if have uuidgen; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else openssl rand -hex 16
  fi
}

pick_free_port() {
  if have python3; then
    python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    return
  fi
  for _ in $(seq 1 100); do
    p=$(shuf -i 20000-60999 -n1)
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then
      echo "$p"; return
    fi
  done
  echo 0
}

port_is_free() {
  local p="$1"
  ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:${p}$|:${p}$"
}

# Ensure the main server config includes the common include-dir
ensure_locations_include() {
  local server_file="$1" domain="$2"
  local include_dir="/etc/nginx/locations-$domain"
  mkdir -p "$include_dir"

  if grep -qF "include $include_dir/*.conf;" "$server_file"; then
    return 0
  fi

  if grep -q "^# --- WEBHOOK LOCATIONS ---" "$server_file"; then
    awk -v inc="    include $include_dir/*.conf;" '
      {print}
      $0 ~ /^# --- WEBHOOK LOCATIONS ---/ && !done {print inc; done=1}
    ' "$server_file" > "$server_file.tmp" && mv "$server_file.tmp" "$server_file"
  elif grep -qE "location[[:space:]]*/[[:space:]]*\\{[[:space:]]*return[[:space:]]+404;" "$server_file"; then
    sed -e "0,/location[[:space:]]*\/[[:space:]]*{[[:space:]]*return[[:space:]]\+404;[[:space:]]*}/s//    include ${include_dir//\//\\/}\\/*.conf;\n&/" \
      "$server_file" > "$server_file.tmp" && mv "$server_file.tmp" "$server_file"
else
    # Depth-aware insert: find the 443 server block closing brace and prepend the include
    local inc_line="    include ${include_dir}/*.conf;"
    python3 -c "
import sys
path, inc_line = sys.argv[1], sys.argv[2]
with open(path) as f: text = f.read()
idx = text.rfind('listen 443')
if idx == -1:
    print(text, end=''); sys.exit()
start = text.rfind('{', 0, idx)
depth = 0
for i in range(start, len(text)):
    if text[i] == '{': depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            print(text[:i] + '\n' + inc_line + '\n' + text[i:], end='')
            sys.exit()
print(text, end='')
" "$server_file" "$inc_line" > "$server_file.tmp" && mv "$server_file.tmp" "$server_file"
  fi
}

# Write one per-webhook snippet under /etc/nginx/locations-<domain>/<project>.conf
write_webhook_snippet() {
  local domain="$1" project="$2" path="$3" port="$4" snippet="$5"
  local include_dir="/etc/nginx/locations-$domain"
  mkdir -p "$include_dir"
  cat > "$include_dir/${project}.conf" <<EOF
# auto-generated snippet for $project
location = $path {
    include $snippet;

    proxy_pass http://127.0.0.1:$port;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 90s;
    gzip off;
}
EOF
}

# ---------- preflight ----------
need_root
have apt-get || die "This script targets Debian/Ubuntu (apt-get)."
msg "Telegram Webhook + Nginx Setup"

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
  port_is_free "$PORT" || die "Selected port $PORT is not free."
  msg "Auto-picked free port: $PORT"
else
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -gt 0 && "$PORT" -le 65535 ]] || die "Invalid port."
  port_is_free "$PORT" || die "Port $PORT is already in use."
fi

default_project="telegram-bot"
read -rp "Project name [$default_project]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-$default_project}

read -rp "Custom webhook path (default: project + random): " CUSTOM_PATH
if [[ -z "${CUSTOM_PATH:-}" ]]; then
  WEBHOOK_PATH="/${PROJECT_NAME}_$(rand_suffix)"
  msg "Using webhook path: $WEBHOOK_PATH"
else
  [[ "$CUSTOM_PATH" =~ ^/ ]] || CUSTOM_PATH="/$CUSTOM_PATH"
  WEBHOOK_PATH="$CUSTOM_PATH"
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

read -rp "Secret token for webhook verification (leave blank to auto-generate): " SECRET_TOKEN
SECRET_TOKEN=${SECRET_TOKEN:-}
if [[ -z "$SECRET_TOKEN" ]]; then
  SECRET_TOKEN="$(gen_uuid)"
  msg "Generated secret token: $SECRET_TOKEN"
fi

read -rp "Restrict to Telegram IP ranges? (y/N): " USE_TG_IPS
USE_TG_IPS=${USE_TG_IPS,,}

# Owner chat IDs required (comma-separated, allow negatives)
read -rp "Owner chat IDs (comma-separated, required): " OWNER_IDS
OWNER_IDS="$(echo "${OWNER_IDS:-}" | tr -d '[:space:]')"
[[ -n "$OWNER_IDS" ]] || die "Owner chat IDs are required."
[[ "$OWNER_IDS" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || die "Owner chat IDs must be comma-separated integers."

default_email="admin@$DOMAIN_CLEAN"
read -rp "Email for Let's Encrypt [$default_email]: " CERTBOT_EMAIL
CERTBOT_EMAIL=${CERTBOT_EMAIL:-$default_email}

read -rp "Run npm install (express telegraf dotenv) after writing files? (y/N): " DO_NPM
DO_NPM=${DO_NPM,,}

# ---------- dependencies ----------
msg "Installing nginx + certbot"
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ca-certificates

systemctl enable --now nginx

ENABLED_DIR="/etc/nginx/sites-enabled"
SITE_CONF="/etc/nginx/sites-available/${DOMAIN_CLEAN}.conf"
ENABLED_LINK="/etc/nginx/sites-enabled/${DOMAIN_CLEAN}.conf"
SNIPPET="/etc/nginx/snippets/${PROJECT_NAME}-telegram_allowlist.conf"

# ---------- allowlist snippet per-project ----------
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
chmod 640 "$SNIPPET" || true

# ---------- detect existing server for domain (symlink or file) ----------
EXISTING_LINK=""
while IFS= read -r -d '' f; do
  if grep -qE "^\s*server_name\s+$DOMAIN_CLEAN\s*;" "$f"; then
    EXISTING_LINK="$f"; break
  fi
done < <(find "$ENABLED_DIR" -maxdepth 1 \( -type l -o -type f \) -print0 2>/dev/null)

if [[ -n "$EXISTING_LINK" ]]; then
  # Edit existing config (follow symlink)
  EXISTING_FILE="$(realpath "$EXISTING_LINK")"
  msg "Found existing server for $DOMAIN_CLEAN -> using $EXISTING_FILE"
  ensure_locations_include "$EXISTING_FILE" "$DOMAIN_CLEAN"
  write_webhook_snippet "$DOMAIN_CLEAN" "$PROJECT_NAME" "$WEBHOOK_PATH" "$PORT" "$SNIPPET"
  nginx -t && systemctl reload nginx
  msg "Updated existing nginx config and reloaded."
else
  # First-time setup for this domain
  msg "Configuring nginx (bootstrap HTTP for certbot)"
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

  msg "Getting SSL cert with certbot..."
  CERT_OK=0
  if certbot --nginx -d "$DOMAIN_CLEAN" --non-interactive --agree-tos \
    --email "$CERTBOT_EMAIL" --redirect --hsts; then
    CERT_OK=1
  else
    die "Certbot failed; Telegram requires HTTPS. Fix certbot and re-run."
  fi

  msg "Writing final nginx config (HTTPS)"
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
    include /etc/nginx/locations-$DOMAIN_CLEAN/*.conf;

    location = /health {
        add_header Cache-Control "no-store";
        return 200 "OK";
    }

    location / { return 404; }
}
EOF

  # Write our first webhook snippet now
  write_webhook_snippet "$DOMAIN_CLEAN" "$PROJECT_NAME" "$WEBHOOK_PATH" "$PORT" "$SNIPPET"
  nginx -t && systemctl reload nginx

  # Ensure nginx reloads automatically when certbot renews the certificate
  RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/post/reload-nginx.sh"
  if [[ ! -f "$RENEWAL_HOOK" ]]; then
    cat > "$RENEWAL_HOOK" <<'HOOK'
#!/usr/bin/env bash
# Reload nginx after certbot renews the TLS certificate for this domain
systemctl reload nginx
HOOK
    chmod 755 "$RENEWAL_HOOK"
    msg "Wrote certbot renewal hook: $RENEWAL_HOOK"
  fi

  chmod 640 "$SITE_CONF" || true
  msg "nginx configured at $SITE_CONF"
fi

# ---------- .env ----------
msg "Writing .env"
umask 077
cat > "$PROJECT_DIR/.env" <<EOF
# --- Bot config ---
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_SECRET=$SECRET_TOKEN
# Comma-separated list (e.g. 12345,-1001234567890)
BOT_OWNER_CHAT_IDS=$OWNER_IDS

# --- Webhook / server ---
WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN
WEBHOOK_PATH=$WEBHOOK_PATH
PORT=$PORT
EOF
chmod 600 "$PROJECT_DIR/.env"

# ---------- helper scripts ----------
msg "Writing helper script"
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
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo" | python3 -m json.tool
    ;;
  delete)
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook" | python3 -m json.tool
    ;;
  set)
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "url=${WEBHOOK_DOMAIN}${WEBHOOK_PATH}" \
      -d "secret_token=${TELEGRAM_SECRET}" \
      -d "max_connections=100" \
      -d 'allowed_updates=["message","edited_message","channel_post","edited_channel_post","callback_query"]' \
      -d "drop_pending_updates=true" | python3 -m json.tool
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

# ---------- bot.js (NOT executed) ----------
msg "Writing bot.js (not executed)"
cat > "$PROJECT_DIR/bot.js" <<'EOF'
// bot.js - minimal webhook starter
import 'dotenv/config';
import express from 'express';
import { Telegraf } from 'telegraf';

// --- ENV and sanity checks ---
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const SECRET_TOKEN = process.env.TELEGRAM_SECRET;
const PORT = process.env.PORT;
const WEBHOOK_PATH = process.env.WEBHOOK_PATH;
const WEBHOOK_DOMAIN = process.env.WEBHOOK_DOMAIN;
const OWNER_IDS_RAW = process.env.BOT_OWNER_CHAT_IDS;

if (!BOT_TOKEN || !SECRET_TOKEN) throw new Error("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_SECRET in .env");
if (!WEBHOOK_PATH || !WEBHOOK_DOMAIN) throw new Error("Missing WEBHOOK_PATH or WEBHOOK_DOMAIN in .env");
if (!OWNER_IDS_RAW) throw new Error("Missing BOT_OWNER_CHAT_IDS in .env");

const OWNER_CHAT_IDS = OWNER_IDS_RAW.split(',').map(s=>s.trim()).filter(Boolean);
if (!OWNER_CHAT_IDS.length) throw new Error("BOT_OWNER_CHAT_IDS has no valid entries.");

console.log('Authorized owner IDs:', OWNER_CHAT_IDS);

// ──────────────────────────────────────────────────────────────────────────────
// Bot instance
// ──────────────────────────────────────────────────────────────────────────────
export const bot = new Telegraf(BOT_TOKEN);

// Simple debug middleware
bot.use(async (ctx, next) => {
  console.log('Incoming update:', {
    updateId: ctx.update.update_id,
    from: ctx.from?.id,
    chat: ctx.chat?.id,
    messageType: ctx.updateType,
    text: ctx.message?.text || ctx.channelPost?.text,
  });
  await next();
});

// Example owner-only /start
bot.command('start', async (ctx) => {
  if (OWNER_CHAT_IDS.includes(String(ctx.from.id))) {
    await ctx.reply('Owner /start: bot is ready.');
  } else {
    return;
  }
});

async function notifyOwnersOnStartup() {
  for (const chatId of OWNER_CHAT_IDS) {
    try {
      await bot.telegram.sendMessage(chatId, 'Bot started successfully!');
      console.log(`Notified owner ${chatId}`);
    } catch (err) {
      console.error(`Failed to notify owner ${chatId}:`, err.message);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Start Express + webhook
// ──────────────────────────────────────────────────────────────────────────────
export async function startWebhookServer() {
  const app = express();
  app.use(express.json());

  // Secret header check (Telegram sets this if setWebhook used secret_token)
  app.post(WEBHOOK_PATH, (req, res, next) => {
    const header = req.get('x-telegram-bot-api-secret-token');
    if (header !== SECRET_TOKEN) {
      console.warn('Unauthorized webhook attempt with wrong secret');
      return res.status(401).json({ ok: false, error: 'Unauthorized' });
    }
    return next();
  });

  // Hand off to Telegraf
  app.post(WEBHOOK_PATH, bot.webhookCallback(WEBHOOK_PATH));

  // Simple health
  app.get('/health', (_, res) => res.send('OK'));

  app.listen(PORT, '127.0.0.1', async () => {
    console.log(`Listening on http://127.0.0.1:${PORT}`);
    console.log(`Webhook: ${WEBHOOK_DOMAIN}${WEBHOOK_PATH}`);

    await notifyOwnersOnStartup();

    const resp = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/setWebhook`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        url: `${WEBHOOK_DOMAIN}${WEBHOOK_PATH}`,
        secret_token: SECRET_TOKEN,
        max_connections: '100',
        allowed_updates: JSON.stringify([
          "message",
          "edited_message",
          "channel_post",
          "edited_channel_post",
          "callback_query"
        ]),
        drop_pending_updates: 'true',
      }),
    });
    console.log('setWebhook response:', await resp.json());
  });

  process.once("SIGINT", () => { bot.stop("SIGINT"); });
  process.once("SIGTERM", () => { bot.stop("SIGTERM"); });
}

// Allow running this file directly
if (import.meta.url === `file://${process.argv[1]}`) {
  startWebhookServer();
}
EOF
chmod 640 "$PROJECT_DIR/bot.js"

# ---------- package.json ----------
msg "Writing package.json"
# Reset umask before writing non-secret files
umask 022
cat > "$PROJECT_DIR/package.json" <<'EOF'
{
  "name": "telegram-webhook-bot",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node bot.js",
    "dev": "node --watch bot.js"
  },
  "dependencies": {
    "dotenv": "^17.2.1",
    "express": "^5.2.1",
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
    msg "Installing npm dependencies (express, telegraf, dotenv)"
    (cd "$PROJECT_DIR" && npm install)
  else
    warn "npm not found. Skipping npm install. Run later: cd \"$PROJECT_DIR\" && npm install"
  fi
else
  msg "Skipping npm install (run later: cd \"$PROJECT_DIR\" && npm install)"
fi

# ---------- final ----------
msg "Setup complete."
echo "Project: $PROJECT_DIR"
echo "Webhook: ${WEBHOOK_DOMAIN}${WEBHOOK_PATH}"
echo "Helper:  $SCRIPTS_DIR/webhook-manage.sh"
