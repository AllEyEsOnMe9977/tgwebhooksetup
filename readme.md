# Telegram Webhook Bot Setup Script

A single Bash installer (`setupPro.sh`) that turns a fresh Debian/Ubuntu server into a running Telegram bot. It asks you a series of questions, then provisions everything needed — nginx, TLS, an optional database, and a Node/TypeScript bot project — and starts the bot under `pm2` so it stays running and survives reboots.

## Purpose

Setting up a Telegram bot properly involves a lot of repetitive, error-prone steps: getting a domain behind HTTPS, writing an nginx reverse proxy, generating a webhook secret, wiring up a database, and configuring a process manager so the bot doesn't die when your SSH session closes. This script automates all of that in one interactive run, so you end up with a working, production-style bot instead of a pile of manual config.

It supports two ways of receiving Telegram updates:

- **Webhook mode** — Telegram pushes updates to a public HTTPS URL. The script sets up nginx + Let's Encrypt TLS for you. Best for VPS/servers with a public domain.
- **Polling mode** — the bot connects outward to Telegram and pulls updates itself. No domain, nginx, or certificate needed. Best for local machines, home servers, or anything without a public IP.

You can also run the script multiple times on the same server to add more bots — it detects existing nginx configs for a domain and adds a new route alongside them instead of overwriting anything.

## Prerequisites

- A Debian/Ubuntu server with `apt-get` (script exits early on other distros).
- Root access (`sudo`).
- A Telegram bot token from [@BotFather](https://t.me/BotFather).
- For **webhook mode only**: a domain name pointing at the server's public IP, with ports 80 and 443 open.
- Your Telegram numeric chat ID(s) — message [@userinfobot](https://t.me/userinfobot) to get yours.

## Installation

```bash
cd /opt
rm -rf tgwebhooksetup   # optional, only if a previous copy exists
git clone https://github.com/AllEyEsOnMe9977/tgwebhooksetup.git
cd tgwebhooksetup
sudo bash setupPro.sh
```

> Use `setupPro.sh`, not `ready_install.sh` — the latter is not the current installer.

## What the script asks you

Run it and answer each prompt. Defaults are shown in `[brackets]` — press Enter to accept them.

| Prompt | Notes |
|---|---|
| Telegram bot token | Validated against Telegram's token format before continuing. |
| Bot mode: webhook or polling | `w` (default) or `p`. Determines whether nginx/TLS/domain questions appear at all. |
| Project name | Used for folder naming, nginx snippet naming, and pm2 process naming. |
| Public HTTPS domain *(webhook mode only)* | Must start with `https://`. |
| Backend port *(webhook mode only)* | Leave blank to auto-pick a free local port. |
| Custom webhook path *(webhook mode only)* | Leave blank to auto-generate an unguessable path (`/project_XXXXXX`). |
| Install under `/opt/<project>`? | Otherwise installs in your current directory. |
| Secret token | Leave blank to auto-generate a UUID, used to verify incoming webhook requests. |
| Restrict to Telegram IP ranges? *(webhook mode only)* | Adds an nginx allowlist so only Telegram's servers can reach the endpoint. |
| Owner chat ID(s) | **Required.** Comma-separated. These IDs get startup notifications and access to owner-only commands. |
| Email for Let's Encrypt *(webhook mode only)* | Used by certbot for renewal notices. |
| Run `npm install` now? | If no, you'll need to run it yourself later. |
| Database choice | `none`, `sqlite` (zero setup, local file), or `mariadb` (installs and provisions a server-backed DB + user automatically). |

## What gets installed on the server

- **nginx + certbot** (webhook mode only) — reverse proxy and free TLS certificate, auto-renewed with a reload hook.
- **pm2** — process manager that keeps the bot running, restarts it on crash, and relaunches it on server reboot.
- **mariadb-server** — only if you chose the MariaDB database option.

## What gets generated in your project folder

```
<project-name>/
├── .env                     # bot token, secret, owner IDs, webhook/DB settings (chmod 600)
├── bot.ts                   # starter bot (Telegraf), webhook or polling logic depending on your choice
├── db.ts                    # DB connection helper (only if sqlite/mariadb was chosen)
├── package.json             # dependencies scoped to your choices (Express, DB driver, etc.)
├── tsconfig.json
├── ecosystem.config.cjs     # pm2 process definition (restart policy, log paths)
├── .gitignore
├── data/                    # sqlite file lives here (sqlite only)
├── logs/                    # pm2 stdout/stderr logs
└── scripts/
    └── webhook-manage.sh    # webhook helper (webhook mode only)
```

The generated `bot.ts` is a real, working starter: it validates required env vars on boot, logs every incoming update (update ID, sender, chat, type, text), notifies all owner chat IDs when it comes online, and gates the `/start` command to owners only. It's meant as a foundation to build your actual bot logic on top of — not a placeholder.

## After installation

The script starts the bot under `pm2` automatically and saves the process list so it survives reboots. Useful commands:

```bash
pm2 status                      # check the bot is running
pm2 logs <project-name>         # tail live logs
pm2 restart <project-name>      # restart after you edit bot.ts and rebuild
```

If you edit `bot.ts` or `db.ts`, rebuild before restarting:

```bash
cd /opt/<project-name>
npm run build
pm2 restart <project-name>
```

### Managing the webhook (webhook mode only)

`scripts/webhook-manage.sh` wraps the Telegram Bot API for you:

```bash
./scripts/webhook-manage.sh info     # show current webhook status (getWebhookInfo)
./scripts/webhook-manage.sh set      # (re)register the webhook URL + secret with Telegram
./scripts/webhook-manage.sh delete   # remove the webhook (e.g. before switching to polling)
./scripts/webhook-manage.sh test     # send a fake update straight to your local endpoint
```

Run `set` if `getWebhookInfo` ever shows the wrong URL, or after changing the domain/path manually.

### Adding a second bot on the same domain

Just re-run the installer with a different project name. It will detect the existing nginx server block for that domain, add a new location snippet under `/etc/nginx/locations-<domain>/`, and reload nginx — your first bot's config is left untouched.

## Re-running the script safely

The script is written to be idempotent where it matters:

- Database creation uses `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` — safe to re-run.
- nginx include-directory wiring checks for an existing include line before adding one.
- Existing server blocks for a domain are reused, not overwritten.

You can safely re-run it to add a new bot/project; it won't duplicate or break an existing one.

## Troubleshooting

- **Certbot fails** — the script exits with an error rather than continuing without TLS, since Telegram requires HTTPS for webhooks. Fix DNS/firewall and re-run.
- **Port already in use** — if you specify a port manually, the script checks it's free first and exits if not; leave the field blank to auto-pick one instead.
- **Webhook not receiving updates** — run `./scripts/webhook-manage.sh info` to check Telegram's view of your webhook, and `pm2 logs <project-name>` to check the bot is actually receiving requests from nginx.
- **MariaDB password** — auto-generated and saved only in `.env` (`chmod 600`). Check there if you need it.
