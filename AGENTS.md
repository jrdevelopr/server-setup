# AGENTS.md — server-scripts

Instructions for an agent (or human) using this repo to stand up a self-hosting **app lab** on a
fresh Linux server. This is the canonical instructions file (Codex and most agent tools read it
by default; `CLAUDE.md` just imports it).

## What this repo is
A reusable template: Docker **and** native apps behind **one Caddy reverse proxy** + **one
Cloudflare Tunnel**, with a single **forward-auth login** in front of everything and an
auto-updating **dashboard**. Folder-driven — drop an app in `~/apps/<name>/`, run one command,
and it deploys, routes, secures, and registers itself. No inbound ports; TLS at the Cloudflare
edge.

## How to use it — IN THIS ORDER
1. **Read `RUNBOOK.md` start to finish first**, especially the **★ Pre-flight** section. It lists
   every value, account, and sudo/irreversible step you need *before* touching the server.
2. **Use the scripts in `bin/` — do NOT re-type them from the prose.** Clone this whole repo; the
   working code (`bin/*.sh`, `bootstrap.sh`, `caddy/`, `cloudflared/`, `systemd/`) is the source
   of truth. Rebuilding from the narrative re-introduces bugs the committed scripts already fixed.
3. **Gather all human inputs up front** (the `lab.conf` values, the two interactive logins —
   Cloudflare + GitHub, and temporary passwordless sudo for agent-driven runs), then run
   start-to-finish without stopping to ask.
4. `./configure.sh` (prompts for the values → writes `lab.conf`) → `./bootstrap.sh` → follow the RUNBOOK happy path.

## Hard rules
- **Never commit secrets.** Real values live only in the host-local, **gitignored** `lab.conf`
  and in `/etc/<LAB_NAME>/`. The global gitignore + pre-push hook enforce this.
- **Keep this repo generic/anonymous** — placeholders only (`YOUR_DOMAIN`, `<server-lan-ip>`,
  `examplelab`, …) so it works on any server. No real domains, IPs, users, emails, or tunnel IDs.
- **Every app deployment is a tracked project** (GitHub repo + Project board + issues) — RUNBOOK §13.
- **Each app carries `AGENTS.md` (canonical) + a `CLAUDE.md` `@AGENTS.md` stub** — one file to edit.

## Maintaining this repo
When a real setup run surfaces a bug or a smoother step, fold it back into `RUNBOOK.md` and the
scripts here — but **ask the owner before pushing changes** to this shared repo.
