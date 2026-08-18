#!/usr/bin/env bash
###############################################################################
# bun-webhook-setup.sh — Nginx + Telegram Webhook Setup (Bun + systemd)
# - Debian/Ubuntu (apt-get)
# - Runtime: Bun (installed via official shell installer, no apt repo exists)
# - Process manager: systemd (native unit; Bun has no first-class pm2 support)
# - Database: none | sqlite (bun:sqlite, built into Bun, zero external deps)
#             | mariadb (npm mariadb package — pure JS, installed via bun install)
# - TLS via certbot; HTTPS-only for Telegram (required by Telegram)
# - Per-domain server; per-webhook location snippets under /etc/nginx/locations-<domain>/
# - Writes: .env, scripts/webhook-manage.sh, bot.ts, package.json, systemd unit
# - Auto-pick free port; auto-generate secret if blank; smart webhook path
# - NOTE ON SANDBOXING: unlike Deno, Bun has no runtime permission flags
#   (--allow-net etc). Process isolation here relies entirely on the systemd
#   hardening directives (dedicated user, ProtectSystem, ReadWritePaths).
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
    print(text, end=''); sys.exit(1)
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
" "$server_file" "$inc_line" > "$server_file.tmp" \
      && mv "$server_file.tmp" "$server_file" \
      || die "Could not safely insert webhook include into $server_file. Edit it manually and re-run."
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
msg "Telegram Webhook + Nginx Setup (Bun + systemd)"

# ---------- install / verify Bun ----------
# Bun has no official apt repository, so the official shell installer is the
# reliable path on any Debian/Ubuntu box. Unlike Deno's installer (which we
# pointed at /usr/local), Bun's installer always writes to $HOME/.bun/bin —
# there is no supported override to a shared system path. Since this script
# runs as root, that means /root/.bun/bin/bun. We resolve the absolute path
# explicitly rather than relying on PATH, because the systemd service later
# runs as a *different*, unprivileged user who won't have root's PATH.
install_bun() {
  have curl || { apt-get update -qq && apt-get install -y -qq curl ca-certificates unzip; }
  msg "Installing Bun via official installer"
  curl -fsSL https://bun.sh/install | bash \
    || die "Bun install failed. Check network access to bun.sh/github.com."
  have unzip || apt-get install -y -qq unzip
}

if [[ -x /root/.bun/bin/bun ]]; then
  msg "Bun already installed at /root/.bun/bin/bun"
elif have bun; then
  msg "Bun already installed at $(command -v bun)"
else
  install_bun
fi

# Resolve the absolute binary path once; prefer root's install location since
# that's where the installer places it when this script runs as root.
if [[ -x /root/.bun/bin/bun ]]; then
  # /root is unreadable to the unprivileged service user, and ProtectHome=true
  # in the systemd unit blocks it too — a symlink into /usr/local/bin still
  # resolves through /root and fails the same way. Copy the actual binary out
  # so nothing at runtime ever needs to touch /root. Remove any old symlink
  # first — cp refuses to overwrite a destination that resolves to the same
  # inode as the source (which a stale symlink from a prior run would do).
  rm -f /usr/local/bin/bun
  cp -f /root/.bun/bin/bun /usr/local/bin/bun
  chmod 755 /usr/local/bin/bun
  BUN_BIN="/usr/local/bin/bun"
elif have bun; then
  BUN_BIN="$(command -v bun)"
else
  die "Bun installed but binary not found at /root/.bun/bin/bun or on PATH."
fi
msg "Using Bun at $BUN_BIN ($($BUN_BIN --version))"

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
# systemd unit names must avoid spaces/slashes; keep project name filesystem/unit safe.
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Project name must be alphanumeric (., _, - allowed)."

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

if [[ "$BOT_MODE" == "webhook" ]]; then
  read -rp "Secret token for webhook verification (leave blank to auto-generate): " SECRET_TOKEN
  SECRET_TOKEN=${SECRET_TOKEN:-}
  if [[ -z "$SECRET_TOKEN" ]]; then
    SECRET_TOKEN="$(gen_uuid)"
    msg "Generated secret token: $SECRET_TOKEN"
  fi
else
  SECRET_TOKEN=""
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

# ---------- database selection ----------
echo "Database options:"
echo "  1) none (default)"
echo "  2) sqlite    (bun:sqlite — built into Bun, zero extra deps)"
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
  apt-get install -y -qq nginx certbot python3-certbot-nginx curl openssl ca-certificates python3
  systemctl enable --now nginx
else
  msg "Installing base dependencies (polling mode, no nginx/certbot needed)"
  apt-get update -qq
  apt-get install -y -qq curl openssl ca-certificates python3
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
  mysql -u root -e "SELECT 1;" >/dev/null 2>&1 \
    || die "Cannot connect to MariaDB as root (unix_socket auth not configured). Fix root access and re-run."
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
  nginx -t || die "nginx config test failed after edit — reverted state may be inconsistent, inspect $EXISTING_FILE manually."
  systemctl reload nginx
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
  nginx -t || die "nginx config test failed after edit — reverted state may be inconsistent, inspect $SITE_CONF manually."
  systemctl reload nginx

  msg "Getting SSL cert with certbot..."
  if certbot --nginx -d "$DOMAIN_CLEAN" --non-interactive --agree-tos \
    --email "$CERTBOT_EMAIL" --redirect --hsts; then
    :
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
  nginx -t || die "nginx config test failed after edit — reverted state may be inconsistent, inspect $SITE_CONF manually."
  systemctl reload nginx

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
  msg "Writing db.ts (bun:sqlite — built into Bun, no external package)"
  mkdir -p "$PROJECT_DIR/data"
  cat > "$PROJECT_DIR/db.ts" <<'EOF'
