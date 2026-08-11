#!/usr/bin/env bash
# Sourced helper: resolves a Tailscale API access token into $TS_TOKEN.
#
# Provide ONE of:
#   TS_API_KEY                             an API access token (tskey-api-...)
#   TS_OAUTH_CLIENT_ID + TS_OAUTH_CLIENT_SECRET
#                                          an OAuth client with scopes:
#                                          policy_file (ACL), auth_keys (keys)
#
# Tailnet defaults to "-" (the token's tailnet); override with TS_TAILNET.
set -euo pipefail

TS_API_BASE="https://api.tailscale.com/api/v2"
TS_TAILNET="${TS_TAILNET:--}"

if [[ -n "${TS_API_KEY:-}" ]]; then
  TS_TOKEN="$TS_API_KEY"
elif [[ -n "${TS_OAUTH_CLIENT_ID:-}" && -n "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
  TS_TOKEN="$(curl -sf "$TS_API_BASE/oauth/token" \
    -d "client_id=$TS_OAUTH_CLIENT_ID" \
    -d "client_secret=$TS_OAUTH_CLIENT_SECRET" |
    sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')"
  [[ -n "$TS_TOKEN" ]] || { echo "error: OAuth token exchange failed" >&2; exit 1; }
else
  cat >&2 <<'EOF'
error: no Tailscale API credentials.
Set TS_API_KEY (from https://login.tailscale.com/admin/settings/keys)
or TS_OAUTH_CLIENT_ID + TS_OAUTH_CLIENT_SECRET (OAuth client with
policy_file and auth_keys scopes).
EOF
  exit 1
fi
export TS_TOKEN TS_API_BASE TS_TAILNET
