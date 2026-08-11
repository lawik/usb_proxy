#!/usr/bin/env bash
# Validate and apply tailnet/policy.hujson to the tailnet.
# Usage: TS_API_KEY=tskey-api-... scripts/tailnet-apply-acl.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/tailnet-auth.sh

POLICY=tailnet/policy.hujson

echo "== Validating policy (including its embedded tests) =="
# /acl/validate returns 200 with a JSON error body on failure, so check content.
resp="$(curl -sf "$TS_API_BASE/tailnet/$TS_TAILNET/acl/validate" \
  -u "$TS_TOKEN:" \
  -H "Content-Type: application/hujson" \
  --data-binary "@$POLICY")"
if [[ -n "$resp" && "$resp" != "{}" ]]; then
  echo "Validation failed:" >&2
  echo "$resp" >&2
  exit 1
fi
echo "OK"

echo "== Applying policy =="
curl -sf "$TS_API_BASE/tailnet/$TS_TAILNET/acl" \
  -u "$TS_TOKEN:" \
  -H "Content-Type: application/hujson" \
  --data-binary "@$POLICY" >/dev/null
echo "Applied. Review at https://login.tailscale.com/admin/acls"
