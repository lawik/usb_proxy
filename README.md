# usbproxy

Nerves firmware for a Raspberry Pi 4 that exports lab hardware to agent
VMs over Tailscale: USB devices via USB/IP, serial consoles via TCP, a
local flash service, and a recovery endpoint. The agent-facing API is
built with Ash on Phoenix and exposed twice from one endpoint — as a
JSON API (AshJsonApi, `/api`) and as an MCP server (ash_ai, `/mcp`).

See `PLAN.md` for the phased implementation plan and verification
checklists.

## Architecture notes

- **Auth is the tailnet ACL** (`tailnet/policy.hujson`): `tag:project-vm`
  nodes reach `tag:usbproxy` on ports 3240 (usbip), 4000 (API/MCP/health)
  and 7000–7099 (serial consoles) — nothing else, in either direction.
  The HTTP endpoint deliberately has no auth plug.
- **TFTP is the file transfer** (`UsbProxy.Tftp`, UDP 69 + transfer
  ports 6900–6999). Read *and* write, one flat directory on the data
  partition, no authentication and no namespacing — the same server
  answers target boards netbooting off the lab LAN and agents pushing
  images over the tailnet, and it does not tell them apart. Uploads are
  atomic (temp file + rename), so a board never reads half an image.
  Agents discover and clean up files through the API/MCP
  (`list_tftp_files`, `delete_tftp_file`); the bytes never go through
  HTTP. Note the protocol's own ceiling: 16-bit block numbers cap a
  transfer at 65535 × blksize — 32 MiB with default 512-byte blocks,
  ~92 MiB at blksize 1468 — and oversized files are refused up front
  with an explanation rather than failing halfway.
- **Boot reconciliation only.** The box assumes nothing about prior
  state on startup; power cuts are routine, clean shutdown is not a
  concept. Anything that depends on a shutdown handler is a bug.
- **Event log**: operationally significant events (boots, binds,
  attaches, flashes, recovery) append to a size-capped JSONL file on
  the data partition (`/data/usb_proxy/events.log`), datasync'd per
  entry so it survives power cuts.
- **Custom system**: `lawik/nerves_system_rpi4`, branch `usbip` —
  adds `CONFIG_USBIP_CORE/HOST`, usbip userspace tools, dfu-util,
  uhubctl, usbutils, eudev (libudev for usbip; udevd never runs).
  Tailscale is NOT in the system: static arm64 binaries are fetched
  into `rootfs_overlay/usr/bin/` by `scripts/fetch-tailscale.sh`.

## Building firmware

```sh
scripts/fetch-tailscale.sh   # once, and after version bumps
mix deps.get
MIX_TARGET=rpi4 mix firmware
MIX_TARGET=rpi4 mix burn
```

The custom system is built on the m1mini build machine (lima VM `dev`);
`scripts/buildhost.sh` wraps `ssh m1mini` + `limactl shell dev`:

```sh
scripts/buildhost.sh --sync                 # push local system tree to the VM
scripts/buildhost.sh 'cd nerves_system_rpi4 && mix nerves.artifact'
scripts/buildhost.sh --get <vm-path> <local-path>
```

## Provisioning a device

1. Mint a reusable `tag:usbproxy` auth key: `scripts/mint-usbproxy-key.sh`
   (needs `TS_API_KEY`). Put it in `.envrc` as `TAILSCALE_AUTHKEY`
   (gitignored; direnv loads it).
2. `MIX_TARGET=rpi4 mix burn` — the custom system's fwup provisioning
   writes `tailscale_authkey` into uboot-env at burn time from
   `$TAILSCALE_AUTHKEY`. Plug in the Pi; it joins the tailnet as
   `usbproxy` unattended.
3. Node identity lives in `/data/tailscale` and survives reboots, power
   cuts, and firmware updates — the key is only used on first boot (or
   after reformatting the data partition).

Fallbacks if the card was burned without the env var: over local ssh run
`Nerves.Runtime.KV.put("tailscale_authkey", "tskey-auth-...")`, or write
the key to `/data/tailscale/authkey`.

## Tailnet operations

- `scripts/tailnet-apply-acl.sh` — validate + apply `tailnet/policy.hujson`
- `scripts/mint-agent-key.sh` — single-use ephemeral `tag:project-vm` key
- `scripts/mint-usbproxy-key.sh` — reusable `tag:usbproxy` key
- `scripts/verify-phase1.sh` — run from a scratch agent VM to verify the ACL

All need `TS_API_KEY` (or `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_CLIENT_SECRET`
with `policy_file` + `auth_keys` scopes).
