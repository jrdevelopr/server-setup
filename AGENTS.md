# AGENTS.md — server-setup

> Single source of agent/contributor instructions, in the open [AGENTS.md](https://agents.md)
> format (Codex, Cursor, Copilot, Claude Code, Aider … all read this; `CLAUDE.md` is just a
> one-line `@AGENTS.md` stub). Keep it concise, current, and **anonymous** (placeholders only).

## Project overview
A reusable kit that turns a fresh Linux server into a self-hosting **app platform**: Docker **and**
native apps behind **one Caddy reverse proxy** + **one Cloudflare Tunnel**, every app behind a
**single branded login**, each app auto-listed on a **dashboard**. Folder-driven: drop an app in
`~/apps/<name>/`, run one command, it deploys + routes + secures + registers itself. No inbound
ports; TLS at the Cloudflare edge. Full guide: **[RUNBOOK.md](RUNBOOK.md)** (start at ★ Pre-flight).

## Setup / build commands (use these — do NOT retype them from prose)
```bash
./configure.sh                       # interactively writes setup.conf (the only values you set)
./bootstrap.sh                       # wires the host from setup.conf (timezone, git, secrets dir, caddy, units)
bin/new-app.sh <name> [docker|native] ["Issue 1" ...]   # scaffold app + GitHub repo + Project board
bin/deploy.sh  <name>                # deploy -> verify local -> route -> DNS -> dashboard tile
bin/board.sh   {start|done|status|additem} <repo> <issue#>   # move Project board cards
```

## How to operate (you have broad autonomy)
- **Don't ask for approval on routine work.** Installs, builds, deploys, file edits, git
  commits/pushes to app & infra repos, Caddy/DNS/systemd changes — just do them. Only stop for:
  (a) a genuinely destructive/irreversible action with no sensible default, or (b) something only
  the human can give you — secrets, the interactive Cloudflare/GitHub logins, or `SETUP_PASSWORD`.
- **Work the tracked-project flow** (RUNBOOK §13): repo + Project board + issues, and move cards
  In Progress → Done as you go.
- **Verify before you report. Always.** After any deploy, actually test it end-to-end and
  re-check until green — never report success you haven't confirmed:
  - `curl` the **local port** (HTTP 200/redirect), then the **public URL through the gate**;
  - confirm the **dashboard tile** registered; for WebSocket apps, test the upgrade (`101`).
- **Report links as clickable Markdown, and ALWAYS give BOTH:**
  - **Public:** `https://<app>.<DOMAIN>` (behind the login)
  - **Private:** `http://<LAN_IP>:<port>` (direct on LAN/VPN)

## Security — the one hard boundary (otherwise free range)
- **NEVER commit or push secrets or env files.** No `.env`, `*.env`, `setup.conf`, passwords, API
  keys, tokens, bcrypt hashes, or tunnel credentials to GitHub. The global gitignore + pre-push
  hook enforce this — **do not bypass them** (`--no-verify` is forbidden).
- **Secrets live host-local only:** `setup.conf` (gitignored, `chmod 600`) and `/etc/<SETUP_NAME>/*.env`
  (root, `chmod 600`).
- **Keep this repo anonymous:** placeholders only — no real domains, IPs, users, emails, or
  tunnel IDs anywhere in tracked files.
- **NEVER push a server's config to the PUBLIC template.** The operational copy's `origin` must
  point at this server's **private** `BACKUP_REPO` (`<host>-setup-live`), which `bootstrap.sh`
  sets up. Before committing/pushing config, confirm `git remote -v` is the private repo — if it
  still shows `…/server-setup` (the public kit), stop and re-point it.

## Auth convention — every app sits behind the login
- **Every public app is gated by the Caddy forward-auth login** (one branded splash page covers
  them all via an SSO cookie). `deploy.sh` adds `import gate` automatically — **leave it on.**
  Only the gate app itself is `auth: false`; genuinely LAN-only apps are `public: false`.
- **One shared production password for everything** (the splash login *and* each app's own
  login): **`SETUP_PASSWORD`** from `setup.conf`. The human sets it before you start — never invent
  or print it; read it from config and seed each app with it.
- **Username is always `admin`** — or an **email** where an app requires one, using
  **`ADMIN_EMAIL`** from `setup.conf` (`ADMIN_USER` holds the default).
- Apps with **no native auth** are still safe behind the gate. Apps that can run a **host shell**
  (browser IDE, Docker-socket UI, agent runners) → keep **LAN-only** unless told otherwise.

## Conventions
- App host ports **8080–8099** (one per app, auto-assigned by `pick_port`); dashboard **5005**,
  gate **8082** — third-party fixed ports are documented exceptions, don't remap them.
- Timezone, git identity, ports, and all the above credentials come from **`setup.conf`** (set once
  via `configure.sh`). Nothing host-specific is hardcoded in the scripts.
- Each new app carries its own **`AGENTS.md`** (canonical) + a **`CLAUDE.md`** `@AGENTS.md` stub.
- Third-party apps that ship their own service/installer are `self_managed: true` — don't run
  them through `deploy.sh`'s native flow (it would create a competing systemd unit).

## Maintaining this repo
This is the shared kit reused across servers. When a real run surfaces a bug or a smoother step,
fold it into `RUNBOOK.md` / the scripts here — but **ask the owner before pushing** changes to it.
