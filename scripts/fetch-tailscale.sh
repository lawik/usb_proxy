#!/usr/bin/env bash
# Fetch the Tailscale static arm64 build into the firmware rootfs_overlay.
# The binaries are gitignored; run this before building firmware.
# Usage: scripts/fetch-tailscale.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.102.2}"
DEST=rootfs_overlay/usr/bin
TGZ="tailscale_${VERSION}_arm64.tgz"
URL="https://pkgs.tailscale.com/stable/$TGZ"

if [[ -x "$DEST/tailscaled" ]] && "$DEST/tailscaled" --version 2>/dev/null | head -1 | grep -q "^$VERSION$"; then
  echo "tailscaled $VERSION already present" >&2
  exit 0
fi

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Fetching $URL" >&2
curl -sfL "$URL" -o "$tmp/$TGZ"
tar -xzf "$tmp/$TGZ" -C "$tmp"
install -m 755 "$tmp/tailscale_${VERSION}_arm64/tailscale" "$DEST/tailscale"
install -m 755 "$tmp/tailscale_${VERSION}_arm64/tailscaled" "$DEST/tailscaled"
echo "Installed tailscale + tailscaled $VERSION into $DEST" >&2
