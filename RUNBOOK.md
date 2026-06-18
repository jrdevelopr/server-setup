# RUNBOOK.md — Self-hosting infrastructure runbook

A complete, transferable guide to the "app lab" infrastructure: one Linux host that runs
**both Docker and native apps**, fronts them with **one reverse proxy** and **one Cloudflare
Tunnel**, puts a **single branded login** in front of everything, auto-registers each app on a
**dashboard**, and is driven by **two folder-aware scripts** so deploying a new app is one
command.

This document explains the *how* and the *why* so you can rebuild it on a fresh server. It is
deliberately app-agnostic — it documents the platform, not the specific apps that run on it.

> ### ⚠ Use the scripts — don't retype them from this prose
> This file is the **guide**, not the source. The actual working automation lives in **this same
> repo**: `bin/lib.sh`, `bin/deploy.sh`, `bin/new-app.sh`, `bin/board.sh`, `bin/flame-status.sh`,
> plus `caddy/Caddyfile`, `cloudflared/config.yml`, the `systemd/` units, and `bootstrap.sh`.
> **Clone the whole repo and run those** — don't re-implement them from the descriptions below.
> Rebuilding from prose is slow and re-introduces shell bugs the committed scripts have already
> fixed (real setup runs have hit exactly that). The narrative here explains *why* each script
> does what it does; the code is the source of truth.
>
> ```bash
> git clone GH_URL/GITHUB_REPO ~/lab && cd ~/lab    # get the working code, then follow §Pre-flight
> ```

> **Conventions used below.** Replace these placeholders with your own values:
> | Placeholder | This reference build | Meaning |
> |---|---|---|
> | `YOUR_DOMAIN` | `example.site` | A domain whose DNS is on Cloudflare |
> | `YOUR_IP` | `<server-lan-ip>` | The server's LAN/VPN IP (reachable by you directly) |
> | `YOUR_USER` | `examplelab` | The non-root login user that owns everything |
> | `LAB_NAME` | `examplelab` | Short name for this lab. Used for the secrets dir `/etc/LAB_NAME/`. Can match `YOUR_USER` or differ — name it whatever you like (`devlab`, `homelab`, …) |
> | `TUNNEL` | `examplelab-tunnel` | The Cloudflare tunnel name |
> | `GH_OWNER` | `example-org` | GitHub account/org that holds the repos |
> | `GH_URL` | `https://github.com/example-org` | URL of the GitHub account/org (= `https://github.com/GH_OWNER`) |
> | `GITHUB_REPO` | `examplelab` | The infrastructure repo (this `~/lab` dir) under `GH_OWNER`; cloned onto each new server. App repos are separate: `GH_OWNER/<app>` |
>
> Everything below is generic — find-and-replace these placeholders with your real values.

---

## ★ Pre-flight — gather everything BEFORE you touch the server

Read this first. Collecting these up front turns the setup into one smooth pass instead of
stopping mid-install to hunt for a value or an account.

**1. Decide your values** (they go straight into `lab.conf`):

| Value | How to get / decide it |
|---|---|
| `DOMAIN` | A domain already added to Cloudflare, nameservers pointed there (zone **active**). |
| `LAN_IP` | The server's LAN/VPN address — `ip -4 addr show` on the box. |
| `LAB_USER` | The non-root sudo user that will own `~/lab` + `~/apps` (often the user you SSH in as). |
| `LAB_NAME` | Free choice — becomes the secrets dir `/etc/LAB_NAME/` (e.g. `devlab`). |
| `TUNNEL` | Free choice — the Cloudflare tunnel's name. |
| `GITHUB_OWNER` | Your GitHub account or org. |
| `TIMEZONE` | tz database name (e.g. `America/New_York`) — `bootstrap.sh` sets it; no mid-run prompt. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | Commit identity for the repos this lab creates — set explicitly so you don't inherit a stray pre-existing global identity. |

