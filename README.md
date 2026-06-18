# server-setup

A reusable template for a **self-hosting app platform**: one Linux host that runs **both Docker and
native apps** behind **one Caddy reverse proxy** and **one Cloudflare Tunnel**, with a **single
branded login** (forward-auth SSO) in front of everything and a **dashboard** that auto-lists
each app. Folder-driven: drop a project in `~/apps/<name>/`, run one command, and it deploys,
routes, secures, and registers itself.

No secrets, no domains, no IPs are baked in — every deployment-specific value lives in one
`setup.conf` file you fill in. Clone it onto any fresh server and make it your own.

> 📖 **Full explanation & step-by-step build:** see **[RUNBOOK.md](RUNBOOK.md)** — architecture,
> why each piece exists, the gotchas, the security model, and the transfer checklist.

## 🚀 Paste this on a fresh Ubuntu server

Run this one block (as a sudo user). It pulls the whole setup kit into **`~/server-setup`**:

```bash
command -v git >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y git; }
git clone https://github.com/jrdevelopr/server-setup.git ~/server-setup && cd ~/server-setup && ./configure.sh
```

That clones the kit into **`~/server-setup`** and runs **`configure.sh`**, which **interactively asks you
the handful of values** (domain, GitHub owner, IP, setup name, tunnel, timezone, git identity —
with auto-detected defaults you just press Enter through) and writes them to `setup.conf`. No
hand-editing a config file.

Then just tell an agent: **“Go to `~/server-setup` and follow AGENTS.md to set up this server.”**
The agent reads [`AGENTS.md`](AGENTS.md) → [`RUNBOOK.md`](RUNBOOK.md) and takes it from there.
(`~/server-setup` is the working repo the RUNBOOK uses throughout; your answers live in `setup.conf` — which
stays host-local and gitignored, so the repo itself remains generic. Forked this repo? Swap in
your own clone URL above.)

## What's here

```
configure.sh         # interactively asks the values and writes setup.conf (no hand-editing)
setup.conf.example     # the schema configure.sh fills in (or copy to setup.conf and edit by hand)
bootstrap.sh         # one-shot host wiring from setup.conf (git hygiene, symlinks, systemd units)
bin/
  lib.sh             # shared helpers; sources setup.conf, derives all paths
  new-app.sh         # scaffold app + GitHub repo + Project board
  deploy.sh          # deploy (docker|native) -> verify local -> route -> DNS -> dashboard tile
  board.sh           # GitHub Projects v2 card mover (Todo/In Progress/Done)
  flame-status.sh    # dashboard status-dot updater (run by a timer)
caddy/Caddyfile      # reverse proxy (auto_https off, (gate) forward-auth, :80 root, import apps.d/*)
cloudflared/config.yml   # tunnel ingress (apex + wildcard -> localhost:80)
systemd/             # unit templates: cloudflared tunnel + dashboard status timer
git/                 # global gitignore + pre-push secret-scanning hook
RUNBOOK.md           # the complete guide
```

## Quick start

1. **Prereqs** (install once — see RUNBOOK §3–6): Docker + compose, Caddy, `cloudflared`, `gh`,
   `git`, `jq`. Plus a domain on Cloudflare and a GitHub account.
2. **Clone** to `~/server-setup` on the server:
   ```bash
   git clone https://github.com/GH_OWNER/server-setup ~/server-setup && cd ~/server-setup
   ```
3. **Configure** — interactively (asks the values, writes `setup.conf`):
   ```bash
   ./configure.sh                          # recommended — no hand-editing
   # or by hand:  cp setup.conf.example setup.conf && nano setup.conf
   ```
4. **Authenticate the externals** (interactive, per-host):
   ```bash
   gh auth login                 # scopes: repo, workflow, project, delete_repo
   cloudflared tunnel login      # authorize YOUR_DOMAIN's zone
   cloudflared tunnel create "$(. setup.conf; echo "$TUNNEL")"
   # paste the printed credentials path into cloudflared/config.yml
   ```
5. **Wire the host:**
   ```bash
   ./bootstrap.sh                # git hygiene, /etc/<SETUP_NAME>, caddy symlink, systemd units
   ```
6. **Stand up the front door** (deploy a dashboard app on `DASHBOARD_PORT` and a login gateway on
   `GATE_PORT`; put their secrets in `/etc/<SETUP_NAME>/`), then:
   ```bash
   sudo systemctl reload caddy
   sudo systemctl enable --now cloudflared-<TUNNEL> flame-status.timer
   ```
7. **Add apps:**
   ```bash
   bin/new-app.sh myapp docker
   bin/deploy.sh  myapp
   # → reports the local http://LAN_IP:<port> link first, then https://myapp.YOUR_DOMAIN
   ```

## Conventions (set in `setup.conf`)

| Value | Meaning |
|---|---|
| `DOMAIN` | Your Cloudflare domain |
| `LAN_IP` | Server LAN/VPN IP (the direct, ungated path) |
| `SETUP_USER` | OS user that owns `~/server-setup` + `~/apps` |
| `SETUP_NAME` | Secrets dir name → `/etc/SETUP_NAME/` |
| `TUNNEL` | Cloudflare tunnel name |
| `GITHUB_OWNER` | GitHub account/org for app repos |
| `PORT_MIN`/`PORT_MAX` | App host-port range (default 8080–8099) |
| `DASHBOARD_PORT` / `GATE_PORT` | Fixed infra ports (must match the Caddyfile) |

## Security notes (read before exposing anything)

- The public perimeter is **one shared password** (the forward-auth gate). Use a strong one.
- The **LAN/VPN path is ungated by design** (`http://LAN_IP:<port>`) — it assumes a trusted LAN.
- Apps that grant host-level power (shells, Docker socket, agent runners) sit behind that one
  password; keep the highest-risk ones LAN-only. See RUNBOOK §17.
- After you edit `setup.conf` (and `bootstrap.sh` personalizes `caddy/Caddyfile` +
  `cloudflared/config.yml`), those files contain your values — `setup.conf` is gitignored; if you
  fork and push, **keep your fork private** or don't commit the personalized configs.

MIT — adapt freely.
