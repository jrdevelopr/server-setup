#!/usr/bin/env bash
# deploy.sh <name>
# Read ~/apps/<name>/deploy.yaml -> deploy (docker|native) -> verify LOCAL link
# first -> write Caddy route + reload -> create tunnel DNS -> print PUBLIC URL.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: deploy.sh <name>"
APP_DIR="$APPS_DIR/$NAME"
YAML="$APP_DIR/deploy.yaml"
[ -f "$YAML" ] || die "no deploy.yaml at $YAML (run new-app.sh $NAME first)"

TYPE="$(yget "$YAML" type)"
SUB="$(yget "$YAML" subdomain)"
PORT="$(yget "$YAML" port)"
CPORT="$(yget "$YAML" container_port)"
PUBLIC="$(yget "$YAML" public)"; PUBLIC="${PUBLIC:-true}"
AUTH="$(yget "$YAML" auth)";     AUTH="${AUTH:-true}"
TILE="$(yget "$YAML" tile)";     TILE="${TILE:-true}"
ICON="$(yget "$YAML" icon)"
[ -n "$PORT" ] || die "port not set in $YAML"
# A blank subdomain means "root app" (e.g. Flame) — routed by the :80 catch-all,
# not by a per-app block. public:false means LAN-only. Both skip Caddy+DNS.
ROUTABLE=1
[ -z "$SUB" ] && ROUTABLE=0
[ "$PUBLIC" = "false" ] && ROUTABLE=0
# default tile icon
[ -z "$ICON" ] && { [ "$TYPE" = native ] && ICON=console || ICON=docker; }

say "Deploying '$NAME' (type=$TYPE) on host port $PORT"

# ── 1. Bring the app up ──────────────────────────────────────────────────
if [ "$TYPE" = "docker" ]; then
	[ -f "$APP_DIR/docker-compose.yml" ] || die "docker type but no docker-compose.yml"
	# Compose reads .env from the project dir for ${VAR} interpolation. Writing a FILE
	# (rather than exported vars) survives sudo's env reset — the gotcha where a compose
	# referencing ${DOMAIN} builds empty under `sudo docker compose`. No secrets here.
	cat > "$APP_DIR/.env" <<ENVEOF
HOST_PORT=$PORT
CONTAINER_PORT=${CPORT:-80}
SUBDOMAIN=$SUB
DOMAIN=$DOMAIN
LAN_IP=$LAN_IP
GATE_PORT=${GATE_PORT:-8082}
DASHBOARD_PORT=${DASHBOARD_PORT:-5005}
ENVEOF
	say "docker compose up (project=$NAME)"
	# --build so source changes in build-based apps are always picked up (no-op for image-only apps).
	( cd "$APP_DIR" && $DOCKER compose -p "$NAME" up -d --remove-orphans --build )
elif [ "$TYPE" = "native" ]; then
	DEPS="$(yget "$YAML" deps | tr -d '[]' | tr ',' ' ')"
	START="$(yget "$YAML" start_command)"
	[ -n "$START" ] || die "native type requires start_command in deploy.yaml"
	if [ -n "${DEPS// /}" ]; then
		say "Installing apt deps: $DEPS"
		sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $DEPS
	fi
	UNIT="app-$NAME"
	say "Writing systemd unit $UNIT.service"
	# Expand $PORT inside start_command; keep other env literal.
	EXPANDED_START="${START//\$PORT/$PORT}"
	sudo tee "/etc/systemd/system/$UNIT.service" >/dev/null <<UNITEOF
[Unit]
Description=App: $NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SETUP_USER
WorkingDirectory=$APP_DIR
Environment=PORT=$PORT
ExecStart=/bin/bash -lc '$EXPANDED_START'
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
UNITEOF
	sudo systemctl daemon-reload
	sudo systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
	sudo systemctl restart "$UNIT"
else
	die "unknown type '$TYPE' (expected docker|native)"
fi

# ── 2. Verify + report the LOCAL link FIRST ──────────────────────────────
say "Verifying local link (this is how you confirm it's actually running)"
local_ok=0
for i in $(seq 1 15); do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT" || true)
	if [ -n "$code" ] && [ "$code" != "000" ]; then local_ok=1; break; fi
	sleep 1
