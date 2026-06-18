#!/usr/bin/env bash
# Shared helpers for the lab automation scripts.
# All deployment-specific values come from ../lab.conf (copy lab.conf.example first).

# Repo root = parent of bin/ (works no matter where the repo is cloned / which user).
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$LAB_DIR/lab.conf"
if [ ! -f "$CONF" ]; then
	echo "✗ Missing $CONF — copy lab.conf.example to lab.conf and fill it in." >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# Derived paths (apps dir is a sibling of the lab repo; override in lab.conf if you like).
APPS_DIR="${APPS_DIR:-$(dirname "$LAB_DIR")/apps}"
SECRETS_DIR="/etc/${LAB_NAME}"
CADDY_APPS_D="$LAB_DIR/caddy/apps.d"

# Colors
G='\033[0;32m'; B='\033[0;34m'; Y='\033[0;33m'; R='\033[0;31m'; NC='\033[0m'
say()  { printf "${B}==>${NC} %s\n" "$*"; }
ok()   { printf "${G}✓${NC} %s\n" "$*"; }
warn() { printf "${Y}!${NC} %s\n" "$*"; }
die()  { printf "${R}✗ %s${NC}\n" "$*" >&2; exit 1; }

# Use docker without sudo if the group is active, else fall back to sudo docker.
if docker info >/dev/null 2>&1; then
	DOCKER="docker"
else
	DOCKER="sudo docker"
fi

# yget <file> <key>  -> value for a flat "key: value" YAML line (quotes/comments stripped)
yget() {
	local file="$1" key="$2"
	# `|| true` so a missing optional key never trips `set -e`/`pipefail`.
	{ grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null || true; } | head -1 \
		| sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" \
		| sed -E 's/[[:space:]]*#.*$//' \
		| sed -E 's/^["'\'']//; s/["'\'']$//' \
		| sed -E 's/[[:space:]]+$//'
}

# Ports already claimed across all app deploy.yaml files.
used_ports() {
	grep -hE "^[[:space:]]*port:" "$APPS_DIR"/*/deploy.yaml 2>/dev/null \
		| sed -E 's/^[[:space:]]*port:[[:space:]]*//' | sed -E 's/[[:space:]]*#.*$//' \
		| grep -E '^[0-9]+$' | sort -un
}

# ── Dashboard (Flame) API ─────────────────────────────────────────────────
# Auth uses the quirky "Authorization-Flame: Bearer <jwt>" header (NOT plain
# Authorization) and /api/auth requires a duration field.
FLAME_URL="http://localhost:${DASHBOARD_PORT:-5005}"
FLAME_ENV="$SECRETS_DIR/flame.env"

flame_token() {
	local pw
	pw=$(sudo grep -oP '(?<=PASSWORD=).*' "$FLAME_ENV" 2>/dev/null) || return 1
	[ -n "$pw" ] || return 1
	curl -s -m 5 -X POST "$FLAME_URL/api/auth" -H 'Content-Type: application/json' \
		-d "{\"password\":\"$pw\",\"duration\":\"14d\"}" | jq -r '.data.token // empty'
}

# flame_register <name> <url> [icon]  — idempotent: update tile if name exists, else create.
# Best-effort: never fails a deploy if the dashboard is down.
flame_register() {
	local name="$1" url="$2" icon="${3:-web}" token id body
	if ! curl -s -m 3 -o /dev/null "$FLAME_URL/api/apps"; then
		warn "Dashboard not reachable — skipping tile for '$name'"; return 0
	fi
	token=$(flame_token) || { warn "Dashboard auth failed — skipping tile for '$name'"; return 0; }
	[ -n "$token" ] || { warn "Dashboard returned no token — skipping tile for '$name'"; return 0; }
	body=$(jq -nc --arg n "$name" --arg u "$url" --arg i "$icon" '{name:$n,url:$u,icon:$i,isPinned:true}')
	# Match by BASE name (strip any leading status-emoji prefix from flame-status.sh).
	id=$(curl -s "$FLAME_URL/api/apps" | jq -r --arg n "$name" '.data[]|select((.name|sub("^[^A-Za-z0-9]+";"")) == $n)|.id' | head -1)
	if [ -n "$id" ]; then
		curl -s -X PUT "$FLAME_URL/api/apps/$id" -H "Authorization-Flame: Bearer $token" \
			-H 'Content-Type: application/json' -d "$body" >/dev/null && ok "Dashboard tile updated: $name -> $url"
	else
		curl -s -X POST "$FLAME_URL/api/apps" -H "Authorization-Flame: Bearer $token" \
			-H 'Content-Type: application/json' -d "$body" >/dev/null && ok "Dashboard tile added: $name -> $url"
	fi
}

# pick_port  -> lowest free host port in range, skipping ones in use or bound
pick_port() {
	local p
	local taken; taken="$(used_ports)"
	for ((p=PORT_MIN; p<=PORT_MAX; p++)); do
		if ! grep -qx "$p" <<<"$taken" && ! ss -tlnH "( sport = :$p )" 2>/dev/null | grep -q .; then
			echo "$p"; return 0
		fi
	done
	die "No free host ports in ${PORT_MIN}-${PORT_MAX}"
}
