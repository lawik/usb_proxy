# Nerves USB Gateway — Implementation Plan

Goal: a Raspberry Pi running Nerves that exports USB devices (USB/IP), serial consoles (TCP), a local flash service, and a recovery endpoint to agent VMs on a server over Tailscale. The usbproxy's API surface is built with **Ash** on **Phoenix**, exposing the same actions as a **JSON API** (AshJsonApi) and an **MCP server** (ash_ai) so agents can discover devices and services either way. Agents must be able to reach the usbproxy's published ports and nothing else. Deployment story: burn SD card with NervesHub and Tailscale credentials, plug in Pi, done.

Reference project for Nerves + Phoenix wiring: https://github.com/nerves-project/nerves_examples/tree/main/hello_live_view — follow its structure for the non-poncho layout and config.

Work the phases in order. Do not start a phase until the previous phase's verification passes. Every phase ends with concrete checks — run them all.

---

## Phase 1 — Tailnet policy

Do this first so that everything built afterward is tested under the real security policy, not an allow-all network.

1. Create tags: `tag:project-vm`, `tag:usbproxy`.
2. Replace the default allow-all ACL:
   - Admin devices → everything.
   - `tag:project-vm` → `tag:usbproxy` on: 3240 (usbip), the serial port range (pick one now, e.g. 7000–7099), and the API port (e.g. 4000 — serves JSON API, MCP, and health from one Phoenix endpoint).
   - No other rules involving `tag:project-vm`. No SSH grants to or from `tag:project-vm`.
3. Create an API-minted, single-use, pre-authorized, tagged ephemeral key flow for agents (script or note the exact API call). Create a normal (non-ephemeral) reusable approach for the usbproxy.

**Confirm:**
- [ ] From a scratch VM joined with an agent key: `nc -vz <usbproxy> 3240` and `nc -vz <usbproxy> 4000` succeed (or connect-and-reset if nothing is listening yet — reachability is what's being tested; use any tagged test node as a stand-in listener if the usbproxy doesn't exist yet).
- [ ] From the same VM: connection to the desktop's SSH port over the tailnet **fails**. Connection to any port on any non-usbproxy node **fails**. Test at least 3 nodes.
- [ ] Agent VM cannot Tailscale-SSH anywhere: `tailscale ssh <any-node>` is rejected.
- [ ] Deleting the scratch VM (or letting it go offline) removes it from the device list within the ephemeral timeout.
- [ ] A second scratch VM cannot reach the first scratch VM (agent→agent denied).

---

## Phase 2 — Custom Nerves system

This should be done on a specific build machine. You can reach it via `ssh m1mini` and then running the tool `limactl shell dev` to get the shell. Build a script that makes operating that practical for you. Fork `nerves_system_rpi4`. Don't build on sliver. It is a weak laptop, m1mini is a dedicated machine at least.

You can pack up a nerves artifact to deliver the final build for use. We shouldn't have to do too many laps. You are fine to push it as a branch to lawik/nerves_system_rpi4 for now.

1. Kernel config: enable `USBIP_CORE`, `USBIP_HOST` (host/export side; `VHCI_HCD` is not needed on the usbproxy but is harmless to include).
2. Buildroot packages: usbip userspace tools, `dfu-util`, `uhubctl`, `fwup` is already present.
3. Build the system, build a minimal firmware, burn, boot.

