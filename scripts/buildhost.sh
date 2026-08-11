#!/usr/bin/env bash
# Operate the Nerves system build host: the lima "dev" VM on m1mini.
# Reached via: ssh m1mini -> limactl shell dev. Work dir in the VM: ~/usbproxy
#
# Usage:
#   scripts/buildhost.sh --sync [dir]     push local nerves_system_rpi4 tree
#                                         (default ~/sprawl/nerves_system_rpi4)
#                                         into VM ~/usbproxy/ (overlays files,
#                                         keeps build output)
#   scripts/buildhost.sh --get <vm-path> <local-path>
#                                         copy a file out of the VM
#   scripts/buildhost.sh <command...>     run command in VM (cwd ~/usbproxy)
set -euo pipefail

M1="m1mini"
LIMA="/opt/homebrew/bin/limactl"

vm() { # run a bash -lc command string in the VM, stdin passed through
  ssh "$M1" "$LIMA shell dev -- bash -lc $(printf '%q' "$1")"
}

case "${1:-}" in
  --sync)
    src="${2:-$HOME/sprawl/nerves_system_rpi4}"
    tar -C "$(dirname "$src")" --exclude .git -czf - "$(basename "$src")" |
      vm 'mkdir -p ~/usbproxy && tar -xzf - -C ~/usbproxy'
    echo "synced $src -> VM:~/usbproxy/$(basename "$src")"
    ;;
  --get)
    vm "cat $(printf '%q' "$2")" > "$3"
    echo "copied VM:$2 -> $3"
    ;;
  "")
    echo "usage: buildhost.sh --sync [dir] | --get <vm> <local> | <command...>" >&2
    exit 2
    ;;
  *)
    vm "cd ~/usbproxy && $*"
    ;;
esac
