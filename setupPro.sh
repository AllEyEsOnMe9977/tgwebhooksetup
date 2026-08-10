#!/usr/bin/env bash
###############################################################################
# nginx-webhook-setup.sh — Nginx + Telegram Webhook Setup (no systemd units)
# - Debian/Ubuntu (apt-get)
# - TLS via certbot; uses HTTPS-only for Telegram (required by Telegram)
# - Per-domain server; per-webhook location snippets under /etc/nginx/locations-<domain>/
# - Writes: .env, scripts/webhook-manage.sh, bot.ts, package.json
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

# ---------- bot mode: webhook (default) or polling ----------
read -rp "Bot mode - (w)ebhook or (p)olling? [w]: " BOT_MODE_IN
BOT_MODE_IN=${BOT_MODE_IN,,}
if [[ "$BOT_MODE_IN" == "p" || "$BOT_MODE_IN" == "polling" ]]; then
  BOT_MODE="polling"
  msg "Mode: polling (no nginx/TLS/webhook needed; bot connects out to Telegram)"
else
  BOT_MODE="webhook"
  msg "Mode: webhook (requires public HTTPS domain via nginx + certbot)"
fi

default_project="telegram-bot"
read -rp "Project name [$default_project]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-$default_project}

if [[ "$BOT_MODE" == "webhook" ]]; then
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

  read -rp "Custom webhook path (default: project + random): " CUSTOM_PATH
  if [[ -z "${CUSTOM_PATH:-}" ]]; then
    WEBHOOK_PATH="/${PROJECT_NAME}_$(rand_suffix)"
    msg "Using webhook path: $WEBHOOK_PATH"
  else
    [[ "$CUSTOM_PATH" =~ ^/ ]] || CUSTOM_PATH="/$CUSTOM_PATH"
    WEBHOOK_PATH="$CUSTOM_PATH"
  fi
else
  # Polling mode: none of the webhook/nginx/domain variables are needed.
  WEBHOOK_DOMAIN=""
  DOMAIN_CLEAN=""
  WEBHOOK_PATH=""
  PORT=""
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

if [[ "$BOT_MODE" == "webhook" ]]; then
  read -rp "Restrict to Telegram IP ranges? (y/N): " USE_TG_IPS
  USE_TG_IPS=${USE_TG_IPS,,}
else
  USE_TG_IPS="n"
fi

# Owner chat IDs required (comma-separated, allow negatives)
read -rp "Owner chat IDs (comma-separated, required): " OWNER_IDS
OWNER_IDS="$(echo "${OWNER_IDS:-}" | tr -d '[:space:]')"
[[ -n "$OWNER_IDS" ]] || die "Owner chat IDs are required."
[[ "$OWNER_IDS" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || die "Owner chat IDs must be comma-separated integers."

if [[ "$BOT_MODE" == "webhook" ]]; then
  default_email="admin@$DOMAIN_CLEAN"
  read -rp "Email for Let's Encrypt [$default_email]: " CERTBOT_EMAIL
  CERTBOT_EMAIL=${CERTBOT_EMAIL:-$default_email}
fi

read -rp "Run npm install (express telegraf dotenv) after writing files? (y/N): " DO_NPM
DO_NPM=${DO_NPM,,}

# ---------- database selection ----------
echo "Database options:"
echo "  1) none (default)"
echo "  2) sqlite    (local file DB, zero server setup)"
echo "  3) mariadb   (installs mariadb-server if not present)"
read -rp "Choose database [1]: " DB_CHOICE
case "${DB_CHOICE:-1}" in
  2) DB_TYPE="sqlite" ;;
  3) DB_TYPE="mariadb" ;;
  *) DB_TYPE="none" ;;
esac
msg "Database: $DB_TYPE"

