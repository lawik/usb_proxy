#!/usr/bin/env bash
# Phase 1 verification. RUN THIS ON A SCRATCH VM joined with an agent key
# (scripts/mint-agent-key.sh). It checks the ACL from the agent's viewpoint.
#
# Usage: verify-phase1.sh <usbproxy-host> <denied-node1> <denied-node2> <denied-node3> [second-agent-ip]
#   usbproxy-host   tailnet name/IP of the usbproxy (or a tagged stand-in
#                   listener if the usbproxy doesn't exist yet)
#   denied-nodeN    3+ non-usbproxy tailnet nodes that must be unreachable
#   second-agent-ip optional: another agent-tagged VM (agent->agent must fail)
set -uo pipefail

USBPROXY="${1:?usage: verify-phase1.sh <usbproxy> <deny1> <deny2> <deny3> [agent2]}"
DENY1="${2:?need 3 denied nodes}"; DENY2="${3:?need 3 denied nodes}"; DENY3="${4:?need 3 denied nodes}"
AGENT2="${5:-}"

pass=0; fail=0
ok()   { echo "PASS: $*"; pass=$((pass+1)); }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }

# Reachability: connect must complete OR be actively refused (RST means the
# packet got through the ACL; a timeout means it was dropped by the ACL).
reachable() { # host port
  nc -z -w 5 "$1" "$2" 2>/dev/null && return 0
  # nc exits nonzero on refused too; distinguish refused (reachable) from
  # timeout (filtered) by timing: refusals come back fast.
  local t0 t1
  t0=$(date +%s); nc -z -w 5 "$1" "$2" 2>/dev/null; t1=$(date +%s)
  [ $((t1 - t0)) -lt 4 ]
}

echo "== Allowed: usbproxy service ports =="
for port in 3240 4000 7000; do
  if reachable "$USBPROXY" "$port"; then ok "$USBPROXY:$port reachable"; else bad "$USBPROXY:$port NOT reachable"; fi
done

echo "== Denied: usbproxy non-service port (SSH) =="
if reachable "$USBPROXY" 22; then bad "$USBPROXY:22 reachable (should be filtered)"; else ok "$USBPROXY:22 filtered"; fi

echo "== Denied: other tailnet nodes =="
for node in "$DENY1" "$DENY2" "$DENY3"; do
  for port in 22 80 443 4000; do
    if reachable "$node" "$port"; then bad "$node:$port reachable (should be filtered)"; else ok "$node:$port filtered"; fi
  done
done

echo "== Denied: Tailscale SSH from agent =="
for target in "$USBPROXY" "$DENY1"; do
  if timeout 10 tailscale ssh "root@$target" true 2>/dev/null; then
    bad "tailscale ssh to $target succeeded (must be rejected)"
  else
    ok "tailscale ssh to $target rejected"
  fi
done

if [ -n "$AGENT2" ]; then
  echo "== Denied: agent -> agent =="
  for port in 22 4000 3240; do
    if reachable "$AGENT2" "$port"; then bad "agent2 $AGENT2:$port reachable"; else ok "agent2 $AGENT2:$port filtered"; fi
  done
else
  echo "note: no second agent IP given; agent->agent check skipped"
fi

echo
echo "Manual checks remaining (admin console):"
echo "  - delete this VM / take it offline; it must vanish from the device list (ephemeral)"
echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
