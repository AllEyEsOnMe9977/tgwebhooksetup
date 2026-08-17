#!/usr/bin/env bash
###############################################################################
# bun-webhook-uninstall.sh — Full removal of a project created by
# bun-webhook-setup.sh
#
# Usage: sudo ./bun-webhook-uninstall.sh <project-name>
#
# Removes, in order:
#   1. systemd service (stop, disable, unit file, daemon-reload)
#   2. Telegram webhook (deleteWebhook, best-effort, only if .env has a token)
#   3. nginx location snippet + allowlist snippet for this project
#      (and the whole domain server block IF this was the only project on it)
#   4. Project directory (/opt/<name> or ./<name> — auto-detected)
#   5. Dedicated system user/group created for the service
#
# Does NOT remove: nginx/certbot/bun/mariadb-server themselves, the TLS
# certificate (certbot certs are often reused/renewed independently), or
# other projects sharing the same domain.
###############################################################################
set -euo pipefail
IFS=$'\n\t'

COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"
msg()  { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*"; }
warn() { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()  { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root

# ---------- input ----------
PROJECT_NAME="${1:-}"
if [[ -z "$PROJECT_NAME" ]]; then
  read -rp "Project name to uninstall: " PROJECT_NAME
fi
[[ -n "$PROJECT_NAME" ]] || die "Project name is required."
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid project name."

# ---------- locate project dir (mirrors setup script's two possible locations) ----------
if [[ -d "/opt/$PROJECT_NAME" ]]; then
  PROJECT_DIR="/opt/$PROJECT_NAME"
elif [[ -d "$(pwd)/$PROJECT_NAME" ]]; then
  PROJECT_DIR="$(pwd)/$PROJECT_NAME"
else
  read -rp "Project directory not found under /opt or ./ — enter full path (blank to skip): " PROJECT_DIR
fi

if [[ -n "${PROJECT_DIR:-}" && -d "$PROJECT_DIR" ]]; then
  msg "Project directory: $PROJECT_DIR"
else
  warn "No project directory found/given — will still clean up service, nginx, and user if present."
  PROJECT_DIR=""
fi

# ---------- confirm ----------
echo
warn "This will PERMANENTLY delete:"
echo "  - systemd service: ${PROJECT_NAME}.service"
[[ -n "$PROJECT_DIR" ]] && echo "  - project directory: $PROJECT_DIR (including .env, data/, logs/)"
echo "  - nginx snippets for: $PROJECT_NAME"
echo "  - system user/group: $PROJECT_NAME"
echo
read -rp "Type the project name again to confirm deletion: " CONFIRM
[[ "$CONFIRM" == "$PROJECT_NAME" ]] || die "Confirmation did not match. Aborted, nothing was deleted."

# ---------- 1. systemd service ----------
SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
if [[ -f "$SERVICE_FILE" ]]; then
  msg "Stopping and disabling systemd service"
  systemctl stop "${PROJECT_NAME}.service" 2>/dev/null || true
  systemctl disable "${PROJECT_NAME}.service" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed "${PROJECT_NAME}.service" 2>/dev/null || true
  msg "Removed $SERVICE_FILE"
else
  warn "No systemd unit found at $SERVICE_FILE — skipping."
fi

# ---------- 2. delete Telegram webhook (best-effort, needs .env token) ----------
if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  BOT_TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
  if [[ -n "${BOT_TOKEN:-}" ]] && have curl; then
    msg "Deleting Telegram webhook for this bot"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" >/dev/null \
      || warn "Could not reach Telegram API to delete webhook (skipping, not fatal)."
  fi
else
  warn "No .env found — skipping Telegram deleteWebhook call."
fi

# ---------- 3. nginx cleanup ----------
if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/.env" ]]; then
  WEBHOOK_DOMAIN="$(grep -E '^WEBHOOK_DOMAIN=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
  DOMAIN_CLEAN="${WEBHOOK_DOMAIN#https://}"
else
  DOMAIN_CLEAN=""
fi

# Fallback: if .env is gone, try to find a locations-<domain> dir containing this project's snippet
if [[ -z "$DOMAIN_CLEAN" ]]; then
  for d in /etc/nginx/locations-*/; do
    [[ -f "${d}${PROJECT_NAME}.conf" ]] || continue
    DOMAIN_CLEAN="$(basename "$d" | sed 's/^locations-//')"
    break
  done
fi

if [[ -n "$DOMAIN_CLEAN" ]]; then
  INCLUDE_DIR="/etc/nginx/locations-$DOMAIN_CLEAN"
  SNIPPET_ALLOWLIST="/etc/nginx/snippets/${PROJECT_NAME}-telegram_allowlist.conf"

  if [[ -f "${INCLUDE_DIR}/${PROJECT_NAME}.conf" ]]; then
    rm -f "${INCLUDE_DIR}/${PROJECT_NAME}.conf"
    msg "Removed nginx location snippet: ${INCLUDE_DIR}/${PROJECT_NAME}.conf"
  fi
  if [[ -f "$SNIPPET_ALLOWLIST" ]]; then
    rm -f "$SNIPPET_ALLOWLIST"
    msg "Removed allowlist snippet: $SNIPPET_ALLOWLIST"
  fi

  # If no other project snippets remain for this domain, offer to remove the whole server block.
  REMAINING=0
  if [[ -d "$INCLUDE_DIR" ]]; then
    REMAINING="$(find "$INCLUDE_DIR" -maxdepth 1 -name '*.conf' | wc -l)"
  fi

  if [[ "$REMAINING" -eq 0 ]]; then
    warn "No other webhook projects remain on domain '$DOMAIN_CLEAN'."
    read -rp "Remove the entire nginx server block + TLS site for $DOMAIN_CLEAN too? (y/N): " RM_DOMAIN
    RM_DOMAIN=${RM_DOMAIN,,}
    if [[ "$RM_DOMAIN" == "y" ]]; then
      rm -f "/etc/nginx/sites-available/${DOMAIN_CLEAN}.conf"
      rm -f "/etc/nginx/sites-enabled/${DOMAIN_CLEAN}.conf"
      rm -rf "$INCLUDE_DIR"
      msg "Removed nginx site config and include dir for $DOMAIN_CLEAN"
      warn "TLS certificate under /etc/letsencrypt was NOT removed. Run 'certbot delete --cert-name $DOMAIN_CLEAN' manually if you no longer need it."
    else
      msg "Left the $DOMAIN_CLEAN server block in place (now with no webhook locations included)."
    fi
  else
    msg "$REMAINING other webhook project(s) still use domain $DOMAIN_CLEAN — leaving server block intact."
  fi

  if have nginx; then
    nginx -t && systemctl reload nginx || warn "nginx reload failed — check config manually with 'nginx -t'."
  fi
else
  warn "Could not determine webhook domain — skipping nginx cleanup (may be polling-mode project, which never had nginx config)."
fi

# ---------- 3b. MariaDB cleanup (only if this project used mariadb) ----------
if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/.env" ]]; then
  DB_TYPE_VAL="$(grep -E '^DB_TYPE=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
  if [[ "$DB_TYPE_VAL" == "mariadb" ]]; then
    DB_NAME_VAL="$(grep -E '^DB_NAME=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    DB_USER_VAL="$(grep -E '^DB_USER=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    if [[ -n "$DB_NAME_VAL" && -n "$DB_USER_VAL" ]] && have mysql; then
      warn "This project used MariaDB: database '$DB_NAME_VAL', user '$DB_USER_VAL'."
      read -rp "Drop this MariaDB database and user too? (y/N): " DROP_DB
      DROP_DB=${DROP_DB,,}
      if [[ "$DROP_DB" == "y" ]]; then
        msg "Dropping MariaDB database and user"
        mysql -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME_VAL}\`;
DROP USER IF EXISTS '${DB_USER_VAL}'@'localhost';
FLUSH PRIVILEGES;
SQL
        msg "Dropped database '$DB_NAME_VAL' and user '$DB_USER_VAL'."
      else
        msg "Left MariaDB database '$DB_NAME_VAL' and user '$DB_USER_VAL' in place."
      fi
    fi
  fi
fi

# ---------- 4. project directory ----------
if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
  rm -rf "$PROJECT_DIR"
  msg "Removed project directory: $PROJECT_DIR"
fi

# ---------- 5. dedicated system user ----------
if id -u "$PROJECT_NAME" >/dev/null 2>&1; then
  userdel "$PROJECT_NAME" 2>/dev/null || warn "Could not delete user '$PROJECT_NAME' (may still own files elsewhere)."
  msg "Removed system user: $PROJECT_NAME"
else
  warn "No system user '$PROJECT_NAME' found — skipping."
fi
if getent group "$PROJECT_NAME" >/dev/null 2>&1; then
  groupdel "$PROJECT_NAME" 2>/dev/null || true
fi

# ---------- final ----------
msg "Uninstall complete for project: $PROJECT_NAME"