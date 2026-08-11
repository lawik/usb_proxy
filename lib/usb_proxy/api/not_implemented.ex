defmodule UsbProxy.Api.NotImplemented do
  @moduledoc """
  Change for placeholder actions whose backing service arrives in a
  later phase. The resource modules exist now so the API shape is
  stable; invoking them errors cleanly.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :base,
      message: "not_implemented: this action's backing service arrives in a later phase"
    )
  end
end
