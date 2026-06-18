#!/usr/bin/env bash
# bootstrap.sh — wire a fresh host from lab.conf (run once, after editing lab.conf).
# Idempotent and review-friendly: it prints each step. Safe to re-run.
#
#   cp lab.conf.example lab.conf && nano lab.conf   # set your values FIRST
#   ./bootstrap.sh
#
# It does NOT install Docker/Caddy/cloudflared/gh (see RUNBOOK §3–6 for those) and it
# does NOT create the tunnel or any secrets — you do those by hand (RUNBOOK), because
# they involve interactive auth and values only you can provide.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$LAB_DIR/lab.conf"
[ -f "$CONF" ] || { echo "✗ Missing lab.conf — cp lab.conf.example lab.conf && edit it first."; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

# Refuse to run with the example placeholders still in place.
for v in DOMAIN LAN_IP LAB_USER LAB_NAME TUNNEL GITHUB_OWNER; do
	val="${!v:-}"
	case "$val" in ""|example*|*'<'*) echo "✗ lab.conf: set a real value for $v (currently '$val')"; exit 1;; esac
done
say() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m✓\033[0m %s\n' "$*"; }

say "1/6  Host basics — timezone + git commit identity (from lab.conf)"
sudo timedatectl set-timezone "${TIMEZONE:-America/New_York}"
[ -n "${GIT_USER_NAME:-}" ]  && git config --global user.name  "$GIT_USER_NAME"
[ -n "${GIT_USER_EMAIL:-}" ] && git config --global user.email "$GIT_USER_EMAIL"
ok "timezone=$(timedatectl show -p Timezone --value 2>/dev/null)  git=$(git config --global user.email 2>/dev/null)"

say "2/6  Global git secret hygiene"
git config --global core.excludesfile "$LAB_DIR/git/gitignore.global"
git config --global core.hooksPath    "$LAB_DIR/git/hooks"
chmod +x "$LAB_DIR/git/hooks/pre-push" "$LAB_DIR/bin/"*.sh
ok "git excludesfile + hooksPath set"

say "3/6  Secrets directory /etc/$LAB_NAME (root, 700)"
sudo mkdir -p "/etc/$LAB_NAME"
sudo chmod 700 "/etc/$LAB_NAME"
ok "/etc/$LAB_NAME ready (put your *.env secrets here, never in git)"

say "4/6  Personalize working-copy placeholders (YOUR_USER/YOUR_DOMAIN/TUNNEL)"
sed -i "s#/home/YOUR_USER/#/home/$LAB_USER/#g" "$LAB_DIR/caddy/Caddyfile" "$LAB_DIR/cloudflared/config.yml"
sed -i "s/YOUR_DOMAIN/$DOMAIN/g"               "$LAB_DIR/cloudflared/config.yml"
sed -i "s/^tunnel: TUNNEL/tunnel: $TUNNEL/"     "$LAB_DIR/cloudflared/config.yml"
ok "Caddyfile import path + cloudflared hostnames personalized"
echo "    ! Still edit cloudflared/config.yml by hand: paste your <UUID>.json credentials path."

say "5/6  Symlink Caddy config + grant caddy read access"
sudo ln -sfn "$LAB_DIR/caddy/Caddyfile" /etc/caddy/Caddyfile
sudo usermod -aG "$LAB_USER" caddy 2>/dev/null || true
ok "/etc/caddy/Caddyfile -> $LAB_DIR/caddy/Caddyfile"

say "6/6  Install systemd units (cloudflared tunnel + dashboard status timer)"
TMP=$(mktemp -d)
sed -e "s/TUNNEL/$TUNNEL/g" -e "s#/home/YOUR_USER/#/home/$LAB_USER/#g" -e "s/User=YOUR_USER/User=$LAB_USER/" \
	"$LAB_DIR/systemd/cloudflared-tunnel.service" | sudo tee "/etc/systemd/system/cloudflared-$TUNNEL.service" >/dev/null
sed -e "s#/home/YOUR_USER/#/home/$LAB_USER/#g" "$LAB_DIR/systemd/flame-status.service" \
	| sudo tee /etc/systemd/system/flame-status.service >/dev/null
sudo cp "$LAB_DIR/systemd/flame-status.timer" /etc/systemd/system/flame-status.timer
sudo systemctl daemon-reload
sudo systemctl enable flame-status.timer >/dev/null 2>&1 || true
rm -rf "$TMP"
ok "Units installed: cloudflared-$TUNNEL.service, flame-status.{service,timer}"

cat <<EOF

Host wiring done. Remaining MANUAL steps (see RUNBOOK):
  1. cloudflared tunnel login && cloudflared tunnel create $TUNNEL
     → paste the credentials-file path into cloudflared/config.yml, then:
       sudo systemctl enable --now cloudflared-$TUNNEL
  2. Deploy the dashboard app (port $DASHBOARD_PORT) and the login gateway (port $GATE_PORT),
     putting their secrets in /etc/$LAB_NAME/.
  3. systemctl reload caddy && systemctl start flame-status.timer
  4. Add apps with: bin/new-app.sh <name> && bin/deploy.sh <name>
EOF
