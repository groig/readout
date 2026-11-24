defmodule ReadoutWeb.Shell do
  @moduledoc """
  `on_mount` hook for every LiveView: handles events that come from the shared
  shell (theme toggle, command palette) whatever page is open.
  """
  import Phoenix.LiveView

  alias Readout.Accounts
  alias Readout.Accounts.Scope

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :shell_events, :handle_event, &handle_event/3)}
  end

  # The theme is applied on the client first; this only persists it.
  defp handle_event("shell:set_theme", %{"theme" => theme}, socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %{}} = scope when theme in ["system", "light", "dark"] ->
        {:ok, user} = Accounts.update_theme(scope, theme)
        {:halt, Phoenix.Component.assign(socket, :current_scope, %{scope | user: user})}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
