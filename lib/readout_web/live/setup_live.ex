defmodule ReadoutWeb.SetupLive do
  @moduledoc """
  First-run setup: creates the first owner. Only reachable while no account
  exists; afterwards people join through invitations.
  """
  use ReadoutWeb, :live_view

  alias Readout.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} width="26rem">
      <div class="mb-6">
        <h1 class="text-xl font-semibold text-fg">{gettext("Set up Readout")}</h1>
        <p class="mt-1 text-sm text-fg-muted">
          {gettext("Create the owner account. You can invite the rest of the team next.")}
        </p>
      </div>

      <.form
        for={@form}
        id="setup-form"
        phx-change="validate"
        phx-submit="save"
        action={~p"/users/log-in?_action=setup"}
        phx-trigger-action={@trigger_submit}
        class="space-y-4"
      >
        <.input
          field={@form[:name]}
          label={gettext("Your name")}
          autocomplete="name"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Work email")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          hint={gettext("At least 12 characters.")}
          autocomplete="new-password"
          required
        />
        <input type="hidden" name="user[remember_me]" value="true" />
        <.button type="submit" variant="primary" size="lg" class="w-full">
          {gettext("Create owner account")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, push_navigate(socket, to: ~p"/users/log-in")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Set up"))
       |> assign(:trigger_submit, false)
       |> assign_form(Accounts.change_setup())}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = params |> Accounts.change_setup() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset, params)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.bootstrap_owner(params) do
      {:ok, _user} ->
        # Sign in through the session controller with the same credentials.
        {:noreply, socket |> assign(:trigger_submit, true) |> assign_form_params(params)}

      {:error, :already_set_up} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Readout is already set up. Please sign in."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset, params)}
    end
  end

  defp assign_form(socket, changeset, _params \\ %{}) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end

  # Keep the password in the form so phx-trigger-action posts it.
  defp assign_form_params(socket, params) do
    assign(socket, :form, to_form(params, as: "user"))
  end
end
