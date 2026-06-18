#!/usr/bin/env bash
# rotate-password.sh — propagate SETUP_PASSWORD (from setup.conf) to the OS login + every app.
#
#   1. Edit SETUP_PASSWORD in setup.conf      (nano setup.conf)
#   2. Run:  bin/rotate-password.sh
#
# The password is READ from setup.conf (never passed as an argument, so it stays out of shell
# history). The script then re-applies it everywhere, auto-DISCOVERING apps — nothing is
# hardcoded:
#   • OS login (chpasswd) for SETUP_USER
#   • the credential reference file  /etc/<SETUP_NAME>/caddy-auth.txt
#   • every Docker app whose compose file pulls an env file from /etc/<SETUP_NAME>/:
#       - a  GATE_PASSWORD_HASH_B64=  field  -> bcrypt(password) | base64  (the login gate)
#       - a  PASSWORD=                field  -> the plaintext password
#     …then recreates that app so it loads the new value.
#   • apps whose login lives in their OWN database (an ADMIN_PASSWORD= field, e.g. control
#     panels) can't be set from outside — the env value is kept in sync for a fresh seed and
#     the app is listed for a one-time change in its own UI. Each still sits behind the gate,
#     so rotating the gate already re-secures access to it.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

PW="${SETUP_PASSWORD:-}"
USER_NAME="${ADMIN_USER:-admin}"
[ -n "$PW" ] || die "SETUP_PASSWORD is empty in setup.conf — set it first, then re-run."
command -v caddy >/dev/null 2>&1 || die "caddy not found (needed to hash the gate password)."
say "Rotating the password everywhere (login user '$USER_NAME')"

# 1) OS login (SSH + console) for the owner account.
if echo "$SETUP_USER:$PW" | sudo chpasswd 2>/dev/null; then ok "OS login ($SETUP_USER)"
else warn "OS password change failed (need sudo)"; fi

# 2) Plaintext credential reference, if present.
if sudo test -f "$SECRETS_DIR/caddy-auth.txt"; then
	sudo sed -i "s|^CADDY_AUTH_USER=.*|CADDY_AUTH_USER=$USER_NAME|; s|^CADDY_AUTH_PASSWORD=.*|CADDY_AUTH_PASSWORD=$PW|" "$SECRETS_DIR/caddy-auth.txt"
	ok "credential reference (caddy-auth.txt)"
fi

# 3) Discover Docker apps and rotate the secret each one actually uses.
#    Map env-file -> app by reading which compose file references it (no naming assumptions:
#    a gate app dir can reference a differently-named env file and it's still found).
MANUAL=""   # apps that store their login in their own DB → collected for a manual note
recreate() { ( cd "$APPS_DIR/$1" && sudo docker compose -p "$1" up -d --force-recreate >/dev/null 2>&1 ); }

for dir in "$APPS_DIR"/*/; do
	app=$(basename "$dir")
	compose="$dir/docker-compose.yml"
	[ -f "$compose" ] || continue
	# env files this app pulls from the secrets dir
	mapfile -t envs < <(grep -hoE "${SECRETS_DIR}/[A-Za-z0-9_.-]+\.env" "$compose" 2>/dev/null | sort -u)
	[ "${#envs[@]}" -gt 0 ] || continue
	for envf in "${envs[@]}"; do
		sudo test -f "$envf" || continue
		if sudo grep -qE '^GATE_PASSWORD_HASH_B64=' "$envf"; then
			HASH_B64=$(caddy hash-password --plaintext "$PW" | base64 -w0)
			sudo sed -i "s|^GATE_USER=.*|GATE_USER=$USER_NAME|; s|^GATE_PASSWORD_HASH_B64=.*|GATE_PASSWORD_HASH_B64=$HASH_B64|" "$envf"
			recreate "$app" && ok "$app (login gate — every app's front door)" || warn "$app recreate failed"
		elif sudo grep -qE '^PASSWORD=' "$envf"; then
			sudo sed -i "s|^PASSWORD=.*|PASSWORD=$PW|" "$envf"
			recreate "$app" && ok "$app" || warn "$app recreate failed"
		elif sudo grep -qE '^ADMIN_PASSWORD=' "$envf"; then
			# DB-seeded: keep the env value in sync (used on a fresh seed) but it can't be
			# pushed into an already-initialised app from here.
			sudo sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$PW|" "$envf"
			MANUAL="$MANUAL $app"
		fi
	done
done

echo
if [ -n "$MANUAL" ]; then
	warn "Apps that store their login in their OWN database can't be rotated from here. Each one"
	warn "still sits behind the gate, so the new gate password already re-secures access — change"
	warn "the inner login in-app only if you want that second layer rotated too:"
	for a in $MANUAL; do echo "    • $a → change the password in its own UI"; done
	echo
fi
ok "Done. New password is live for: SSH/console, the login gate, and every env-based app."
echo "   Login username: $USER_NAME   (email where an app requires one: ${ADMIN_EMAIL:-n/a})"
