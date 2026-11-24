defmodule ReadoutWeb.SettingsLive.Workspace do
  @moduledoc "Settings → Workspace (owners): name and ownership transfer."
  use ReadoutWeb, :live_view

  on_mount {ReadoutWeb.UserAuth, {:can, :manage_workspace}}

  alias Readout.{Accounts, Workspace}
  alias Readout.Accounts.User
  alias ReadoutWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <:crumb navigate={~p"/settings/profile"}>{gettext("Settings")}</:crumb>
      <:crumb>{gettext("Workspace")}</:crumb>

      <Layouts.settings_nav current_scope={@current_scope} active={:workspace} />

      <div class="space-y-8">
        <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
          <div>
            <h2 class="text-md font-semibold text-fg">{gettext("General")}</h2>
            <p class="mt-1 text-sm text-fg-muted">
              {gettext("Shown in the sidebar, invitations and emails.")}
            </p>
          </div>
          <.card>
            <.form
              for={@form}
              id="workspace-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-5"
            >
              <.input field={@form[:name]} label={gettext("Workspace name")} />
              <div class="flex justify-end">
                <.button type="submit" variant="primary" id="save-workspace">
                  {gettext("Save")}
                </.button>
              </div>
            </.form>
          </.card>
        </section>

        <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
          <div>
            <h2 class="text-md font-semibold text-fg">{gettext("Ownership")}</h2>
            <p class="mt-1 text-sm text-fg-muted">
              {gettext("There is always at least one owner.")}
            </p>
          </div>
          <.card>
            <.form
              for={@transfer_form}
              id="transfer-form"
              phx-submit="confirm_transfer"
              class="space-y-4"
            >
              <.input
                field={@transfer_form[:user_id]}
                type="select"
                label={gettext("Transfer ownership to")}
                hint={gettext("They become an owner and you become an admin.")}
                prompt={gettext("Choose a person")}
                options={for u <- @candidates, do: {"#{User.display_name(u)} · #{u.email}", u.id}}
              />
              <div class="flex justify-end">
                <.button type="submit" variant="danger" id="start-transfer">
                  {gettext("Transfer ownership")}
                </.button>
              </div>
            </.form>
          </.card>
        </section>
      </div>

      <.dialog
        :if={@transfer_to}
        id="transfer-dialog"
        show
        title={gettext("Transfer ownership?")}
        on_close={JS.push("cancel_transfer")}
      >
        <p class="text-sm text-fg-muted">
          {gettext(
            "%{name} becomes an owner. You'll become an admin and lose access to workspace settings.",
            name: User.display_name(@transfer_to)
          )}
        </p>
        <:footer>
          <.button phx-click={close_dialog("transfer-dialog")}>{gettext("Cancel")}</.button>
          <.button id="confirm-transfer" variant="danger" phx-click="transfer">
            {gettext("Transfer ownership")}
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    settings = Workspace.get_settings()

    candidates =
      scope
      |> Accounts.list_members(status: "active")
      |> Enum.reject(&(&1.id == scope.user.id))

    {:ok,
     socket
     |> assign(:page_title, gettext("Workspace"))
     |> assign(:settings, settings)
     |> assign(:candidates, candidates)
     |> assign(:transfer_to, nil)
     |> assign(:transfer_form, to_form(%{"user_id" => ""}, as: "transfer"))
     |> assign(:form, to_form(Workspace.change_settings(settings)))}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    changeset =
      socket.assigns.settings |> Workspace.change_settings(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Workspace.update_settings(socket.assigns.current_scope, params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:form, to_form(Workspace.change_settings(settings)))
         |> put_flash(:info, gettext("Workspace saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  def handle_event("confirm_transfer", %{"transfer" => %{"user_id" => id}}, socket) do
    case Enum.find(socket.assigns.candidates, &(&1.id == id)) do
      nil -> {:noreply, put_flash(socket, :error, gettext("Choose a person first."))}
      user -> {:noreply, assign(socket, :transfer_to, user)}
    end
  end

  def handle_event("cancel_transfer", _params, socket) do
    {:noreply, assign(socket, :transfer_to, nil)}
  end

  def handle_event("transfer", _params, socket) do
    target = Accounts.get_user!(socket.assigns.transfer_to.id)

    case Accounts.transfer_ownership(socket.assigns.current_scope, target) do
      {:ok, {new_owner, tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is now an owner.", name: User.display_name(new_owner))
         )
         |> push_navigate(to: ~p"/settings/members")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:transfer_to, nil)
         |> put_flash(:error, gettext("Ownership couldn't be transferred."))}
    end
  end
end