done
echo
if [ "$local_ok" = 1 ]; then
	printf "${G}→ LOCAL:  http://%s:%s${NC}   (verified, HTTP %s)\n" "$LAN_IP" "$PORT" "$code"
else
	printf "${R}→ LOCAL:  http://%s:%s   (NOT responding — check the app)${NC}\n" "$LAN_IP" "$PORT"
	if [ "$TYPE" = docker ]; then $DOCKER compose -p "$NAME" ps; else sudo systemctl status "app-$NAME" --no-pager -n 15 || true; fi
	die "Aborting before routing — fix the app, then re-run deploy.sh $NAME"
fi

# ── 3 + 4. Caddy route + tunnel DNS (skipped for root / LAN-only apps) ────
if [ "$ROUTABLE" = 1 ]; then
	say "Writing Caddy route $SUB.$DOMAIN -> localhost:$PORT"
	# NOTE: the http:// scheme is required — a bare hostname defaults to :443 even
	# with auto_https off, but the tunnel forwards to :80. http:// pins it to :80.
	# `import gate` puts this route behind the gate login (forward-auth). Internet
	# traffic must log in; direct host-port LAN access is not gated. Set `auth: false`
	# in deploy.yaml to leave a route open (e.g. gate itself, to avoid a redirect loop).
	if [ "$AUTH" = "false" ]; then GATE_LINE=""; else GATE_LINE=$'\timport gate'; fi
	cat > "$CADDY_APPS_D/$NAME.caddy" <<CADDYEOF
http://$SUB.$DOMAIN {
$GATE_LINE
	reverse_proxy localhost:$PORT
}
CADDYEOF
	if sudo systemctl reload caddy; then ok "Caddy reloaded"; else
		die "Caddy reload failed — check: caddy validate --config $SETUP_DIR/caddy/Caddyfile"
	fi

	say "Ensuring tunnel DNS route for $SUB.$DOMAIN"
	if cloudflared tunnel route dns "$TUNNEL" "$SUB.$DOMAIN" 2>/tmp/route.$$; then
		ok "DNS route created"
	elif grep -qiE 'already (exists|configured)|record with that host' /tmp/route.$$; then
		ok "DNS route already exists (skipped)"
	else
		warn "DNS route command reported: $(tr -d '\n' </tmp/route.$$)"
	fi
	rm -f /tmp/route.$$
else
	[ -z "$SUB" ] && warn "No subdomain — root app, served by the :80 catch-all (no per-app route/DNS)"
	[ "$PUBLIC" = "false" ] && warn "public:false — LAN-only, skipping Caddy route + DNS"
fi

# ── 5. Register/refresh the Flame dashboard tile (idempotent, best-effort) ─
# Skip for infra/utility apps that shouldn't appear as a tile (tile: false).
if [ "$TILE" = "false" ]; then
	warn "tile:false — skipping Flame tile for '$NAME'"
else
	say "Registering Flame tile"
	# Tile links to the PUBLIC URL (apex for the root app), except LAN-only apps
	# which link to their local host:port. (Local links live in Flame's "Local (LAN)"
	# bookmark group; status dots probe the local port regardless — flame-status.sh.)
	if [ "$PUBLIC" = "false" ]; then TILE_URL="http://$LAN_IP:$PORT"
	elif [ -z "$SUB" ];        then TILE_URL="https://$DOMAIN"
	else                            TILE_URL="https://$SUB.$DOMAIN"; fi
	flame_register "$NAME" "$TILE_URL" "$ICON"
fi

# ── 6. Report links ──────────────────────────────────────────────────────
echo
printf "${G}→ LOCAL:  http://%s:%s${NC}\n" "$LAN_IP" "$PORT"
if [ "$ROUTABLE" = 1 ]; then
	printf "${G}→ PUBLIC: https://%s.%s${NC}\n" "$SUB" "$DOMAIN"
	echo -e "   (edge TLS via Cloudflare tunnel; may take a few seconds to propagate)"
elif [ -z "$SUB" ]; then
	printf "${G}→ PUBLIC: https://%s${NC}  (root / apex)\n" "$DOMAIN"
else
	echo -e "   (LAN-only — not routed publicly)"
fi
