#!/usr/bin/env bash
# Mint a single-use, pre-authorized, EPHEMERAL auth key tagged tag:project-vm.
# The node it creates disappears from the tailnet shortly after going offline.
# Prints the key (tskey-auth-...) on stdout; everything else goes to stderr.
#
# Usage: TS_API_KEY=tskey-api-... scripts/mint-agent-key.sh [expiry-seconds]
#        (expiry is for the KEY itself; default 3600 = mint right before use)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/tailnet-auth.sh

EXPIRY="${1:-3600}"

resp="$(curl -sf "$TS_API_BASE/tailnet/$TS_TAILNET/keys" \
  -u "$TS_TOKEN:" \
  -H "Content-Type: application/json" \
  --data-binary @- <<EOF
{
  "description": "agent VM (single-use, ephemeral)",
  "expirySeconds": $EXPIRY,
  "capabilities": {
    "devices": {
      "create": {
        "reusable": false,
        "ephemeral": true,
        "preauthorized": true,
        "tags": ["tag:project-vm"]
      }
    }
  }
}
EOF
)"
key="$(printf '%s' "$resp" | sed -n 's/.*"key" *: *"\(tskey-[^"]*\)".*/\1/p')"
[[ -n "$key" ]] || { echo "error: no key in response: $resp" >&2; exit 1; }
echo "Join with: tailscale up --auth-key=<key> (device auto-tags tag:project-vm)" >&2
echo "$key"