// db.ts - sqlite connection helper using bun:sqlite (Database).
// Built directly into the Bun runtime; no external package required and no
// native-binding compile step (unlike better-sqlite3 under Node, which needs
// node-gyp / prebuilt binaries per platform).
import { Database } from 'bun:sqlite';
import fs from 'node:fs';
import path from 'node:path';

const DB_FILE = process.env.DB_FILE || './data/bot.sqlite3';

// Ensure the containing directory exists before opening the file
fs.mkdirSync(path.dirname(DB_FILE), { recursive: true });

export const db = new Database(DB_FILE, { create: true });
// bun:sqlite defaults to DELETE journal mode; WAL improves concurrent
// read/write behaviour for a bot handling frequent small writes.
db.exec('PRAGMA journal_mode = WAL;');

console.log(`[db] sqlite connected (bun:sqlite): ${DB_FILE}`);
EOF
  chmod 640 "$PROJECT_DIR/db.ts"
elif [[ "$DB_TYPE" == "mariadb" ]]; then
  msg "Writing db.ts (mariadb — installed as a regular npm dependency)"
  cat > "$PROJECT_DIR/db.ts" <<'EOF'
// db.ts - mariadb connection pool helper.
// Pure-JS driver (no native bindings), installed normally via `bun install`
// and imported with a bare specifier, same as under Node.
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
// Runtime: Bun. Dependencies are installed normally via 'bun install' and
// imported with standard bare specifiers — Bun's npm compatibility is deep
// enough (including native addon support) that no special import syntax
// or workaround packages are needed, unlike under Deno.
import 'dotenv/config';
import { Telegraf } from 'telegraf';
$( [[ "$BOT_MODE" == "webhook" ]] && echo "import express from 'express';" )
$( [[ "$DB_TYPE" != "none" ]] && echo "import './db.ts'; // initializes and logs DB connection on import" )

// --- ENV and sanity checks ---
const BOT_MODE = process.env.BOT_MODE || '$BOT_MODE';
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const SECRET_TOKEN = process.env.TELEGRAM_SECRET;
const PORT = process.env.PORT;
const WEBHOOK_PATH = process.env.WEBHOOK_PATH;
const WEBHOOK_DOMAIN = process.env.WEBHOOK_DOMAIN;
const OWNER_IDS_RAW = process.env.BOT_OWNER_CHAT_IDS;

if (!BOT_TOKEN) throw new Error("Missing TELEGRAM_BOT_TOKEN in .env");
if (!OWNER_IDS_RAW) throw new Error("Missing BOT_OWNER_CHAT_IDS in .env");
$( if [[ "$BOT_MODE" == "webhook" ]]; then cat <<'ENVCHECK'
if (!SECRET_TOKEN || !WEBHOOK_PATH_RAW || !WEBHOOK_DOMAIN_RAW || !PORT_RAW) {
  throw new Error("Missing TELEGRAM_SECRET/WEBHOOK_PATH/WEBHOOK_DOMAIN/PORT in .env for webhook mode");
}

ENVCHECK
fi )
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
# Bun runs .ts directly (no tsc build step needed, same benefit as Deno here),
# but it follows Node/npm conventions for dependency management, so we still
# ship package.json rather than a Deno-style config file.
msg "Writing package.json (mode: $BOT_MODE, db: $DB_TYPE)"
umask 022

# Build the dependencies list based on selected options.
DEPS='"dotenv": "^17.2.1", "telegraf": "^4.16.3"'
[[ "$BOT_MODE" == "webhook" ]] && DEPS="$DEPS, \"express\": \"^5.2.1\""
[[ "$DB_TYPE" == "mariadb" ]] && DEPS="$DEPS, \"mariadb\": \"^3.4.0\""
# bun:sqlite is built into the Bun runtime; no dependency entry needed.

DEV_DEPS='"@types/node": "^22.10.5", "bun-types": "latest"'
[[ "$BOT_MODE" == "webhook" ]] && DEV_DEPS="$DEV_DEPS, \"@types/express\": \"^5.0.0\""

cat > "$PROJECT_DIR/package.json" <<EOF
{
  "name": "$PROJECT_NAME",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "bun run bot.ts",
    "dev": "bun --watch run bot.ts"
  },
  "dependencies": {
    $DEPS
  },
  "devDependencies": {
    $DEV_DEPS
  }
}
EOF
chmod 644 "$PROJECT_DIR/package.json"