**2. Accounts you'll authenticate interactively** (browser/device — these can't be scripted, so
have them ready and expect a prompt):
- **Cloudflare** account with `DOMAIN` active → browser login during `cloudflared tunnel login`.
- **GitHub** → `gh auth login` (scopes: `repo, workflow, project, delete_repo`).
- **(Only if deploying AI-agent apps)** Omnara — see [§2a](#2a-ai-agent-credentials--set-up-omnara-first-order-matters); do it **first**.

**3. Steps that need `sudo` / change the host / are one-way** (nothing here destroys existing
data, but know what's coming):
- `apt` installs: Docker (§4), Caddy (§5). `timedatectl set-timezone` (§3).
- `usermod -aG …` for docker + the caddy group (group changes apply on **next login**).
- systemd units written to `/etc/systemd/system` (cloudflared, status timer, native apps).
- `cloudflared tunnel create` mints a tunnel + credential file (undo = delete the tunnel).
- **If an agent is running this** (it can't type a sudo password), grant temporary passwordless
  sudo up front, and remove it when done:
  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER-temp
  sudo chmod 440 /etc/sudoers.d/$USER-temp && sudo visudo -c   # validate, or you can lock sudo out
  # ...when the build is finished:
  sudo rm /etc/sudoers.d/$USER-temp
  ```

**4. The happy path** (each step links to its section — this is the order):
1. Install prereqs: [Docker §4](#4-docker), [Caddy §5a](#5-caddy-the-reverse-proxy), `cloudflared`, `gh`, `jq`.
2. `git clone GH_URL/GITHUB_REPO ~/lab && cd ~/lab && ./configure.sh` — interactively asks the values + writes `lab.conf` (or `cp lab.conf.example lab.conf` and edit by hand).
3. `gh auth login`; `cloudflared tunnel login`; `cloudflared tunnel create "$(. lab.conf; echo $TUNNEL)"` → paste the printed credentials path into `cloudflared/config.yml`.
4. `./bootstrap.sh` — wires git hygiene, `/etc/LAB_NAME/`, the Caddy symlink, and the systemd units ([§16](#16-transferring-to-a-new-server)).
5. **Stand up the front door:** deploy a **dashboard** (a startpage app on `DASHBOARD_PORT`, empty `subdomain` so it's the root) and the **login gateway** (a forward-auth app on `GATE_PORT` with `auth: false`); put their secrets in `/etc/LAB_NAME/`. See [§9](#9-the-login-gateway)–[§10](#10-the-dashboard).
6. `sudo systemctl reload caddy && sudo systemctl enable --now cloudflared-<TUNNEL> flame-status.timer`.
7. Add apps: `bin/new-app.sh <name> docker && bin/deploy.sh <name>`.
8. **SSH-by-name** (recommended on every server): `cloudflared tunnel route dns TUNNEL ssh.YOUR_DOMAIN`, then add a `cloudflared access ssh` ProxyCommand on your client — [§6e](#6e-ssh-over-the-tunnel-do-this-on-every-server). Now `ssh ssh.YOUR_DOMAIN` works without an IP.

> **For an agent running this:** everything you need from a human is in items 1–2 above. Collect
> the six `lab.conf` values and confirm the two interactive logins can happen, *then* proceed —
> nothing else stops to ask.

---

## Table of contents

★. [Pre-flight — gather everything first](#-pre-flight--gather-everything-before-you-touch-the-server)
0. [What you end up with](#0-what-you-end-up-with)
1. [Architecture & request flow](#1-architecture--request-flow)
2. [Prerequisites & accounts](#2-prerequisites--accounts)
   - [2a. AI-agent credentials — set up Omnara FIRST](#2a-ai-agent-credentials--set-up-omnara-first-order-matters)
3. [Base server prep](#3-base-server-prep)
4. [Docker (containerized apps)](#4-docker)
5. [Caddy (the reverse proxy)](#5-caddy-the-reverse-proxy)
6. [Cloudflare Tunnel (public ingress)](#6-cloudflare-tunnel)
7. [Repo layout & the `lab` repo](#7-repo-layout)
8. [Secret hygiene (gitignore + pre-push guard)](#8-secret-hygiene)
9. [The login gateway (forward-auth SSO)](#9-the-login-gateway)
10. [The dashboard + status dots](#10-the-dashboard)
11. [The automation scripts](#11-the-automation-scripts)
12. [Per-app config & the deploy lifecycle](#12-per-app-config)
13. [GitHub: the tracked-project workflow](#13-github-tracked-project-workflow)
14. [Conventions (ports, credentials, timezone)](#14-conventions)
15. [Gotchas & hard-won lessons](#15-gotchas)
16. [Transferring to a new server](#16-transferring-to-a-new-server)
17. [Security model & caveats](#17-security-model--caveats)

---

## 0. What you end up with

- **Drop a folder, run one command, the app is live** — locally on a host port *and* publicly
  on `https://<app>.YOUR_DOMAIN`, with a login in front, a DNS record, and a dashboard tile.
- **Two runtimes, one front door.** Docker containers *and* native systemd services both sit
  behind the same Caddy proxy and the same tunnel.
- **No open ports on the host.** The public internet reaches you only through Cloudflare's
  outbound tunnel — nothing is port-forwarded, no `80/443` exposed at your firewall.
- **One password, one login page** for every app (forward-auth SSO).
- **TLS with zero certs to manage** — Cloudflare terminates HTTPS at its edge.
- **Everything is in git**, secrets are not, and a pre-push hook enforces it.

---

## 1. Architecture & request flow

```
                          Public internet (HTTPS)
                                   │
                          ┌────────▼─────────┐
                          │ Cloudflare edge  │  TLS terminates here (real cert, auto)
                          │  *.YOUR_DOMAIN   │
                          └────────┬─────────┘
                                   │  outbound tunnel (no inbound ports)
                          ┌────────▼─────────┐
                          │   cloudflared    │  systemd: cloudflared-TUNNEL.service
                          │  (on the server) │  ingress: * + apex → http://localhost:80
                          └────────┬─────────┘
                                   │ plain HTTP :80
                          ┌────────▼─────────────────────────────────┐
                          │             Caddy  (:80)                  │  auto_https OFF
                          │  routes by Host header; every route       │
                          │  does `import gate` → forward-auth        │
                          └───┬───────────────┬───────────────┬───────┘
              not logged in?  │               │ authed        │ authed
                 302 ─────────┤               ▼               ▼
                              ▼        docker app          native app
                       ┌──────────────┐  127.0.0.1:8081   systemd :8082
                       │  login gateway│  (published port) (app-<n>.service)
                       │  :8082 /verify│
                       │  branded page │
                       └──────────────┘

   You, on the LAN/VPN, also reach every app DIRECTLY at  http://YOUR_IP:<port>
   (bypasses Caddy + the gate — this is the trusted/automation path).
```

**Key design decisions and why:**

- **Cloudflare Tunnel instead of port-forwarding.** The server makes an *outbound* connection
  to Cloudflare; nothing listens on the public internet. Works behind NAT/firewalls, no static
  IP needed, and the origin IP is never exposed.
- **TLS at the edge, plain HTTP internally.** Cloudflare presents the real certificate. The
  tunnel hands Caddy plain HTTP on `:80`, so Caddy's automatic HTTPS is turned **off** — no
  ACME, no cert files, no renewals to babysit.
- **Caddy as the single internal router.** One Host-header switchboard in front of both
  runtimes. Adding an app = dropping a small snippet file and reloading.
- **Forward-auth gate instead of per-app auth.** Most self-hosted apps have weak or no auth.
  A tiny gateway authenticates once and issues a domain-wide cookie, so one login covers
  everything — even apps that ship no login at all.
- **The local-port rule.** Every app *also* publishes a host port bound to `0.0.0.0`, so the
  operator can reach it directly over the LAN/VPN before the tunnel/gate is in the path. This
  is the escape hatch that keeps automation (and you) from ever being locked out by the login.

---

## 2. Prerequisites & accounts

On the server:
- A modern Linux (this build: **Ubuntu 24.04 LTS**), a non-root sudo user (`YOUR_USER`).
- Outbound internet (the tunnel dials out; no inbound ports needed).

Accounts / one-time setup you do as a human:
- **A domain on Cloudflare.** Add `YOUR_DOMAIN` to Cloudflare and point its nameservers there.
  (Free plan is fine.) You need the zone active before the tunnel can create DNS records.
- **A GitHub account** (`GH_OWNER`) — optional but assumed here for the tracked-project workflow.

CLI tools that must be present and authenticated (install in §3):
- `cloudflared` — authenticated (`cloudflared tunnel login`, writes `~/.cloudflared/cert.pem`).
- `gh` — authenticated (`gh auth login`) with scopes `repo, workflow, project, delete_repo`.
- `git`, `curl`, `jq`.

### 2a. AI-agent credentials — set up Omnara FIRST (order matters)

**Only relevant if you'll deploy AI-agent apps** (anything that runs `claude` / `codex` /
other coding-agent CLIs — e.g. the agent-runner, control-plane, and managed-agent apps). Skip
this if your apps are plain web services.

**Do this before deploying those apps — the order is not optional:**

1. **Install [Omnara](https://omnara.com) first**, and complete **Omnara's own auth flow** to
   obtain the **Codex + Anthropic** credentials. The agent CLIs are wired to authenticate
   through Omnara's flow.
2. **Then** deploy the agent apps and point them at those credentials.

> **Why the order:** provisioning a bare Anthropic API key up front is **wasted effort** — the
> agent toolchain expects the auth that Omnara's setup produces, and a standalone key won't make
> the agents work. Get Omnara running and run *its* "get Codex / Anthropic keys" step first,
> then everything downstream just works. (Follow Omnara's current docs for the exact commands —
> they own that flow; this runbook only fixes the ordering: **Omnara → keys → agent apps.**)

The platform itself (proxy / tunnel / gate / dashboard, §§3–13) does **not** need any AI keys —
you can stand the whole host up first and only do this step when you add an agent app.

---

## 3. Base server prep

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install -y curl wget ca-certificates gnupg jq git
```

**Timezone and git commit identity are set from `lab.conf`** (`TIMEZONE`, `GIT_USER_NAME`,
`GIT_USER_EMAIL`) by `bootstrap.sh` — decide them in the pre-flight, not mid-run. If you're doing
it by hand instead:

```bash
sudo timedatectl set-timezone "America/New_York"   # your TIMEZONE
git config --global user.name  "Lab Operator"      # your GIT_USER_NAME
git config --global user.email "you@example.com"   # your GIT_USER_EMAIL — set it EXPLICITLY,
                                                   # don't inherit a stray pre-existing identity
```

> **Why a named timezone everywhere:** logs, cron, app timestamps all read the host clock.
> §14 covers how containers inherit it (and the slim-image gotcha).

---

## 4. Docker

Install Engine + the Compose **plugin** (`docker compose`, not the legacy `docker-compose`)
from Docker's official apt repo:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker YOUR_USER     # run docker without sudo (takes effect next login)
sudo systemctl enable --now docker
```

> **Gotcha:** group membership only applies on your **next login**. Scripts should detect this
> and fall back to `sudo docker` until then (see `lib.sh` in §11).

---

## 5. Caddy (the reverse proxy)

### 5a. Install (official apt repo)

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
sudo apt-get update && sudo apt-get install -y caddy
```

### 5b. Make the git-tracked Caddyfile the source of truth

Caddy ships with config at `/etc/caddy/Caddyfile`. Symlink it to a file inside your repo so the
config is versioned, and let the `caddy` service user read your home dir:

```bash
sudo usermod -aG YOUR_USER caddy            # let caddy traverse /home/YOUR_USER (mode 750)
sudo rm -f /etc/caddy/Caddyfile
sudo ln -s /home/YOUR_USER/lab/caddy/Caddyfile /etc/caddy/Caddyfile
```

### 5c. The Caddyfile

`~/lab/caddy/Caddyfile`:

```caddyfile
{
    # TLS terminates at the Cloudflare edge and the tunnel forwards plain HTTP here,
    # so disable Caddy's automatic HTTPS entirely. No certs, no ACME — Host routing on :80.
    auto_https off
    admin localhost:2019
}

# (gate) — forward-auth to the login gateway. Every public route does `import gate`.
# Strip the hop-by-hop upgrade headers from the AUTH SUBREQUEST ONLY, or WebSocket apps
# break (see §15). The original request keeps Upgrade for the real backend.
(gate) {
    forward_auth localhost:8082 {
        uri /verify
        header_up -Connection
        header_up -Upgrade
    }
}

# Root / catch-all on :80 → the dashboard. Serves the bare IP and the apex domain.
# Only ONE :80 block may exist (Caddy errors on duplicate site addresses) — edit this one.
:80 {
    import gate
    reverse_proxy localhost:5005
}

# Per-app route snippets are dropped here by deploy.sh.
import /home/YOUR_USER/lab/caddy/apps.d/*.caddy
```

A per-app snippet (`apps.d/<name>.caddy`) looks like:

```caddyfile
http://<sub>.YOUR_DOMAIN {
    import gate
    reverse_proxy localhost:<port>
}
```

> **Critical gotcha:** the `http://` scheme prefix is **required**. With `auto_https off`, a
> *bare* hostname still defaults to port **:443**, but the tunnel forwards to **:80**. Writing
> `http://<sub>...` pins the site to `:80`. Without it the route silently never matches.

Validate and reload (never full-restart in normal operation):

```bash
caddy validate --config ~/lab/caddy/Caddyfile
sudo systemctl reload caddy
sudo systemctl enable caddy
```

---

## 6. Cloudflare Tunnel

### 6a. Authenticate & create the tunnel

```bash
cloudflared tunnel login          # ← this is the Cloudflare auth step (see note below)
cloudflared tunnel create TUNNEL  # writes ~/.cloudflared/<UUID>.json (the tunnel credential)
```

> **Yes — `cloudflared tunnel login` is where Cloudflare authenticates you for *your* domain.**
> It prints a URL and opens a browser; you log into your Cloudflare account and then **pick the
> zone (`YOUR_DOMAIN`) to authorize**. On success it writes `~/.cloudflared/cert.pem`, the
> zone-scoped certificate that lets this host create tunnels and DNS records for that domain —
> no API keys to paste, no dashboard clicking. This is per-host and per-zone: redo it on each
> new server, and run it again if you add a second domain. **Prerequisite:** the domain must
> already be added to your Cloudflare account with its nameservers pointed at Cloudflare (§2),
> or it won't appear in the authorization list. If the server is headless, `cloudflared` prints
> the URL to open on any browser.

### 6b. Ingress config

`~/lab/cloudflared/config.yml`:

```yaml
tunnel: TUNNEL
credentials-file: /home/YOUR_USER/.cloudflared/<UUID>.json

ingress:
  # SSH over the tunnel (see §6e) — MUST be before the wildcard or it's treated as HTTP.
  - hostname: "ssh.YOUR_DOMAIN"
    service: ssh://localhost:22
  # The wildcard does NOT match the bare apex — it needs its own entry, listed first.
  - hostname: "YOUR_DOMAIN"
    service: http://localhost:80
  - hostname: "*.YOUR_DOMAIN"
    service: http://localhost:80
  - service: http_status:404
```

> **Gotcha:** `*.YOUR_DOMAIN` does **not** cover the apex `YOUR_DOMAIN`. If you want the bare
> domain to work, give it its own ingress rule above the catch-all. Same for `ssh.YOUR_DOMAIN` —
> the SSH rule must sit **above** the wildcard or it'll be matched as HTTP.

### 6c. Run it as a service

```bash
sudo tee /etc/systemd/system/cloudflared-TUNNEL.service >/dev/null <<'UNIT'
[Unit]
Description=Cloudflare Tunnel (TUNNEL)
After=network-online.target caddy.service
Wants=network-online.target
[Service]
Type=simple
User=YOUR_USER
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /home/YOUR_USER/lab/cloudflared/config.yml tunnel run TUNNEL
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared-TUNNEL
```

### 6d. Per-app DNS (fully automated, no dashboard)

For each app's hostname, this creates the proxied CNAME automatically (the cert authorizes it):

```bash
cloudflared tunnel route dns TUNNEL <sub>.YOUR_DOMAIN
cloudflared tunnel route dns TUNNEL YOUR_DOMAIN          # apex, once
```

> **⚠ Audit the zone FIRST (see gotcha #11).** Before routing, check the Cloudflare dashboard for
> a **Redirect Rule / Page Rule** that catches `*.YOUR_DOMAIN` — it will silently 30x all traffic
> to another site before it ever reaches your tunnel, and no on-box change can fix it. Also expect
> the apex to already have a placeholder `A` record (free it for the tunnel) and **`MX`/`SPF`/`TXT`
> email records (leave those alone)**.

> **Optional simplification:** create a single wildcard `*` CNAME → `<UUID>.cfargotunnel.com`
> in the Cloudflare dashboard once, after which even the per-app `route dns` call is unnecessary.
>
> **Deleting** a DNS record: `cloudflared` has no delete verb. Use the Cloudflare API
> (`DELETE /zones/{zone}/dns_records/{id}`) — the API token + zone id are embedded (base64 JSON)
> in the `ARGO TUNNEL TOKEN` block of `~/.cloudflared/cert.pem`.

### 6e. SSH over the tunnel (do this on every server)

Log into the box **by name from anywhere** — no IP to remember, no inbound SSH port exposed
(SSH rides the same outbound tunnel; origin IP stays hidden). The `ssh.YOUR_DOMAIN → ssh://localhost:22`
ingress rule is already in the config above. To finish it:

```bash
# 1. Make sure sshd is running (Ubuntu usually has it; install if not)
sudo systemctl enable --now ssh   # or: sudo apt-get install -y openssh-server

# 2. Route DNS for the SSH hostname
cloudflared tunnel route dns TUNNEL ssh.YOUR_DOMAIN

# 3. Restart the tunnel so it loads the new ingress, then validate
sudo systemctl restart cloudflared-TUNNEL
cloudflared tunnel --config ~/lab/cloudflared/config.yml ingress validate
```

**On each client machine** (laptop/phone) — install `cloudflared`, then add to `~/.ssh/config`:

```ssh-config
Host ssh.YOUR_DOMAIN
    ProxyCommand cloudflared access ssh --hostname %h
    User YOUR_USER
```

Now `ssh ssh.YOUR_DOMAIN` just works, using your existing key/password (the tunnel only changes
the network path). Phone: Termux (`pkg install openssh cloudflared` + same config) or Termius
(built-in Cloudflare support).

> **Verify the path** from any box with `cloudflared`:
> ```bash
> ssh -o BatchMode=yes -o "ProxyCommand=cloudflared access ssh --hostname %h" YOUR_USER@ssh.YOUR_DOMAIN true
> ```
> Reaching `Permission denied (publickey,password)` is **success** — it means SSH got through the
> tunnel to the daemon; only the no-credential `BatchMode` login was refused.
>
> **Security:** with no Cloudflare Access policy, the SSH endpoint is reachable by anyone with
> `cloudflared` + the hostname — protected only by **SSH auth**. Harden by (a) using **key-only**
> auth (`PasswordAuthentication no` in sshd), and/or (b) adding a **Cloudflare Access** policy on
> `ssh.YOUR_DOMAIN` (Zero Trust → Access) so you authenticate with Cloudflare *before* SSH is
> even reachable.

---

## 7. Repo layout

```
~/lab/                         # the infrastructure repo (push to GH_OWNER/GITHUB_REPO)
  lab.conf                     # ← THE one file you fill in (copy of lab.conf.example; gitignored)
  lab.conf.example             # template of the above (the only file you must edit)
  bootstrap.sh                 # one-shot host wiring from lab.conf
  bin/
    lib.sh                     # shared helpers; sources lab.conf, derives all paths
    new-app.sh                 # scaffold app + GitHub repo + board
    deploy.sh                  # deploy + route + dns + dashboard tile
    board.sh                   # GitHub Projects v2 card mover
    flame-status.sh            # dashboard status-dot updater (timer)
  systemd/                     # unit templates (cloudflared tunnel + status timer)
  caddy/
    Caddyfile                  # symlinked from /etc/caddy/Caddyfile
    apps.d/<name>.caddy        # one per app (written by deploy.sh)
  cloudflared/
    config.yml                 # tunnel ingress
  git/
    gitignore.global           # global excludes (secrets)
    hooks/pre-push             # secret-scanning guard

~/apps/                        # one folder per app (each its own git repo)
  <name>/
    deploy.yaml                # how to deploy this app
    docker-compose.yml         # if docker
    <source>                   # if native
    AGENTS.md                  # agent/contributor notes (canonical — Codex et al. read it)
    CLAUDE.md                  # one-line stub: `See @AGENTS.md` (Claude Code import)

/etc/LAB_NAME/                    # secrets, root-owned, chmod 600 (NEVER in git)
  <app>.env                    # per-app credentials/keys
```

Create and version it:

```bash
mkdir -p ~/lab/{bin,caddy/apps.d,cloudflared,git/hooks} ~/apps /etc/LAB_NAME
sudo chmod 700 /etc/LAB_NAME
cd ~/lab && git init -b main
# ... add files ...
gh repo create GH_OWNER/GITHUB_REPO --private --source=. --remote=origin --push
```

---

## 8. Secret hygiene

Two layers, both global (apply to **every** repo on the host):

**8a. Global gitignore** (`~/lab/git/gitignore.global`): ignores `.env`, `*.pem`, `*.key`,
`*credentials*.json`, token files, plus `node_modules/`, build dirs, OS cruft. Wire it up:

```bash
git config --global core.excludesfile /home/YOUR_USER/lab/git/gitignore.global
```

**8b. Global pre-push hook** (`~/lab/git/hooks/pre-push`): on every push, diffs the outgoing
commits and **aborts** if it finds high-signal secret patterns (GitHub `ghp_…`, AWS `AKIA…`,
Slack `xox…`, OpenAI `sk-…`, Google `AIza…`, `BEGIN … PRIVATE KEY`) or forbidden filenames
(`.env`, `*.pem`, `credentials*.json`). Wire it up:

```bash
chmod +x ~/lab/git/hooks/pre-push
git config --global core.hooksPath /home/YOUR_USER/lab/git/hooks
```

**The discipline:** *no secret ever lives under `~/apps/`.* All credentials go in
`/etc/LAB_NAME/<app>.env` (root, `chmod 600`) and are referenced by compose `env_file:` or by the
app's systemd unit. The git layers are a safety net, not the primary control.

---

## 9. The login gateway

A ~150-line **Flask forward-auth service** ("gate") gives every app one branded login with
single sign-on. It is itself just another app on the platform (its own repo + container), with
two special flags: `auth: false` (it must not gate *itself* → redirect loop) and no dashboard
tile.

**How it works:**

- Caddy's `forward_auth` calls `GET /verify` before serving any gated route.
- `/verify` returns **204** if the request carries a valid signed cookie, else **302** to a
  branded `/login` page on `auth.YOUR_DOMAIN`.
- `POST /login` checks the credential (bcrypt), then sets a **signed cookie scoped to
  `.YOUR_DOMAIN`** — so one login covers every subdomain *and* the apex.
- `/logout` clears it. Sessions are time-boxed (`itsdangerous` timed serializer).

**Endpoints:** `/verify`, `GET|POST /login`, `/logout`, `/healthz`.

**Security details that matter:**
- The cookie domain is `.YOUR_DOMAIN` (leading dot) → SSO across all apps.
- `/verify` reconstructs the original URL from `X-Forwarded-Host`/`-Uri` and forces `https`
  for the redirect (Caddy only sees internal http; trusting `X-Forwarded-Proto` would be
  spoofable).
- Open-redirect guard: the post-login `rd` target is only honored if its host is
  `YOUR_DOMAIN` or a subdomain.
- Credentials live in `/etc/LAB_NAME/gate.env`: `GATE_USER`, `GATE_SECRET_KEY` (cookie signing),
  and **`GATE_PASSWORD_HASH_B64`** — the bcrypt hash **base64-encoded** (see the §15 compose
  gotcha; base64 dodges `$`-interpolation that would corrupt the hash).

To add the gate to any route, Caddy just needs `import gate` in that route block —
`deploy.sh` does this automatically.

---

## 10. The dashboard

A self-hosted startpage (this build uses **Flame**, `pawelmalak/flame`, on port 5005) is the
**root**: the `:80` catch-all and the apex both serve it. Every deploy auto-registers/updates a
tile via the dashboard's REST API, so the homepage always reflects what's running.

**Two automation pieces (in `lib.sh` / `flame-status.sh`):**

- **`flame_register <name> <url> <icon>`** — idempotent tile upsert. *Gotchas this encodes:*
  the dashboard's auth endpoint needs a `duration` field, and protected calls use a custom
  `Authorization-Flame: Bearer <jwt>` header (not standard `Authorization`).
- **`flame-status.sh`** (run by a 60-second systemd timer) — probes each app's **local port**
  and prefixes its tile name with 🟢 up / 🟡 stuck / 🔴 down. It probes the local port, **not**
  the public tile URL, because the public URL would 302 at the gate and always look "up."

The status timer:

```bash
# /etc/systemd/system/flame-status.service  (oneshot → ExecStart=.../flame-status.sh)
# /etc/systemd/system/flame-status.timer    (OnUnitActiveSec=60s) → enable --now
```

> If your dashboard has a "discover containers from the Docker socket" feature, **turn it off**
> if you also rename tiles (e.g. status dots) via the API — the two fight and create duplicates.
> Pick one source of truth (here: the REST API).

---

## 11. The automation scripts

Four bash scripts under `~/lab/bin/` turn "a folder" into "a deployed, routed, logged-in,
dashboarded app." All are idempotent.

### `lab.conf` — the single source of deployment-specific values
All host-specific values (`DOMAIN`, `LAN_IP`, `LAB_USER`, `LAB_NAME`, `TUNNEL`,
`GITHUB_OWNER`, port range, infra ports) live in **one file**, `lab.conf` (copied from
`lab.conf.example`, gitignored). Nothing is hardcoded in the scripts. `bin/lib.sh` sources it
and derives every path from the repo's own location, so the lab works regardless of username or
where it's cloned.

### `lib.sh` — shared helpers (sourced by the rest)
- Sources `lab.conf`; derives `LAB_DIR`/`APPS_DIR`/`SECRETS_DIR` from the repo location.
- `yget <file> <key>` — read a flat `key: value` from `deploy.yaml` (tolerant of missing keys).
- `pick_port` — lowest free host port in the app range, skipping ones already claimed or bound.
- `flame_token` / `flame_register` — dashboard API (see §10).
- Docker detection: use `docker` if the group is active, else `sudo docker`.

### `new-app.sh <name> [docker|native] ["Issue 1" "Issue 2" …]`
1. Scaffold `~/apps/<name>/` (`deploy.yaml`, `CLAUDE.md`, starter compose/source), pick a free port.
2. `git init` + initial commit.
3. `gh repo create GH_OWNER/<name> --source=. --push`.
4. Create a GitHub **Project (v2)** board and seed it with the **task-specific issues you pass**
   (not generic placeholders).

### `deploy.sh <name>` — the heart of it
1. Parse `deploy.yaml`.
2. **Bring it up:** docker → `docker compose -p <name> up -d --build` (the `--build` matters,
   §15); native → write/enable an `app-<name>.service` systemd unit bound to the port on `0.0.0.0`.
3. **Verify and report the LOCAL link FIRST** — curl `http://localhost:<port>`, confirm it
   answers, print `→ LOCAL: http://YOUR_IP:<port>`. (Abort before routing if it's dead.)
4. **Write the Caddy route** `apps.d/<name>.caddy` (with `import gate` unless `auth: false`),
   then `systemctl reload caddy`.
5. **Ensure the tunnel DNS** record (idempotent).
6. **Register the dashboard tile** (public URL, unless LAN-only).
7. Print `→ PUBLIC: https://<sub>.YOUR_DOMAIN`.

Root/LAN-only apps (empty `subdomain`, or `public: false`) skip steps 4–5. A `tile: false`
flag skips step 6.

### `board.sh {start|done|status|additem} <repo> <issue#>`
Moves GitHub Projects v2 cards between Status columns. The `gh` CLI **cannot** set single-select
fields, so this uses GraphQL: resolve project → issue node → ensure item → resolve the Status
field + option IDs (which are **per-project**, so look them up every time) →
`updateProjectV2ItemFieldValue`. `done` also closes the issue.

---

## 12. Per-app config

`deploy.yaml` is the single source of truth for an app:

```yaml
name: example
type: docker            # docker | native
subdomain: example      # → example.YOUR_DOMAIN  (empty = root app, served by the :80 catch-all)
port: 8081              # HOST port, published on 0.0.0.0 → http://YOUR_IP:8081
container_port: 80      # docker only: the app's port inside the container
public: true            # false = LAN-only (skip Caddy route + DNS)
auth: true              # false = leave the route un-gated (e.g. the gate itself)
tile: true              # false = no dashboard tile
icon: docker            # dashboard icon (Material Design Icons slug)
runtime: ""             # native only, informational
start_command: ""       # native only, e.g. "python3 -m http.server $PORT --bind 0.0.0.0"
deps: []                # native only, apt packages
```

**Docker apps** keep the host port published as `0.0.0.0:${HOST_PORT}:${CONTAINER_PORT}`
(deploy.sh writes a `.env` next to the compose file so the port substitution survives `sudo`).

**Native apps** get an idempotent `app-<name>.service` unit (`User=YOUR_USER`,
`ExecStart=/bin/bash -lc '<start_command>'`, `$PORT` injected) — enabled so they survive reboot.

**Third-party / self-managed apps** (that ship their own installer + service, or a multi-service
compose) are tracked here but **not** run through `deploy.sh`'s native flow (it would create a
competing unit). You still wire their Caddy route, DNS, and tile by hand. Mark them
`self_managed: true` for clarity.

### Agent instructions: `AGENTS.md` (canonical) + a `CLAUDE.md` stub

Every repo (each app **and** the lab/infra repo) carries agent/contributor instructions in
**`AGENTS.md`** — the cross-tool standard that Codex and most agent tools read by default — and a
one-line **`CLAUDE.md`** stub that imports it:

```text
# CLAUDE.md
See @AGENTS.md — the single source of agent/contributor instructions for this repo
(also read natively by Codex and other agent tools).
```

Claude Code follows the `@AGENTS.md` import, so **`AGENTS.md` is the only file you edit** — no
keeping two docs in sync. `new-app.sh` scaffolds both automatically. (Migrating an existing repo:
`git mv CLAUDE.md AGENTS.md`, then drop the one-line stub back into `CLAUDE.md`.)

---

## 13. GitHub: tracked-project workflow

Every deployment is treated as a tracked project — even infrastructure. The standing rule:

1. **Scaffold** the app folder + a `GH_OWNER/<name>` repo; push immediately.
2. **Plan first:** break the real task into a full set of GitHub **issues**, start to finish.
3. **Board:** create a Project (v2), add every issue.
4. **Work one issue at a time:** `board.sh start` (→ *In Progress*) when you begin,
   `board.sh done` (closes it → *Done*) when finished. Watch the board move in real time.
5. **Push continuously to `main`** (no feature branches unless needed). Secrets never land
   (gitignore + hook).
6. **Report the local `YOUR_IP:<port>` link first, the repo URL second** after each push.

This is bookkeeping, but it's what makes a multi-app host auditable: every change has an issue,
every issue has a state, and the boards are the project's memory.

---

## 14. Conventions

**Ports.** App host ports live in a fixed range (**8080–8099** here), one per app, tracked in
each `deploy.yaml`; `pick_port` auto-assigns the lowest free one. Third-party apps that hardcode
a port (dashboards, control planes) are documented **exceptions** — don't remap or "collision"-flag
them.

**Credentials — one identity everywhere it's supported** (all from `lab.conf`):
- **`ADMIN_USER`** (default `admin`) — the login username; use **`ADMIN_EMAIL`** where an app
  requires an email.
- **`LAB_PASSWORD`** — the single shared production password. The operator sets it in `lab.conf`
  (via `configure.sh`, hidden prompt) **before** deploying. Apply it to the gate **and** every
  app's own login/seed, so there's literally one password. Bcrypt-hash it into
  `/etc/LAB_NAME/*.env` (base64 the hash — gotcha #3); never store it plaintext in a tracked file.
- `lab.conf` holds `LAB_PASSWORD`, so it's a **secret file** — gitignored + `chmod 600`, never committed.
- Passwordless apps (email-code or no-auth) can't use the password — they just stay behind the gate.

**Timezone.** Host set with `timedatectl`. Containers inherit it by adding
`TZ=America/New_York` (works when the image ships `tzdata`). **Slim images without zoneinfo**
(a named `TZ` silently falls back to UTC) instead bind-mount the host's zone files read-only and
set **no** `TZ`:

```yaml
volumes:
  - /etc/localtime:/etc/localtime:ro
  - /etc/timezone:/etc/timezone:ro
# and DON'T set TZ — musl/glibc read /etc/localtime when TZ is unset
```

---

## 15. Gotchas & hard-won lessons

These each cost real debugging time. They're the reason this doc exists.

1. **Bare hostnames default to `:443` even with `auto_https off`.** Caddy route blocks must be
   written `http://<host>` to pin them to `:80` (the tunnel's target). Symptom: route silently
   never matches; you hit the catch-all instead.

2. **`forward_auth` breaks WebSockets** ("WebSocket close 1006"; the app works on its direct
   port but not through the gate; the auth server returns 400). Cause: `forward_auth` copies the
   request's hop-by-hop `Upgrade`/`Connection` headers into the auth subrequest, which the
   gateway rejects → treated as "denied." Fix: `header_up -Connection` + `header_up -Upgrade`
   inside the `forward_auth` block (strips them from the *subrequest only*; the real backend
   still gets them). Test WS handshakes with `--http1.1` (over HTTP/2 the Upgrade header doesn't
   apply and you'll get a misleading result).

3. **`docker compose` interpolates `$` in `env_file` values.** A bcrypt hash like `$2b$12$…`
   gets mangled (compose treats `$2b`, `$12` as variables) — a 60-char hash arrives ~27 chars
   inside the container. Fix: **base64-encode** the value in the env file and decode it in the
   app. (Escaping each `$` as `$$` is brittle; base64 is robust.)

4. **`docker compose up` does NOT rebuild a `build:` image after you edit source.** It reuses
   the old image and runs stale code ("my fix did nothing"). Always `up -d --build` for
   build-based apps. `deploy.sh` does this unconditionally.

5. **Dashboard API quirks (Flame).** `/api/auth` requires a `duration` field; protected calls
   use a custom `Authorization-Flame: Bearer <jwt>` header, not standard `Authorization`. Token
   is at `.data.token`.

6. **GitHub Projects v2 single-selects need GraphQL.** The `gh` CLI can't set a card's Status.
   Field/option IDs are **per-project** — resolve them by name each time; an issue must be
   *added as a project item* before its fields can be set.

7. **The apex is not covered by `*.DOMAIN`** — in both the tunnel ingress and DNS. Give it its
   own entry.

8. **Don't run two `:80` blocks in Caddy** (it errors on duplicate site addresses) — edit the
   one catch-all.

9. **Status probes must hit the local port, not the public URL** — the public URL 302s at the
   gate and every app would look "up."

10. **A whole-host PaaS can't co-exist with this design.** (E.g. Dokploy's installer demands
    ports 80/443/3000, runs `docker swarm init`, and installs Traefik as *the* host proxy — it
    collides head-on with Caddy + the tunnel and would take the lab offline. Evaluate such tools
    on a dedicated VM, not this host.)

11. **A pre-existing Cloudflare Redirect Rule / Page Rule will hijack ALL traffic before it
    ever reaches your server.** Symptom: every hostname (even ones that don't exist yet) 301/302s
    to some other site, and nothing you do on the box changes it. These rules live at the **zone**
    level, not in DNS, so `cloudflared`/DNS edits can't fix them. **Before routing, audit the
    zone** (Cloudflare dashboard → Rules → *Redirect/Page/Bulk Rules*, and *Settings*) and the
    **existing apex DNS** — delete or scope any rule that catches `*.YOUR_DOMAIN`. Also: the apex
    often already has a placeholder `A` record and **`MX`/`SPF` records for email** — free the
    apex `A`/`CNAME` for the tunnel but **never touch `MX`/`TXT`/`SPF`** or you break their email.

12. **`sudo` resets the environment, so `docker compose` loses your `${VAR}` interpolation.**
    If a compose file references `${DOMAIN}` (etc.) and you run it via `sudo docker compose`
    (before the docker group is active), the var arrives **empty** and the image builds wrong.
    Two robust fixes, both used here: `deploy.sh` writes the needed values into a project-dir
    **`.env` file** (compose reads it regardless of the caller's env), *and* passes
    `sudo --preserve-env=DOMAIN,HOST_PORT,…` when it must shell out. Don't rely on exported vars
    surviving `sudo`.

13. **The docker group isn't active until your next login — detect it live, not from the user
    DB.** `groups $USER` reads the account database (shows the new group immediately) but your
    *current* shell doesn't have it yet, so you'll wrongly skip `sudo`. Check the **live** session
    with `id -nG` (or just test `docker info >/dev/null 2>&1`). Until a fresh login, keep using
    `sudo docker`.

14. **Bash `${1:?usage … {start|done}}` breaks on the literal `}`.** A `}` inside a
    `${var:?message}` default terminates the expansion early and corrupts the value. Put the usage
    text in a plain variable first (`usage="…"; action="${1:?$usage}"`), or avoid `{…}` in the
    message.

15. **`cloudflared tunnel login` is interactive (prints a URL, waits for the browser).** Run it
    as a single backgrounded process and watch for `~/.cloudflared/cert.pem` to appear — don't
    wrap it in a sub-script that exits, or the login gets killed before it finishes.

---

## 16. Transferring to a new server

The repo is portable; only host-specific values change. On the new box:

1. **Provision** (§3): user, packages, timezone.
2. **Install** Docker (§4), Caddy (§5a), cloudflared, gh.
3. **Clone the infra repo:** `git clone GH_URL/GITHUB_REPO ~/lab && cd ~/lab`.
4. **Fill in `lab.conf`** — the only file you edit. All host-specific values live here; the
   scripts read it and derive every path, so there's no scattered find-and-replace anymore:
   ```bash
   ./configure.sh                       # recommended: prompts for the values, writes lab.conf
   # or by hand: cp lab.conf.example lab.conf && nano lab.conf
   #   DOMAIN, LAN_IP, LAB_USER, LAB_NAME, TUNNEL, GITHUB_OWNER, TIMEZONE, git identity, ports
   ```
   (Two files still hold a couple of values `lab.conf` can't reach — `caddy/Caddyfile`'s
   `import` path and `cloudflared/config.yml`'s tunnel/UUID/hostnames. `bootstrap.sh` in step 6
   personalizes those for you from `lab.conf`; you only hand-paste the tunnel `<UUID>` path.)
5. **Re-establish the externals (per-host, never copied):**
   - `cloudflared tunnel login` + `cloudflared tunnel create TUNNEL` (new cert + new UUID;
     update `config.yml`).
   - `gh auth login` (scopes: repo, workflow, project, delete_repo).
   - **Regenerate all secrets** in `/etc/LAB_NAME/` — do **not** copy old ones. New gate
     `GATE_SECRET_KEY` + password hash, new app credentials, etc.
6. **Run `./bootstrap.sh`** — wires the host from `lab.conf` in one shot (idempotent):
   global gitignore + hooks path, creates `/etc/LAB_NAME/`, personalizes the `caddy/Caddyfile`
   import path + `cloudflared/config.yml` hostnames, symlinks `/etc/caddy/Caddyfile`, and
   installs the `cloudflared-<TUNNEL>` + `flame-status` systemd units. (Then paste the tunnel
   `<UUID>` path into `cloudflared/config.yml` and `enable --now cloudflared-<TUNNEL>`.)
7. **Bring up the front door, then the apps:** deploy the dashboard, deploy the login gateway,
   then `deploy.sh <app>` for each app (or re-clone each app repo into `~/apps/` and deploy).
8. **DNS:** `cloudflared tunnel route dns TUNNEL <host>` per app (or the one-time wildcard CNAME).

What is **not** transferable and must be recreated fresh: the Cloudflare cert/tunnel
credentials, the GitHub auth token, and **every secret in `/etc/LAB_NAME/`**.

---

## 17. Security model & caveats

- **Public exposure is opt-in per app.** Only apps with a Caddy route + DNS are reachable from
  the internet, and all of them sit behind the login gate. `public: false` apps are LAN/VPN-only.
- **The gate is the perimeter.** One password protects everything public. That's convenient, but
  it means the blast radius of that password = every app. Use a strong one; rotate by updating
  `/etc/LAB_NAME/gate.env` + recreating the gate container.
- **Some apps grant host-level power** (an IDE with a terminal, a Docker-socket dashboard, an
  agent runner with shell access). Behind one shared password, anyone past the login effectively
  controls the host — which could reach the rest of your network. Keep the highest-risk ones
  (anything with arbitrary shell/`exec` on the host) **LAN-only** (`public: false`), never routed.
- **The LAN/VPN path is ungated by design.** `http://YOUR_IP:<port>` bypasses Caddy and the
  gate. That's the trusted operator/automation path — it assumes the LAN/VPN itself is trusted.
  If it isn't, don't rely on the local-port escape hatch.
- **Secrets never enter git** (gitignore + pre-push guard). They live root-owned in
  `/etc/LAB_NAME/`. Tunnel/GitHub credentials live in the user's home, also gitignored.
- **Hardening to consider for production** (this build is a sandbox): an egress firewall
  limiting what the server can reach on your other subnets; Cloudflare Access (real edge SSO /
  device posture) instead of the simple gate; per-app credentials instead of one shared password;
  moving the highest-risk tools to isolated VMs.

---

## Appendix — file reference

| File | Purpose |
|---|---|
| `caddy/Caddyfile` | Reverse-proxy config; `auto_https off`, `(gate)` snippet, `:80` root, `import apps.d/*` |
| `caddy/apps.d/<name>.caddy` | Per-app route (written by `deploy.sh`) |
| `cloudflared/config.yml` | Tunnel ingress (apex + wildcard → `localhost:80`) |
| `bin/lib.sh` | Shared helpers (config, ports, dashboard API, docker detection) |
| `bin/new-app.sh` | Scaffold app + GitHub repo + Project board |
| `bin/deploy.sh` | Deploy → verify local → route → DNS → tile |
| `bin/board.sh` | GitHub Projects v2 card mover (GraphQL) |
| `bin/flame-status.sh` | Dashboard status-dot updater (systemd timer) |
| `git/gitignore.global` | Global secret excludes (`core.excludesfile`) |
| `git/hooks/pre-push` | Secret-scanning push guard (`core.hooksPath`) |
| `/etc/LAB_NAME/<app>.env` | Per-app secrets (root 600, **never** in git) |
| `~/apps/<name>/deploy.yaml` | Per-app deploy descriptor |

*This runbook documents the platform only. The specific apps deployed on top of it are
incidental — anything that serves HTTP on a local port drops into the same machinery.*
