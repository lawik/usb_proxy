defmodule UsbProxyWeb.ErrorJSON do
  @moduledoc """
  Renders errors for the JSON API. Invoked by Phoenix when an error
  escapes the router (404, 500, ...).
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
