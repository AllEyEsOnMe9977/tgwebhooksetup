# Telegram Webhook Modular Bot Setup

## Installation

**Recommended method (reliable, supports modular folders):**

```bash
cd /opt
rm -rf tgwebhooksetup   # (optional, if you want a fresh start)
git clone https://github.com/AllEyEsOnMe9977/tgwebhooksetup.git
cd tgwebhooksetup
sudo bash setupPro.sh    # not ready_install.sh!
```

## Features

### Interactive setup

The installer asks for all required configuration values instead of relying on hardcoded settings. It validates the bot token format, the domain format, and owner chat IDs before proceeding, so misconfigured input is caught immediately rather than failing mid-install.

### Two bot modes

- **Webhook mode** — Telegram pushes updates to a public HTTPS endpoint. Requires a domain and triggers the nginx/TLS setup described below.
- **Polling mode** — the bot connects out to Telegram and pulls updates itself. No domain, nginx, or certificate is needed; useful for local setups or environments without a public IP.

### Automatic Nginx and TLS configuration

For webhook mode, the script:

- Installs `nginx` and `certbot` if not already present.
- Detects whether a server block already exists for the given domain and reuses it, or bootstraps a new one.
- Obtains and installs a Let's Encrypt certificate via `certbot --nginx`, then rewrites the site config for HTTPS with HSTS, `X-Content-Type-Options`, and `Referrer-Policy` headers.
- Adds a certbot renewal hook that automatically reloads nginx after certificate renewal.

### Modular per-project webhook routing

Instead of one monolithic nginx config, each project gets its own location snippet under `/etc/nginx/locations-<domain>/<project>.conf`, included automatically into the domain's server block. This allows multiple bots or webhook consumers to share the same domain without editing a shared config file by hand.

### Automatic port and path selection

- If no backend port is specified, the script finds a free local port automatically and verifies it isn't already in use.
- If no custom webhook path is given, it generates one combining the project name with a random suffix, reducing the chance of path guessing by outside parties.

### Secret token generation

If a webhook secret token is left blank, one is generated automatically (UUID-based) and used both in the `.env` file and in the `X-Telegram-Bot-Api-Secret-Token` verification check inside the generated bot code.

### Optional Telegram IP allowlisting

The script can restrict access to the webhook endpoint to Telegram's published IP ranges, rejecting requests from any other source at the nginx level.

### Owner-based access control

The bot requires at least one owner chat ID at setup time. Generated bot code uses this list to gate privileged commands (for example `/start`) and to send a startup notification to each owner once the bot comes online.

### Optional database provisioning

Three database options are offered:

- **None** — no database is configured.
- **SQLite** — a local file-based database; no server setup required. A `data/` directory and connection helper are created automatically.
- **MariaDB** — installs `mariadb-server` if missing, then provisions a dedicated database and user with a generated password, all recorded in `.env`.

A matching `db.ts` connection helper is generated for SQLite or MariaDB, imported automatically by the bot entry point when a database is selected.

### Process management with pm2

The bot is started and supervised using `pm2` rather than a systemd unit:

- `pm2` is installed globally if not already present.
- An `ecosystem.config.cjs` file defines restart policy (`max_restarts`, `min_uptime`, `restart_delay`) and log file locations under `logs/`.
- The process list is saved and configured to resurrect automatically on system boot.

### Generated project files

Each run produces a self-contained Node/TypeScript project, including:

- `.env` — all configuration values (bot token, secret, owner IDs, webhook details, database credentials), written with restrictive file permissions.
- `bot.ts` — a working starter bot using Telegraf, with mode-specific logic (Express server for webhook mode, long-polling loop for polling mode) and startup owner notifications.
- `db.ts` — database connection helper (only written if a database was selected).
- `package.json` — dependencies scoped to the options chosen (Express only added for webhook mode, database drivers only added if selected).
- `tsconfig.json` — TypeScript compiler configuration.
- `ecosystem.config.cjs` — pm2 process definition.
- `.gitignore` — excludes `node_modules/`, `.env`, and log files from version control.
- `scripts/webhook-manage.sh` — helper for inspecting, setting, deleting, and testing the Telegram webhook (webhook mode only).

### Webhook management helper

`scripts/webhook-manage.sh` wraps common Telegram Bot API calls:

- `info` — fetches current webhook status via `getWebhookInfo`.
- `delete` — removes the webhook via `deleteWebhook`.
- `set` — registers the webhook URL, secret token, and full `allowed_updates` list via `setWebhook`.
- `test` — sends a sample update directly to the local endpoint to verify the pipeline end to end.

### Idempotent re-runs

Database provisioning (`CREATE DATABASE IF NOT EXISTS`, `CREATE USER IF NOT EXISTS`) and nginx include-directory setup are written to be safe to run again without duplicating configuration or failing on existing resources.

### Logging

The generated bot logs incoming updates (update ID, sender, chat, update type, message text) via Telegraf middleware, and logs outcomes of owner notifications, webhook registration, and database connection attempts, so failures are visible rather than silent.
