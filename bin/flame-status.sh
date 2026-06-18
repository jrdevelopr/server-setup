#!/usr/bin/env bash
# flame-status.sh — probe each dashboard tile and prefix its name with a status dot:
#   🟢 up (got an HTTP response)   🟡 stuck (connect/read timeout)   🔴 down (refused/no response)
# Run on a timer (flame-status.timer). Idempotent: strips the old dot before re-adding,
# so it only PUTs when the status actually changed. Runs as root.
set -uo pipefail

# Pull config-derived values (FLAME_URL, FLAME_ENV, APPS_DIR) from lib.sh.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

PW=$(grep -oP '(?<=PASSWORD=).*' "$FLAME_ENV" 2>/dev/null) || exit 0
[ -n "$PW" ] || exit 0
TOKEN=$(curl -s -m5 -X POST "$FLAME_URL/api/auth" -H 'Content-Type: application/json' \
  -d "{\"password\":\"$PW\",\"duration\":\"14d\"}" | jq -r '.data.token // empty')
[ -n "$TOKEN" ] || exit 0

curl -s -m5 "$FLAME_URL/api/apps" | jq -c '.data[]' | while read -r app; do
  id=$(jq -r '.id'   <<<"$app")
  name=$(jq -r '.name' <<<"$app")
  url=$(jq -r '.url'  <<<"$app")
  icon=$(jq -r '.icon' <<<"$app")
  base=$(sed 's/^[^A-Za-z0-9]*//' <<<"$name")   # name without any existing status dot

  # Probe the LOCAL port (from the app's deploy.yaml), NOT the tile URL — tiles
  # point at the gated public URL, which would 302 at the gate and always read "up".
  # localhost works even for 127.0.0.1-only apps. Try http then https.
  port=$(grep -E '^port:' "$APPS_DIR/$base/deploy.yaml" 2>/dev/null | head -1 | sed -E 's/port:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]*$//')
  if [ -n "$port" ]; then
    code=$(curl -sk -o /dev/null -m4 --connect-timeout 2 -w '%{http_code}' "http://localhost:$port" 2>/dev/null); rc=$?
    if { [ -z "$code" ] || [ "$code" = "000" ]; } && [ "$rc" -ne 28 ]; then
      code=$(curl -sk -o /dev/null -m4 --connect-timeout 2 -w '%{http_code}' "https://localhost:$port" 2>/dev/null); rc=$?
    fi
  else
    code=$(curl -sk -o /dev/null -m4 --connect-timeout 2 -w '%{http_code}' "$url" 2>/dev/null); rc=$?
  fi
  if [ -n "$code" ] && [ "$code" != "000" ]; then emoji="🟢"   # responded
  elif [ "$rc" -eq 28 ]; then emoji="🟡"                        # timed out (stuck)
  else emoji="🔴"; fi                                           # refused / no response

  newname="$emoji $base"
  if [ "$newname" != "$name" ]; then
    curl -s -X PUT "$FLAME_URL/api/apps/$id" -H "Authorization-Flame: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg n "$newname" --arg u "$url" --arg i "$icon" '{name:$n,url:$u,icon:$i,isPinned:true}')" >/dev/null
  fi
done
