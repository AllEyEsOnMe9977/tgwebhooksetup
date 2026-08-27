# Telegram Webhook Bot Setup Scripts

A set of interactive Bash installers that turn a fresh Debian/Ubuntu server into a running Telegram bot. Each script asks a series of questions, then provisions everything needed — nginx, TLS, an optional database, and a bot project — and starts the bot under a process manager so it stays running and survives reboots.

There are three installers, one per runtime/process-manager combination, plus one uninstaller. Pick **one** installer per project.

| Script | Runtime | Process manager | Notes |
|---|---|---|---|
| `bun-webhook-setup.sh` | Bun | systemd (native unit) | Fastest install, no build step, zero-dep sqlite via `bun:sqlite` |
| `deno-webhook-setup.sh` | Deno | systemd (native unit) | Sandboxed permissions (`--allow-net`, `--allow-read`, etc.), zero-dep sqlite via `node:sqlite` |
| `setupPro.sh` | Node.js | pm2 | Most mature ecosystem, requires a `tsc` build step before each restart |
| `bun-webhook-uninstall.sh` | — | — | Fully removes a project created by `bun-webhook-setup.sh` |

If you don't have a strong preference, use `bun-webhook-setup.sh` — it has the fewest moving parts (no separate build step, no third-party process manager to install).

> Deno/Node uninstallers aren't included yet; for those runtimes, remove the systemd unit / pm2 process and project directory manually using the same steps as the Bun uninstaller (see below).

## Purpose

Setting up a Telegram bot properly involves a lot of repetitive, error-prone steps: getting a domain behind HTTPS, writing an nginx reverse proxy, generating a webhook secret, wiring up a database, and configuring a process manager so the bot doesn't die when your SSH session closes. These scripts automate all of that in one interactive run, so you end up with a working, production-style bot instead of a pile of manual config.

Each script supports two ways of receiving Telegram updates:

- **Webhook mode** — Telegram pushes updates to a public HTTPS URL. The script sets up nginx + Let's Encrypt TLS for you. Best for VPS/servers with a public domain.
- **Polling mode** — the bot connects outward to Telegram and pulls updates itself. No domain, nginx, or certificate needed. Best for local machines, home servers, or anything without a public IP.

You can run any of these scripts multiple times on the same server to add more bots — each one detects existing nginx configs for a domain and adds a new route alongside them instead of overwriting anything.

## Prerequisites