# ---------- tsconfig.json ----------
# Purely for editor/IDE support and optional `tsc --noEmit` type-checking in
# CI. Bun ignores this at runtime — it transpiles and runs .ts directly
# regardless of whether this file exists, same as Deno.
msg "Writing tsconfig.json (editor/type-check support only, not required at runtime)"
cat > "$PROJECT_DIR/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "types": ["bun-types"]
  },
  "include": ["*.ts"]
}
EOF
chmod 644 "$PROJECT_DIR/tsconfig.json"

# ---------- .gitignore ----------
cat > "$PROJECT_DIR/.gitignore" <<'EOF'
node_modules/
.env
.bun/
bun.lock
bun.lockb
logs/
data/
EOF

# ---------- systemd unit (replaces pm2 — native OS process supervision) ----------
msg "Writing systemd unit (mode: $BOT_MODE, db: $DB_TYPE)"
mkdir -p "$PROJECT_DIR/logs"
SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
cat > "$SERVICE_FILE" <<EOF
# ${PROJECT_NAME}.service - auto-generated by bun-webhook-setup.sh
# Runs the Telegram bot under Bun. systemd handles restart-on-failure and
# boot persistence, replacing pm2 (which has no first-class Bun support).
# Unlike Deno, Bun has no runtime permission flags — process isolation here
# comes entirely from the hardening directives below (dedicated user,
# ProtectSystem, ReadWritePaths), so they matter more than in the Deno unit.
[Unit]
Description=${PROJECT_NAME} Telegram bot (Bun)
After=network-online.target
Wants=network-online.target
# Cap restart storms: allow at most 10 restarts within a 60s window.
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${PROJECT_DIR}/.env
# Bun installs per-user to ~/.bun/bin, not a shared system path, so PATH must
# be set explicitly here — the service user otherwise has no PATH entry
# pointing at the bun binary. ExecStart itself uses the absolute path so
# startup does not depend on PATH resolution at all; PATH is kept only in
# case bot.ts or a dependency shells out expecting bun/node on PATH.
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# HOME is redirected into the project directory (already covered by
# ReadWritePaths) rather than left as the service user's real home. ProtectHome
# below makes /home inaccessible to this service, and Bun writes cache/config
# under $HOME — the same class of failure we hit with Deno's default cache
# path under ProtectHome=true. Keeping HOME inside ReadWritePaths avoids it.
Environment=HOME=${PROJECT_DIR}
ExecStart=${BUN_BIN} run start
Restart=on-failure
RestartSec=3

# Hardening: run as a dedicated unprivileged user, not root.
User=${PROJECT_NAME}
Group=${PROJECT_NAME}
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${PROJECT_DIR}
ProtectHome=true

# Logging: journald captures stdout/stderr; view with
#   journalctl -u ${PROJECT_NAME} -f
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${PROJECT_NAME}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$SERVICE_FILE"

# Dedicated service user (no login shell, no home dir writes outside project)
if ! id -u "$PROJECT_NAME" >/dev/null 2>&1; then
  msg "Creating dedicated system user '$PROJECT_NAME' for the service"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PROJECT_NAME"
fi
chown -R "$PROJECT_NAME:$PROJECT_NAME" "$PROJECT_DIR"
# .env holds secrets; keep it readable only by the service user and root.
chmod 600 "$PROJECT_DIR/.env"

# ---------- npm install (mandatory) ----------
# Unlike Deno, Bun does NOT lazily fetch dependencies at runtime — bot.ts
# will fail to start without node_modules in place, so this step is required
# and cannot be skipped.
msg "Installing dependencies via bun install (required)"
# Run as the dedicated service user so file ownership matches what the
# systemd unit will use, and so bun's per-user cache lands in the right home.
(cd "$PROJECT_DIR" && sudo -u "$PROJECT_NAME" env HOME="$PROJECT_DIR" "$BUN_BIN" install) \
  || die "bun install failed. Fix the error above and re-run the script."

# ---------- start service ----------
msg "Enabling and starting systemd service"
systemctl daemon-reload
systemctl enable --now "${PROJECT_NAME}.service" \
  || warn "Service failed to start. Check: journalctl -u ${PROJECT_NAME} -n 50"

# ---------- final ----------
msg "Setup complete."
echo "Project:  $PROJECT_DIR"
echo "Mode:     $BOT_MODE"
echo "Runtime:  Bun ($BUN_BIN)"
if [[ "$BOT_MODE" == "webhook" ]]; then
  echo "Webhook:  ${WEBHOOK_DOMAIN}${WEBHOOK_PATH}"
  echo "Helper:   $SCRIPTS_DIR/webhook-manage.sh"
else
  echo "Polling:  no public URL needed."
fi
echo "Database: $DB_TYPE"
if [[ "$DB_TYPE" == "mariadb" ]]; then
  echo "  DB name: $DB_NAME  DB user: $DB_USER  (password saved in .env)"
elif [[ "$DB_TYPE" == "sqlite" ]]; then
  echo "  DB file: $PROJECT_DIR/data/${PROJECT_NAME}.sqlite3 (node:sqlite)"
fi
echo "Service:  systemctl status ${PROJECT_NAME} | journalctl -u ${PROJECT_NAME} -f | systemctl restart ${PROJECT_NAME}"