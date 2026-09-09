#!/usr/bin/env bash
# Render the NGINX vhosts for this host and install the allow list.
#
#   sudo CBS_HOST=fineract-uat.example CONSOLE_HOST=cbs-console-uat.example \
#        CBS_ALLOW="10.0.0.4/32 197.0.0.0/24" ./render.sh
#
# The allowed addresses are supplied here, at render time, and never committed. This
# repository is a public fork of apache/fineract; an allow list in git is a map of who can
# reach the core banking system.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CBS_HOST:?set CBS_HOST}"
: "${CBS_ALLOW:?set CBS_ALLOW, space separated CIDRs (the banking service host and operator addresses)}"
FINERACT_PORT="${FINERACT_PORT:-8080}"
CONSOLE_PORT="${CONSOLE_PORT:-8081}"

install -d -m 755 /etc/nginx/snippets
: > /etc/nginx/snippets/malipopay-cbs-allow.conf
for cidr in $CBS_ALLOW; do printf '%s 1;\n' "$cidr" >> /etc/nginx/snippets/malipopay-cbs-allow.conf; done
echo "allow list:"; sed 's/^/  /' /etc/nginx/snippets/malipopay-cbs-allow.conf

render() {
  local tpl="$1" out="$2"
  CBS_HOST="$CBS_HOST" CONSOLE_HOST="${CONSOLE_HOST:-}" FINERACT_PORT="$FINERACT_PORT" \
  CONSOLE_PORT="$CONSOLE_PORT" \
    envsubst '${CBS_HOST} ${CONSOLE_HOST} ${FINERACT_PORT} ${CONSOLE_PORT}' < "$tpl" > "$out"
  echo "rendered $out"
}

render "$HERE/fineract.conf.template" "/etc/nginx/sites-available/malipopay-cbs.conf"
ln -sf /etc/nginx/sites-available/malipopay-cbs.conf /etc/nginx/sites-enabled/malipopay-cbs.conf
if [[ -n "${CONSOLE_HOST:-}" ]]; then
  render "$HERE/console.conf.template" "/etc/nginx/sites-available/malipopay-cbs-console.conf"
  ln -sf /etc/nginx/sites-available/malipopay-cbs-console.conf /etc/nginx/sites-enabled/malipopay-cbs-console.conf
fi

nginx -t
echo
echo "Config is valid but NOT yet reloaded, because the certificates may not exist yet."
echo "  certbot certonly --nginx -d ${CBS_HOST}${CONSOLE_HOST:+ -d $CONSOLE_HOST}"
echo "  systemctl reload nginx"
echo
echo "Then prove the allow list from an address that is NOT on it: expect 403, not a login"
echo "prompt. A rule you have not tried from the wrong side is not a rule."