- A Debian/Ubuntu server with `apt-get` (each script exits early on other distros).
- Root access (`sudo`).
- A Telegram bot token from [@BotFather](https://t.me/BotFather).
- For **webhook mode only**: a domain name pointing at the server's public IP, with ports 80 and 443 open.
- Your Telegram numeric chat ID(s) — message [@userinfobot](https://t.me/userinfobot) to get yours.

## Installation

First-time clone:

```bash
cd /opt
git clone https://github.com/AllEyEsOnMe9977/tgwebhooksetup.git
cd tgwebhooksetup
```

Then run whichever installer matches the runtime you want:

```bash
sudo bash bun-webhook-setup.sh    # Bun + systemd
sudo bash deno-webhook-setup.sh   # Deno + systemd
sudo bash setupPro.sh             # Node.js + pm2
```

### Updating to the latest version of the scripts

Don't delete and re-clone the repo — that discards any local edits and re-downloads everything unnecessarily. Instead, pull the latest changes in place:

```bash
cd /opt/tgwebhooksetup
git fetch origin
git pull origin main
```

If `git pull` reports local changes conflicting with the update, check `git status` first — commit or stash anything you want to keep before pulling.

> Re-running an installer script does **not** require re-cloning. The scripts are safe to run again on the same server (see "Re-running the script safely" below) — just `git pull` first to make sure you're running the latest version.

## What the scripts ask you

All three installers ask a very similar sequence of questions. Defaults are shown in `[brackets]` — press Enter to accept them.

| Prompt | Notes |
|---|---|
| Telegram bot token | Validated against Telegram's token format before continuing. |
| Bot mode: webhook or polling | `w` (default) or `p`. Determines whether nginx/TLS/domain questions appear at all. |
| Project name | Used for folder naming, nginx snippet naming, systemd unit / pm2 process naming. |
| Public HTTPS domain *(webhook mode only)* | Must start with `https://`. |
| Backend port *(webhook mode only)* | Leave blank to auto-pick a free local port. |
| Custom webhook path *(webhook mode only)* | Leave blank to auto-generate an unguessable path (`/project_XXXXXX`). |
| Install under `/opt/<project>`? | Otherwise installs in your current directory. |
| Secret token | Leave blank to auto-generate a UUID, used to verify incoming webhook requests. |
| Restrict to Telegram IP ranges? *(webhook mode only)* | Adds an nginx allowlist so only Telegram's servers can reach the endpoint. |
| Owner chat ID(s) | **Required.** Comma-separated. These IDs get startup notifications and access to owner-only commands. |
| Email for Let's Encrypt *(webhook mode only)* | Used by certbot for renewal notices. |
| Database choice | `none`, `sqlite` (zero setup, local file, built into the runtime), or `mariadb` (installs and provisions a server-backed DB + user automatically). |

`setupPro.sh` (Node/pm2) additionally asks whether to run `npm install` immediately, since Node requires a separate dependency-install and build step that Bun and Deno don't need.

## What gets installed on the server

- **nginx + certbot** (webhook mode only) — reverse proxy and free TLS certificate, auto-renewed with a reload hook.
- **Bun** or **Deno** (via their official installers) — for `bun-webhook-setup.sh` / `deno-webhook-setup.sh` respectively. Neither has an apt repo, so the shell installer is used.
- **pm2** — process manager for `setupPro.sh` only; keeps the bot running, restarts it on crash, and relaunches it on server reboot.
- **mariadb-server** — only if you chose the MariaDB database option.

The Bun and Deno scripts use a native **systemd** unit instead of pm2 — this means no extra process-manager dependency, and the service benefits from systemd hardening (dedicated unprivileged user, `ProtectSystem=strict`, `ProtectHome=true`).

## What gets generated in your project folder

Layout is the same shape across all three runtimes, with a few runtime-specific files:

```
<project-name>/
├── .env                     # bot token, secret, owner IDs, webhook/DB settings (chmod 600)
├── bot.ts                   # starter bot (Telegraf), webhook or polling logic depending on your choice
├── db.ts                    # DB connection helper (only if sqlite/mariadb was chosen)
├── data/                    # sqlite file lives here (sqlite only)
├── logs/                    # log directory (systemd journal is used for Bun/Deno; pm2 logs here for Node)
├── scripts/
│   └── webhook-manage.sh    # webhook helper (webhook mode only)
│
├── package.json             # Bun/Node only
├── tsconfig.json            # Bun/Node only (editor/type-check support; Bun ignores it at runtime)
├── ecosystem.config.cjs     # Node/pm2 only — pm2 process definition
├── deno.json                # Deno only — replaces package.json; defines least-privilege run permissions
└── .gitignore
```

The generated `bot.ts` is a real, working starter: it validates required env vars on boot, logs every incoming update (update ID, sender, chat, type, text), notifies all owner chat IDs when it comes online, and gates the `/start` command to owners only. It's meant as a foundation to build your actual bot logic on top of — not a placeholder.

## After installation

### Bun / Deno (systemd)

```bash
systemctl status <project-name>          # check the bot is running
journalctl -u <project-name> -f          # tail live logs
systemctl restart <project-name>         # restart after you edit bot.ts
```

No build step — both runtimes run `.ts` files directly, so editing `bot.ts` and restarting the service is enough.

### Node.js (pm2)

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

### Managing the webhook (webhook mode only, all runtimes)

`scripts/webhook-manage.sh` wraps the Telegram Bot API for you:

```bash
./scripts/webhook-manage.sh info     # show current webhook status (getWebhookInfo)
./scripts/webhook-manage.sh set      # (re)register the webhook URL + secret with Telegram
./scripts/webhook-manage.sh delete   # remove the webhook (e.g. before switching to polling)
./scripts/webhook-manage.sh test     # send a fake update straight to your local endpoint
```

Run `set` if `getWebhookInfo` ever shows the wrong URL, or after changing the domain/path manually.

### Adding a second bot on the same domain

Just re-run an installer with a different project name. It will detect the existing nginx server block for that domain, add a new location snippet under `/etc/nginx/locations-<domain>/`, and reload nginx — your first bot's config is left untouched. You can even mix runtimes on the same domain (e.g. one bot on Bun, another on Node) since each project is fully self-contained.

## Uninstalling a project

Currently only Bun-based projects have a dedicated uninstaller:

```bash
sudo bash bun-webhook-uninstall.sh <project-name>
```

It removes, in order, and asks for confirmation first:

1. The systemd service (stop, disable, delete unit, reload)
2. The Telegram webhook itself (best-effort `deleteWebhook` call, only if `.env` still has the token)
3. The nginx location snippet + IP-allowlist snippet for this project — and, if no other project shares the domain, offers to remove the whole nginx server block too
4. The MariaDB database + user, if this project used MariaDB (asks first)
5. The project directory (`.env`, `data/`, `logs/`, everything)
6. The dedicated system user/group created for the service

It deliberately does **not** remove nginx, certbot, Bun, or mariadb-server themselves, nor the TLS certificate (since certs are often shared/renewed independently of any one project). If you no longer need the cert, remove it manually:

```bash
certbot delete --cert-name <your-domain>
```

For Deno (systemd) or Node (pm2) projects, uninstall manually using the same steps as a guide:

```bash
# Deno
sudo systemctl stop <project-name> && sudo systemctl disable <project-name>
sudo rm /etc/systemd/system/<project-name>.service && sudo systemctl daemon-reload

# Node/pm2
pm2 delete <project-name> && pm2 save
```

Then remove the project's nginx snippet under `/etc/nginx/locations-<domain>/<project-name>.conf`, the project directory, and (if created) the dedicated system user.

## Re-running the scripts safely

The installer scripts are written to be idempotent where it matters:

- Database creation uses `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` — safe to re-run.
- nginx include-directory wiring checks for an existing include line before adding one.
- Existing server blocks for a domain are reused, not overwritten.

You can safely re-run any installer to add a new bot/project; it won't duplicate or break an existing one.

## Troubleshooting

- **Certbot fails** — the script exits with an error rather than continuing without TLS, since Telegram requires HTTPS for webhooks. Fix DNS/firewall and re-run.
- **Port already in use** — if you specify a port manually, the script checks it's free first and exits if not; leave the field blank to auto-pick one instead.
- **Webhook not receiving updates** — run `./scripts/webhook-manage.sh info` to check Telegram's view of your webhook, then check the runtime's own logs (`journalctl -u <project-name> -f` for Bun/Deno, `pm2 logs <project-name>` for Node) to confirm the bot is actually receiving requests from nginx.
- **MariaDB password** — auto-generated and saved only in `.env` (`chmod 600`). Check there if you need it.
- **`git pull` fails after editing a script locally** — run `git status` to see what changed, then either `git stash` your edits before pulling or commit them to a branch first.
