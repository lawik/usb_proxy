#!/usr/bin/env bash
# Mint a REUSABLE, pre-authorized, NON-ephemeral auth key tagged tag:usbproxy.
# Used when burning usbproxy SD cards; the node identity persists on the
# device's data partition, so the same key can provision replacement cards.
# Prints the key (tskey-auth-...) on stdout; everything else goes to stderr.
#
# Usage: TS_API_KEY=tskey-api-... scripts/mint-usbproxy-key.sh [expiry-seconds]
#        (default 7776000 = 90 days)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/tailnet-auth.sh

EXPIRY="${1:-7776000}"

resp="$(curl -sf "$TS_API_BASE/tailnet/$TS_TAILNET/keys" \
  -u "$TS_TOKEN:" \
  -H "Content-Type: application/json" \
  --data-binary @- <<EOF
{
  "description": "usbproxy provisioning (reusable)",
  "expirySeconds": $EXPIRY,
  "capabilities": {
    "devices": {
      "create": {
        "reusable": true,
        "ephemeral": false,
        "preauthorized": true,
        "tags": ["tag:usbproxy"]
      }
    }
  }
}
EOF
)"
key="$(printf '%s' "$resp" | sed -n 's/.*"key" *: *"\(tskey-[^"]*\)".*/\1/p')"
[[ -n "$key" ]] || { echo "error: no key in response: $resp" >&2; exit 1; }
echo "$key"
