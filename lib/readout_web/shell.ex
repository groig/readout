defmodule ReadoutWeb.Shell do
  @moduledoc """
  `on_mount` hook for every LiveView: handles events that come from the shared
  shell (theme toggle, command palette) whatever page is open.
  """
  import Phoenix.LiveView

  alias Readout.Accounts
  alias Readout.Accounts.Scope

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns[:current_scope]

    # Signed-in pages hear about documents (the upload tray and the documents
    # pages update live). See handle_info/2 below.
    if connected?(socket) and match?(%Scope{user: %{}}, scope) do
      Readout.Documents.subscribe(scope)
    end

    {:cont,
     socket
     |> attach_hook(:shell_events, :handle_event, &handle_event/3)
     |> attach_hook(:shell_info, :handle_info, &handle_info/2)}
  end

  # Document events go to the upload tray, then to the page itself if it
  # implements `handle_document_event/3` (returning the socket). Pages that
  # don't care never see them.
  defp handle_info({event, id} = message, socket)
       when event in [:document_created, :document_updated, :document_deleted] and is_binary(id) do
    if Readout.Policy.can?(socket.assigns[:current_scope], :upload_document, :workspace) do
      Phoenix.LiveView.send_update(ReadoutWeb.UploadComponent,
        id: "uploader",
        document_event: message
      )
    end

    view = socket.view

    socket =
      if function_exported?(view, :handle_document_event, 3),
        do: view.handle_document_event(event, id, socket),
        else: socket

    {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

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
