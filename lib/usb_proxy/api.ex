defmodule UsbProxy.Api do
  @moduledoc """
  The Ash domain for everything agent-facing.

  Standing rule: every agent-facing operation is an action on a
  resource in this domain, exposed BOTH via AshJsonApi (/api) and as
  ash_ai MCP tools (/mcp). Internal code calls the same actions.
  No service reaches around Ash.

  Resources arrive in Phase 5: Device, SerialConsole, FlashJob,
  RecoveryAction.
  """

  use Ash.Domain

  resources do
  end
end