if [[ "$DB_TYPE" == "mariadb" ]]; then
  read -rp "MariaDB database name [${PROJECT_NAME//-/_}]: " DB_NAME
  DB_NAME=${DB_NAME:-${PROJECT_NAME//-/_}}
  read -rp "MariaDB username [${PROJECT_NAME//-/_}_user]: " DB_USER
  DB_USER=${DB_USER:-${PROJECT_NAME//-/_}_user}
  # Auto-generate a strong password; user can change it later in .env
  DB_PASS="$(gen_uuid | tr -d '-')"
  msg "Generated MariaDB password (also saved in .env)."
fi

# ---------- dependencies ----------
if [[ "$BOT_MODE" == "webhook" ]]; then
  msg "Installing nginx + certbot"
  apt-get update -qq
  apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ca-certificates
  systemctl enable --now nginx
else
  msg "Installing base dependencies (polling mode, no nginx/certbot needed)"
  apt-get update -qq
  apt-get install -y -qq curl openssl ca-certificates
fi

# ---------- pm2 (process manager, keeps bot running/restarting) ----------
if have pm2; then
  msg "pm2 already installed: $(pm2 -v)"
else
  have npm || { apt-get install -y -qq nodejs npm; }
  msg "Installing pm2 globally"
  npm install -g pm2 || die "Failed to install pm2. Install manually: npm install -g pm2"
fi

if [[ "$DB_TYPE" == "mariadb" ]]; then
  if have mysql || have mariadb; then
    msg "MariaDB/MySQL client already present."
  else
    msg "Installing mariadb-server"
    apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb
  fi

  # Create database and user idempotently (safe to re-run)
  msg "Provisioning MariaDB database '$DB_NAME' and user '$DB_USER'"
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  msg "MariaDB database and user ready."
fi

if [[ "$BOT_MODE" == "webhook" ]]; then

ENABLED_DIR="/etc/nginx/sites-enabled"
SITE_CONF="/etc/nginx/sites-available/${DOMAIN_CLEAN}.conf"
ENABLED_LINK="/etc/nginx/sites-enabled/${DOMAIN_CLEAN}.conf"
SNIPPET="/etc/nginx/snippets/${PROJECT_NAME}-telegram_allowlist.conf"

# ---------- allowlist snippet per-project ----------
if [[ "$USE_TG_IPS" == "y" ]]; then
  cat > "$SNIPPET" <<'EOF'
# Telegram published IP ranges (source: https://core.telegram.org/bots/webhooks)
# Verified current as of this script's last update. Re-check the URL above periodically.
allow 149.154.160.0/20;
allow 91.108.4.0/22;
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

fi # end BOT_MODE == webhook nginx/certbot block

# ---------- .env ----------
msg "Writing .env"
umask 077
cat > "$PROJECT_DIR/.env" <<EOF
# --- Bot config ---
BOT_MODE=$BOT_MODE
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_SECRET=$SECRET_TOKEN
# Comma-separated list (e.g. 12345,-1001234567890)
BOT_OWNER_CHAT_IDS=$OWNER_IDS

# --- Webhook / server (unused when BOT_MODE=polling) ---
WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN
WEBHOOK_PATH=$WEBHOOK_PATH
PORT=$PORT

# --- Database ---
DB_TYPE=$DB_TYPE
EOF

if [[ "$DB_TYPE" == "sqlite" ]]; then
  cat >> "$PROJECT_DIR/.env" <<EOF
DB_FILE=./data/${PROJECT_NAME}.sqlite3
EOF
elif [[ "$DB_TYPE" == "mariadb" ]]; then
  cat >> "$PROJECT_DIR/.env" <<EOF
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
EOF
fi
chmod 600 "$PROJECT_DIR/.env"

# ---------- helper scripts ----------
SCRIPTS_DIR="$PROJECT_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
if [[ "$BOT_MODE" == "webhook" ]]; then
msg "Writing helper script"
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
      -d 'allowed_updates=["message","edited_message","channel_post","edited_channel_post","business_connection","business_message","edited_business_message","deleted_business_messages","message_reaction","message_reaction_count","inline_query","chosen_inline_result","callback_query","shipping_query","pre_checkout_query","purchased_paid_media","poll","poll_answer","my_chat_member","chat_member","chat_join_request","chat_boost","removed_chat_boost"]' \
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
else
  msg "Skipping webhook-manage.sh (not applicable in polling mode)"
fi

# ---------- db.ts (only written if a DB was selected) ----------
if [[ "$DB_TYPE" == "sqlite" ]]; then
  msg "Writing db.ts (sqlite)"
  mkdir -p "$PROJECT_DIR/data"
  cat > "$PROJECT_DIR/db.ts" <<'EOF'
// db.ts - sqlite connection helper (better-sqlite3, synchronous driver)
import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';

const DB_FILE = process.env.DB_FILE || './data/bot.sqlite3';

// Ensure the containing directory exists before opening the file
fs.mkdirSync(path.dirname(DB_FILE), { recursive: true });

export const db = new Database(DB_FILE);
db.pragma('journal_mode = WAL');

console.log(`[db] sqlite connected: ${DB_FILE}`);
EOF
  chmod 640 "$PROJECT_DIR/db.ts"
elif [[ "$DB_TYPE" == "mariadb" ]]; then
  msg "Writing db.ts (mariadb)"
  cat > "$PROJECT_DIR/db.ts" <<'EOF'
// db.ts - mariadb connection pool helper
import mariadb from 'mariadb';

export const pool = mariadb.createPool({
  host: process.env.DB_HOST || '127.0.0.1',
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  connectionLimit: 5,
});

// Quick connectivity check at startup; fail loudly rather than silently.
try {
  const conn = await pool.getConnection();
  console.log('[db] mariadb connected:', process.env.DB_NAME);
  conn.release();
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  console.error('[db] mariadb connection failed:', msg);
  throw err;
}
EOF
  chmod 640 "$PROJECT_DIR/db.ts"
fi

# ---------- bot.ts (NOT executed) ----------
msg "Writing bot.ts (not executed) - mode: $BOT_MODE, db: $DB_TYPE"
cat > "$PROJECT_DIR/bot.ts" <<EOF
// bot.ts - auto-generated starter (mode: $BOT_MODE, db: $DB_TYPE)
import 'dotenv/config';
import { Telegraf } from 'telegraf';
$( [[ "$BOT_MODE" == "webhook" ]] && echo "import express from 'express';" )
$( [[ "$DB_TYPE" != "none" ]] && echo "import './db.js'; // initializes and logs DB connection on import" )

// --- ENV and sanity checks ---
const BOT_MODE = process.env.BOT_MODE || '$BOT_MODE';
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const SECRET_TOKEN = process.env.TELEGRAM_SECRET;
const PORT_RAW = process.env.PORT;
const WEBHOOK_PATH_RAW = process.env.WEBHOOK_PATH;
const WEBHOOK_DOMAIN_RAW = process.env.WEBHOOK_DOMAIN;
const OWNER_IDS_RAW = process.env.BOT_OWNER_CHAT_IDS;

if (!BOT_TOKEN) throw new Error("Missing TELEGRAM_BOT_TOKEN in .env");
if (!OWNER_IDS_RAW) throw new Error("Missing BOT_OWNER_CHAT_IDS in .env");
if (BOT_MODE === 'webhook' && (!SECRET_TOKEN || !WEBHOOK_PATH_RAW || !WEBHOOK_DOMAIN_RAW || !PORT_RAW)) {
  throw new Error("Missing TELEGRAM_SECRET/WEBHOOK_PATH/WEBHOOK_DOMAIN/PORT in .env for webhook mode");
}

// Narrowed, definitely-defined values for use below (guaranteed by the checks above)
const PORT = PORT_RAW as string;
const WEBHOOK_PATH = WEBHOOK_PATH_RAW as string;
const WEBHOOK_DOMAIN = WEBHOOK_DOMAIN_RAW as string;

const OWNER_CHAT_IDS = OWNER_IDS_RAW.split(',').map(s=>s.trim()).filter(Boolean);
if (!OWNER_CHAT_IDS.length) throw new Error("BOT_OWNER_CHAT_IDS has no valid entries.");

console.log('Authorized owner IDs:', OWNER_CHAT_IDS);
console.log('Bot mode:', BOT_MODE);

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
    text: ('text' in (ctx.message ?? {}) ? (ctx.message as any).text : undefined)
      || ('text' in (ctx.channelPost ?? {}) ? (ctx.channelPost as any).text : undefined),
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
      console.log(\`Notified owner \${chatId}\`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(\`Failed to notify owner \${chatId}:\`, msg);
    }
  }
}

$( if [[ "$BOT_MODE" == "webhook" ]]; then cat <<'WEBHOOKFN'
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

  app.listen(Number(PORT), '127.0.0.1', async () => {
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
          "business_connection",
          "business_message",
          "edited_business_message",
          "deleted_business_messages",
          "message_reaction",
          "message_reaction_count",
          "inline_query",
          "chosen_inline_result",
          "callback_query",
          "shipping_query",
          "pre_checkout_query",
          "purchased_paid_media",
          "poll",
          "poll_answer",
          "my_chat_member",
          "chat_member",
          "chat_join_request",
          "chat_boost",
          "removed_chat_boost"
        ]),
        drop_pending_updates: 'true',
      }),
    });
    console.log('setWebhook response:', await resp.json());
  });

  process.once("SIGINT", () => { bot.stop("SIGINT"); });
  process.once("SIGTERM", () => { bot.stop("SIGTERM"); });
}

startWebhookServer();
WEBHOOKFN
else cat <<'POLLINGFN'
// ──────────────────────────────────────────────────────────────────────────────
// Start long-polling (no server, no webhook, no public URL needed)
// ──────────────────────────────────────────────────────────────────────────────
export async function startPolling() {
  await notifyOwnersOnStartup();
  await bot.launch();
  console.log('Bot is polling for updates.');
}

process.once("SIGINT", () => { bot.stop("SIGINT"); });
process.once("SIGTERM", () => { bot.stop("SIGTERM"); });

startPolling();
POLLINGFN
fi )
EOF
chmod 640 "$PROJECT_DIR/bot.ts"

# ---------- package.json ----------
msg "Writing package.json (mode: $BOT_MODE, db: $DB_TYPE)"
# Reset umask before writing non-secret files
umask 022

# Build the dependencies object based on selected options
DEPS='"dotenv": "^17.2.1", "telegraf": "^4.16.3"'
[[ "$BOT_MODE" == "webhook" ]] && DEPS="$DEPS, \"express\": \"^5.2.1\""
[[ "$DB_TYPE" == "sqlite" ]] && DEPS="$DEPS, \"better-sqlite3\": \"^11.3.0\""
[[ "$DB_TYPE" == "mariadb" ]] && DEPS="$DEPS, \"mariadb\": \"^3.4.0\""

DEV_DEPS='"typescript": "^5.7.3", "tsx": "^4.19.2", "@types/node": "^22.10.5"'
[[ "$BOT_MODE" == "webhook" ]] && DEV_DEPS="$DEV_DEPS, \"@types/express\": \"^5.0.0\""
[[ "$DB_TYPE" == "sqlite" ]] && DEV_DEPS="$DEV_DEPS, \"@types/better-sqlite3\": \"^7.6.11\""

cat > "$PROJECT_DIR/package.json" <<EOF
{
  "name": "telegram-webhook-bot",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc",
    "start": "node dist/bot.js",
    "dev": "tsx watch bot.ts"
  },
  "dependencies": {
    $DEPS
  },
  "devDependencies": {
    $DEV_DEPS
  }
}
EOF

# ---------- .gitignore ----------
cat > "$PROJECT_DIR/.gitignore" <<'EOF'
node_modules/
.env
npm-debug.log*
logs/
EOF


# ---------- tsconfig.json ----------
msg "Writing tsconfig.json"
cat > "$PROJECT_DIR/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "outDir": "dist"
  },
  "include": ["*.ts"]
}
EOF

# ---------- ecosystem.config.cjs (pm2 process definition) ----------
msg "Writing ecosystem.config.cjs (pm2 config)"
mkdir -p "$PROJECT_DIR/logs"
cat > "$PROJECT_DIR/ecosystem.config.cjs" <<EOF
// ecosystem.config.cjs - pm2 process definition, auto-generated
// Docs: https://pm2.keymetrics.io/docs/usage/application-declaration/
module.exports = {
  apps: [
    {
      name: "$PROJECT_NAME",
      script: "bot.ts",
      cwd: "$PROJECT_DIR",
      interpreter: "node",
      script: "dist/bot.js",
      // Restart policy: keep it alive, but don't hot-loop-crash forever
      autorestart: true,
      max_restarts: 10,
      min_uptime: "10s",
      restart_delay: 3000,
      watch: false,
      env: {
        NODE_ENV: "production",
      },
      // Logging
      out_file: "$PROJECT_DIR/logs/out.log",
      error_file: "$PROJECT_DIR/logs/error.log",
      merge_logs: true,
      log_date_format: "YYYY-MM-DD HH:mm:ss Z",
      time: true,
    },
  ],
};
EOF
chmod 640 "$PROJECT_DIR/ecosystem.config.cjs"

# ---------- npm install (optional) ----------
if [[ "$DO_NPM" == "y" ]]; then
  if have npm; then
    msg "Installing npm dependencies ($DEPS)"
    (cd "$PROJECT_DIR" && npm install)

    msg "Building TypeScript (tsc)"
    (cd "$PROJECT_DIR" && npm run build) || die "TypeScript build failed. Fix errors in bot.ts/db.ts and re-run: cd \"$PROJECT_DIR\" && npm run build"
  else
    warn "npm not found. Skipping npm install. Run later: cd \"$PROJECT_DIR\" && npm install && npm run build"
  fi
else
  msg "Skipping npm install (run later: cd \"$PROJECT_DIR\" && npm install && npm run build)"
fi

# ---------- pm2 start (start bot under pm2 and persist across reboots) ----------
if have pm2; then
  msg "Starting bot under pm2"
  (cd "$PROJECT_DIR" && pm2 start ecosystem.config.cjs)
  pm2 save
  # Configure pm2 to resurrect the saved process list on system boot.
  # 'pm2 startup' prints a command that must be run as root; since this
  # script already runs as root, we generate and execute it directly.
  STARTUP_CMD="$(pm2 startup systemd -u root --hp /root 2>/dev/null | tail -n1)"
  if [[ "$STARTUP_CMD" == sudo* || "$STARTUP_CMD" == env* ]]; then
    eval "$STARTUP_CMD" || warn "pm2 startup command failed; run manually: pm2 startup"
  else
    warn "Could not auto-detect pm2 startup command. Run manually: pm2 startup"
  fi
  msg "pm2 process list saved; bot will auto-start on boot."
else
  warn "pm2 not found; bot NOT started. Run manually: cd \"$PROJECT_DIR\" && pm2 start ecosystem.config.cjs && pm2 save"
fi

# ---------- final ----------
msg "Setup complete."
echo "Project: $PROJECT_DIR"
echo "Mode:    $BOT_MODE"
if [[ "$BOT_MODE" == "webhook" ]]; then
  echo "Webhook: ${WEBHOOK_DOMAIN}${WEBHOOK_PATH}"
  echo "Helper:  $SCRIPTS_DIR/webhook-manage.sh"
else
  echo "Polling: no public URL needed; run 'npm start' to launch the bot."
fi
echo "Database: $DB_TYPE"
if [[ "$DB_TYPE" == "mariadb" ]]; then
  echo "  DB name: $DB_NAME  DB user: $DB_USER  (password saved in .env)"
elif [[ "$DB_TYPE" == "sqlite" ]]; then
  echo "  DB file: $PROJECT_DIR/data/${PROJECT_NAME}.sqlite3"
fi
echo "Process manager: pm2 (pm2 status | pm2 logs $PROJECT_NAME | pm2 restart $PROJECT_NAME)"