**Confirm:**
- [ ] Pi boots the custom system; `iex` accessible over local console.
- [ ] `usbipd` binary runs on target (`cmd "usbipd --version"`).
- [ ] `usbip list -l` on target shows locally attached USB devices.
- [ ] `uhubctl` on target lists the Pi's hub and reports port power state.
- [ ] `dfu-util --version` and each vendor tool run without missing-library errors.
- [ ] `cat /dev/watchdog` behavior confirms watchdog device exists (don't hold it open).

---

## Phase 3 — Base usbproxy firmware

The application skeleton, networking, Phoenix endpoint, and the boot-reconciliation principle.

1. Project layout per the hello_live_view example: monolithic structure (not a poncho) with everything in the firmware app. Add Ash, AshJsonApi, and ash_ai as deps now, even though resources come later — get the dependency tree compiling for the target early.
2. Add tailscaled (use existing Nerves tailscale prior art, downloading a static build at runtime is fine or packing it in at build-time) running under a supervisor. State directory on the application data partition so identity survives reboots and power cuts.
3. Join the tailnet with the usbproxy (non-ephemeral) key, tagged `tag:usbproxy`.
4. Phoenix endpoint (Bandit) on the API port. Listener on `0.0.0.0`.
5. Establish the boot-reconciliation rule in the app skeleton: startup code assumes nothing about prior state. There is no shutdown handler that matters.
6. Wire `heart` and the hardware watchdog (Nerves defaults mostly cover this; verify config).
7. Logging: keep RingLogger, and add a persistent append-only event log on the data partition for operationally significant events (flash operations, binds, attaches, recovery actions). Small, size-capped, survives power cuts.

**Confirm:**
- [ ] Pi appears on tailnet with stable name; survives reboot with same node identity (check device list — no duplicate node).
- [ ] Phoenix answers a trivial route (`GET /up` → 200) from an agent VM over the tailnet.
- [ ] Pull power mid-operation 5 times in a row. Pi returns to tailnet unattended every time, Phoenix answering, every time.
- [ ] Kill the BEAM (`:erlang.halt` via console without reboot flag, or `kill -9` the beam process): watchdog/heart recovers the box unattended.
- [ ] Event log file exists after a hard power cut and contains pre-cut entries.

---

## Phase 4 — Device registry and hotplug bind

The GenServer that owns "what hardware exists and what's exported." This will later be the data layer behind the Ash `Device` resource, so keep its query interface clean.

1. Subscribe to `nerves_uevent` (or poll `/sys/bus/usb/devices` as fallback) for USB add/remove events.
2. On device appearance: Resolve current busid, run `usbip bind`, record state.
3. On device removal: update state. On reappearance (including re-enumeration into a different mode, e.g. DFU): re-match, re-bind automatically.
4. Registry is queryable: stable name → current busid, bind status, attach status, plus full snapshot.
5. On boot: full reconciliation — enumerate, match, bind everything that shows up.
6. Disable autosuspend for exported devices (write `on` to `power/control` in sysfs when binding).

**Confirm:**
- [ ] Boot with devices attached: all devices bound within seconds of boot (check `usbip list -r <usbproxy>` from a tailnet machine).
- [ ] Hot-plug a device: bound automatically, no manual action, event logged.
- [ ] Unplug/replug: busid may change (use different physical port); registry reflects new busid, bind succeeds.
- [ ] Put a DFU-capable device into DFU mode (it re-enumerates with a different VID:PID): It re-binds automatically. Time the gap.
- [ ] `power/control` reads `on` for every bound device.

---

## Phase 5 — Ash resources, JSON API, and MCP

The API layer. Everything agent-facing from here on is an Ash action exposed twice: once via AshJsonApi, once as an ash_ai tool over MCP. Internal code calls the same actions directly.

1. Resources (manual/ETS-style data layers backed by the Phase 4 registry and later services — there is no database on this box):
   - `Device`: reads only for now — `list`, `get by stable name`. Attributes: stable name, VID:PID, serial, busid, present?, bound?, attached?, kind (usbip/serial/flash-target).
   - `SerialConsole`: `list` — stable name, TCP port, status. (Backing service arrives in Phase 6; until then it reads is empty.)
   - Placeholders for `FlashJob` and `RecoveryAction` (created in Phases 8–9); define the resource modules now so the API shape is stable, actions can error with `not_implemented`.
2. AshJsonApi routes under `/api` on the Phoenix endpoint.
3. MCP: forward `/mcp` to `AshAi.Mcp.Router` with the tool list. **No auth plug in the `:mcp` pipeline** — reachability over the tailnet is the auth, per the ACL from Phase 1. Pin `protocol_version_statement` per the Phase 0 decision.
4. Tools exposed at this phase: `list_devices`, `get_device`, `list_serial_consoles`. Write tool descriptions as if the reader is an agent that has never seen the hardware — the MCP tool list is agent-facing documentation.
5. Keep one rule: no service reaches around Ash. Serial, flash, and recovery services (later phases) are invoked *through* resource actions so JSON, MCP, and internal callers can never disagree.

**Confirm:**
- [ ] `GET /api/devices` from an agent VM returns the devices with live present/bound state matching reality (unplug one, re-query, state changed).
- [ ] The chosen MCP client (Phase 0) connects to `http://<usbproxy>:4000/mcp` **with no credentials**, completes initialization, and lists the tools.
- [ ] MCP `list_devices` tool call returns the same data as the JSON API.
- [ ] An actual agent session (Claude or equivalent) is pointed at the MCP server and successfully answers "what devices are available and which are free?" using only tool calls.
- [ ] Malformed MCP request (bad JSON-RPC) gets a clean protocol error, not a crash; endpoint still up (check `/up`).

---

## Phase 6 — Serial console service

One TCP listener per serial device, plus its Ash surface.

1. `circuits_uart` per adapter, enumerated by serial number (stable identity), mapped to a TCP port (within the ACL'd range).
2. TCP listener per console on `0.0.0.0`. Raw byte pipe, no protocol.
3. Supervision: adapter unplugged → listener stays up, returns connection or explicit error; adapter returns → console resumes. Client disconnect/reconnect is stateless and instant.
4. Decide and implement single-client vs multi-observer semantics (recommend: single writer, or simply single client — pick one and document it).
5. Wire the `SerialConsole` resource to the live service: `list` now reports real status and current client count. Agents discover the port number via JSON API or MCP, then connect with plain TCP.

**Confirm:**
- [ ] From an agent VM: query MCP/JSON for the console port of a named device, then `nc <usbproxy> <port>` shows live console output from a booted target; keystrokes reach the target.
- [ ] Kill `nc`, reconnect: console immediately live again.
- [ ] Unplug the serial adapter mid-session, replug: session recovers per the chosen semantics without usbproxy restart; `SerialConsole` status reflected the outage.
- [ ] Reboot the usbproxy while a client is connected: client reconnect loop (simple `while true; nc; sleep 1`) regains console without human action.
- [ ] Port mapping survives replug into a different physical USB port (stable identity works).

---

## Phase 7 — USB/IP end-to-end

Guest-side attach, under the real ACL, from a real agent VM.

1. Agent VM template: kernel with `VHCI_HCD` (usbip vhci module), usbip userspace tools, tailscale with ephemeral tagged key, plus MCP client config pointing at the usbproxy.
2. Script the attach flow: query usbproxy (MCP or JSON) for busid by stable name → `usbip attach -r <usbproxy> -b <busid>`.
3. Script detach and a recovery path: `usbip detach`, and `modprobe -r vhci_hcd && modprobe vhci_hcd` for wedged ports.
4. Document (in the agent-facing docs, Phase 12) the rule: attach short-lived, detach when done, never hold across long tasks.

**Confirm:**
- [ ] Agent VM resolves busid via the API and attaches; `lsusb` in the guest shows the device; `Device.attached?` flips true in the API within seconds.
- [ ] Real workload check: talk to the device with its native tool (e.g. `dfu-util -l` sees it, or `fastboot devices` lists it).
- [ ] Small DFU-style flash of the sacrificial device completes successfully over USB/IP. Record duration.
- [ ] Mass-storage throughput test: measure MB/s, compare against the Phase 0 RTT expectation, record the number as documentation for "why flashing goes through the flash service."
- [ ] Second agent VM attempts attach of the same device while attached: fails cleanly.
- [ ] Detach from VM 1, attach from VM 2: works.
- [ ] Drop the network mid-attach (down the tailscale interface on the guest for 60s, restore): guest recovers using the documented recovery path with no usbproxy-side action.

---

## Phase 8 — Flash service (`FlashJob`)

The local-speed flash path, as an Ash resource. This should become the default way agents flash; USB/IP is the fallback.

1. Image upload: a dedicated Phoenix route (streamed to the data partition, size-capped, checksummed) returning an image ref. Uploads are the one thing that stays plain HTTP rather than an MCP tool — document that agents upload via HTTP, then trigger via either interface.
2. `FlashJob` resource actions: `create` (device stable name + image ref → runs `fwup`/`dfu-util`/vendor tool locally under a supervised task), `get`/`list` (status, tool output tail, result). Exposed via JSON API and as MCP tools (`flash_device`, `get_flash_job`).
3. If sd-mux hardware is present: mux-to-usbproxy → write → mux-to-target as one job, with the power step from Phase 9 chained.
4. Every flash job goes to the persistent event log: requester, image checksum, device, result.
5. Concurrency as Ash action logic: one running job per device; overlapping `create` is rejected with a clear error. Flash of a device currently USB/IP-attached: rejected with a clear error.

**Confirm:**
- [ ] Agent uploads a real Nerves firmware image over HTTP, triggers `flash_device` via **MCP**, polls `get_flash_job` to completion; target boots the new firmware (verify over the Phase 6 serial console — this is the whole-pipeline test).
- [ ] Same flow via the JSON API instead of MCP works identically.
- [ ] Duration is dramatically better than the Phase 7 USB/IP flash of the same image. Record both numbers side by side.
- [ ] Corrupt upload (truncate the file) is rejected by checksum before any write is attempted.
- [ ] Two simultaneous jobs for the same device: second is cleanly rejected, not interleaved.
- [ ] Flash of a USB/IP-attached device: rejected with the documented error.
- [ ] Event log entry exists for every attempt, including failures.

---

## Phase 9 — Power control and recovery (`RecoveryAction`)

The recovery ladder: VBUS cycle → usbproxy reboot → (human) wall power.

1. `RecoveryAction` resource with a `create` action, `level: :vbus | :reboot`. Exposed via JSON API and as an MCP tool (`recover`). `:vbus` runs uhubctl (all ports — document that it's all-or-nothing on Pi built-in hubs); `:reboot` calls `Nerves.Runtime.reboot()`.
2. `:vbus` must first quiesce: mark devices as expected-to-vanish so the Phase 4 registry treats the disappearance/reappearance as routine and re-binds.
3. Rate-limit both levels in the action (e.g. min interval between reboots) so a confused agent can't reboot-loop the usbproxy.
4. Log every recovery action to the persistent log with requester identity (source tailnet address at minimum).

**Confirm:**
- [ ] `recover vbus` via MCP from an agent VM: all USB devices drop and return; registry re-binds everything; serial consoles resume; total time recorded.
- [ ] A target wedged in a bad state (simulate: put sacrificial device into a stuck bootloader) recovers to normal boot after VBUS cycle.
- [ ] `recover reboot` from an agent VM: usbproxy returns to fully operational (all Phase 4–8 confirms passing) unattended. Time it and put the number in the agent docs.
- [ ] Ten rapid `recover reboot` calls: rate limiter blocks the loop with a clean error via both MCP and JSON.
- [ ] Post-recovery, the persistent log shows the action and requester despite the reboot.

---

**Confirm:**
- [ ] Clean-room test: spin up a brand-new agent VM from the template, and following only the contract doc plus MCP tool discovery, perform: health check → serial console session → upload + flash via flash service → USB/IP attach for a DFU operation → `recover vbus`. No steps outside the doc needed.
- [ ] Second-Pi test (if hardware available) or same-Pi re-burn: following only the runbook, deploy from nothing to fully operational.

---

## Future design notes (not scheduled)

- **Per-VM device gating (claims/leases).** Today any `tag:project-vm` node
  may operate on any device; exclusivity is only mechanical (usbip
  single-attach, single console client, one flash job per device).
  When gating becomes necessary: add a claim/lease action on `Device`
  (TTL-based, bound to requester identity — source tailnet IP, mappable
  to a node via `tailscale whois`), and flip to a default-unbound
  model: devices are only usbip-bound while claimed, so raw
  `usbip attach` on 3240 is enforced by bind state rather than trust.
  Consoles check the connecting peer against the claim; flash and
  recovery actions check the claimant. Everything already flows through
  Ash actions, so this slots in without restructuring.

## Standing rules for the implementing agent

- Every agent-facing operation is an Ash action, exposed via both AshJsonApi and ash_ai MCP tools. No service reaches around Ash; no interface-specific behavior.
- The MCP endpoint has no auth plug — the tailnet ACL is the auth. Do not add auth; do not weaken the ACL.
- Boot-time reconciliation only. Any logic that depends on clean shutdown is a bug.
- Every operationally significant action (bind, attach observed, flash, recovery) hits the persistent event log.
- When a phase's confirm list can't pass, fix forward within the phase — do not proceed and circle back.
- Destructive tests only against designated sacrificial devices.
