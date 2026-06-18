#!/usr/bin/env bash
# new-app.sh <name> [docker|native] ["Issue 1" "Issue 2" ...]
# Scaffold ~/apps/<name>, create + push a GitHub repo, create a Project board,
# and assign a free host port. Per the §1 workflow (see ~/apps/CLAUDE.md), the
# board is seeded with the REAL, task-specific issues you pass as extra args —
# NOT generic placeholders. If none are passed, an empty board is created and you
# plan the issues yourself (then add them with: board.sh additem <name> <issue#>).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

NAME="${1:-}"
TYPE="${2:-docker}"
[ -n "$NAME" ] || die "usage: new-app.sh <name> [docker|native] [\"Issue 1\" \"Issue 2\" ...]"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase alnum/hyphen (DNS-safe)"
[[ "$TYPE" == "docker" || "$TYPE" == "native" ]] || die "type must be 'docker' or 'native'"
# Remaining args (after name + type) are task-specific issue titles for the board.
shift $(( $# >= 2 ? 2 : 1 )) || true
ISSUES=("$@")

APP_DIR="$APPS_DIR/$NAME"
[ -e "$APP_DIR" ] && die "$APP_DIR already exists"

PORT="$(pick_port)"
SUB="$NAME"
say "Scaffolding '$NAME' (type=$TYPE) on host port $PORT"
mkdir -p "$APP_DIR"

# ── deploy.yaml ──────────────────────────────────────────────────────────
if [ "$TYPE" = "docker" ]; then
	cat > "$APP_DIR/deploy.yaml" <<YAML
name: $NAME
type: docker
subdomain: $SUB
port: $PORT          # HOST port, published on 0.0.0.0 -> http://$LAN_IP:$PORT
container_port: 80   # port the app listens on inside the container
runtime: ""
start_command: ""
deps: []
YAML

	# Starter compose: a hello-world web server so `deploy.sh` works immediately.
	# Replace the image/build with your real app, keeping the ports line intact.
	cat > "$APP_DIR/docker-compose.yml" <<YAML
services:
  app:
    image: nginxdemos/hello:plain-text
    restart: unless-stopped
    ports:
      # 0.0.0.0:<HOST_PORT>:<CONTAINER_PORT>  (values come from deploy.yaml)
      - "0.0.0.0:\${HOST_PORT}:\${CONTAINER_PORT}"
    labels:
      # Backup for Flame's "Use Docker API" discovery (primary path is deploy.sh's
      # REST registration). Same name as the API tile so Flame upserts, not dupes.
      - "flame.type=application"
      - "flame.name=$NAME"
      - "flame.url=http://$LAN_IP:$PORT"
      - "flame.icon=docker"
YAML
else
	cat > "$APP_DIR/deploy.yaml" <<YAML
name: $NAME
type: native
subdomain: $SUB
port: $PORT          # HOST port the service binds on 0.0.0.0 -> http://$LAN_IP:$PORT
container_port: ""
runtime: ""                       # informational, e.g. node20 / python3.12
start_command: "python3 -m http.server \$PORT --bind 0.0.0.0"
deps: []                          # apt packages, e.g. [python3]
YAML

	cat > "$APP_DIR/index.html" <<HTML
<!doctype html><title>$NAME</title>
<h1>$NAME</h1><p>native lab app — replace start_command + source with your real app.</p>
HTML
fi

# ── AGENTS.md (canonical) + CLAUDE.md stub ────────────────────────────────
# AGENTS.md is the single source of agent/contributor instructions — Codex and
# most agent tools read it by default. CLAUDE.md just imports it, so there's
# only ONE file to maintain.
cat > "$APP_DIR/AGENTS.md" <<MD
# $NAME

Lab app scaffolded by \`new-app.sh\`.

- **Type:** $TYPE
- **Local link:** http://$LAN_IP:$PORT  (bound 0.0.0.0 — reachable over VPN)
- **Public URL:** https://$SUB.$DOMAIN
- **Repo:** https://github.com/$GITHUB_OWNER/$NAME

## Run / redeploy
\`\`\`
~/server-setup/bin/deploy.sh $NAME
\`\`\`
Idempotent: app name = compose project / systemd unit name, so re-runs update in place.

## How it runs
$( [ "$TYPE" = docker ] && echo "Docker Compose project \`$NAME\`. Edit \`docker-compose.yml\` to set your real image/build; keep the \`ports\` line so the host port stays published on 0.0.0.0." || echo "Native systemd unit \`app-$NAME.service\`. Set \`runtime\`, \`deps\`, and \`start_command\` in deploy.yaml; the service binds \$PORT on 0.0.0.0." )

## Gotchas
- Host port is fixed at **$PORT** (range 8080–8099, tracked in deploy.yaml). Don't reuse across apps.
- Never commit secrets. Global gitignore + pre-push guard are active.
MD

# CLAUDE.md = thin stub that imports AGENTS.md (Claude Code follows @-imports), so
# AGENTS.md stays the only file you edit.
cat > "$APP_DIR/CLAUDE.md" <<'MD'
See @AGENTS.md — the single source of agent/contributor instructions for this repo
(also read natively by Codex and other agent tools).
MD

# ── git init + initial commit (global gitignore + hooks already configured) ─
say "Initializing git repo"
git -C "$APP_DIR" init -q -b main
git -C "$APP_DIR" add -A
git -C "$APP_DIR" commit -q -m "Initial scaffold for $NAME ($TYPE)"
ok "Committed initial scaffold"

# ── GitHub repo ──────────────────────────────────────────────────────────
say "Creating GitHub repo $GITHUB_OWNER/$NAME"
if gh repo view "$GITHUB_OWNER/$NAME" >/dev/null 2>&1; then
	warn "repo already exists — adding remote + pushing"
	git -C "$APP_DIR" remote get-url origin >/dev/null 2>&1 || \
		git -C "$APP_DIR" remote add origin "https://github.com/$GITHUB_OWNER/$NAME.git"
	git -C "$APP_DIR" push -u origin main
else
	gh repo create "$GITHUB_OWNER/$NAME" --private --source="$APP_DIR" --remote=origin --push
fi
ok "Repo pushed: https://github.com/$GITHUB_OWNER/$NAME"

# ── GitHub Project (v2) board + task-specific issues (§1 workflow) ────────
# No generic seeding: pass the real, task-specific issues as extra args. They are
# created and added to the board; you then work them in order with board.sh
# (start -> In Progress, done -> close -> Done).
say "Creating Project board"
PROJ_NUM=""
if PROJ_NUM=$(gh project create --owner "$GITHUB_OWNER" --title "$NAME" --format json 2>/dev/null | jq -r '.number'); then
	gh project link "$PROJ_NUM" --owner "$GITHUB_OWNER" --repo "$GITHUB_OWNER/$NAME" >/dev/null 2>&1 || true
	ok "Project board #$PROJ_NUM created (title '$NAME')"
	if [ "${#ISSUES[@]}" -gt 0 ]; then
		say "Seeding ${#ISSUES[@]} task-specific issue(s) onto the board"
		for title in "${ISSUES[@]}"; do
			[ -z "$title" ] && continue
			url=$(gh issue create --repo "$GITHUB_OWNER/$NAME" --title "$title" \
				--body "Planned task for $NAME (see ~/apps/CLAUDE.md §1 workflow)." 2>/dev/null) || { warn "failed to create issue: $title"; continue; }
			gh project item-add "$PROJ_NUM" --owner "$GITHUB_OWNER" --url "$url" >/dev/null 2>&1 || true
			ok "issue: $title"
		done
	else
		warn "No issues passed — plan them per §1, then: gh issue create ... && board.sh additem $NAME <#>"
	fi
else
	warn "Could not create Project board (continuing) — check 'gh auth status' scopes"
fi

echo
ok "Scaffold complete for '$NAME'"
echo -e "   Local (after deploy): ${G}http://$LAN_IP:$PORT${NC}"
echo -e "   Public (after deploy): ${G}https://$SUB.$DOMAIN${NC}"
echo -e "   Board:  https://github.com/users/$GITHUB_OWNER/projects/${PROJ_NUM:-?}"
echo -e "   Work issues in order: ${B}board.sh start $NAME <#>${NC} … ${B}board.sh done $NAME <#>${NC}"
echo -e "   Next step: ${B}~/server-setup/bin/deploy.sh $NAME${NC}"
