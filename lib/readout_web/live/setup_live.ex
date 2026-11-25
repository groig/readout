defmodule ReadoutWeb.SetupLive do
  @moduledoc """
  First-run setup: creates the first owner. Only reachable while no account
  exists; afterwards people join through invitations.

  On a fresh database whoever reaches this page first becomes the owner, so
  in production it must be protected (`config :readout, :setup`):

    * with `SETUP_TOKEN` set, the form asks for it as a setup code (compared
      in constant time, rate-limited per client);
    * otherwise, with `ADMIN_NETWORKS` set, only those networks reach it
      (`ReadoutWeb.AdminNetwork`);
    * with neither, setup is locked and says how to unlock it.

  Development and tests leave it open (`require_authorization: false`).
  """
  use ReadoutWeb, :live_view
  on_mount ReadoutWeb.AdminNetwork

  alias Readout.{Accounts, RateLimit}
  alias ReadoutWeb.ClientIP

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

      <div
        :if={@guard == :locked}
        id="setup-locked"
        class="rounded-lg border border-border bg-inset p-4 text-sm text-fg-muted"
      >
        <p class="font-medium text-fg">{gettext("Setup is locked")}</p>
        <p class="mt-1">
          {gettext(
            "To create the owner account, set SETUP_TOKEN (or ADMIN_NETWORKS) on the server and restart Readout."
          )}
        </p>
      </div>

      <.form
        :if={@guard != :locked}
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
        <.input
          :if={@guard == :code}
          id="setup-code"
          name="setup_code"
          value={@setup_code}
          type="password"
          label={gettext("Setup code")}
          hint={gettext("The SETUP_TOKEN configured on the server.")}
          autocomplete="off"
          errors={@code_errors}
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
       |> assign(guard: guard(), setup_code: "", code_errors: [])
       |> assign(:client_key, connected?(socket) && ClientIP.from_socket(socket))
       |> assign_form(Accounts.change_setup())}
    end
  end

  # How setup is protected right now (see the moduledoc).
  defp guard do
    config = Application.get_env(:readout, :setup, [])

    cond do
      is_binary(config[:token]) -> :code
      not Keyword.get(config, :require_authorization, false) -> :open
      Application.get_env(:readout, :admin_networks) -> :open
      true -> :locked
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params} = all, socket) do
    changeset = params |> Accounts.change_setup() |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:setup_code, all["setup_code"] || "")
     |> assign_form(changeset, params)}
  end

  def handle_event("save", %{"user" => params} = all, socket) do
    case check_code(socket, all["setup_code"]) do
      :ok ->
        create_owner(socket, params)

      {:error, message} ->
        {:noreply, assign(socket, setup_code: "", code_errors: [message])}
    end
  end

  defp check_code(%{assigns: %{guard: :open}}, _code), do: :ok
  defp check_code(%{assigns: %{guard: :locked}}, _code), do: {:error, gettext("Setup is locked")}

  defp check_code(socket, code) do
    expected = Application.get_env(:readout, :setup)[:token]

    with :ok <- RateLimit.hit({:setup, socket.assigns.client_key}, 10, :timer.minutes(15)),
         true <- is_binary(code) and Plug.Crypto.secure_compare(String.trim(code), expected) do
      :ok
    else
      {:error, :rate_limited} ->
        {:error, gettext("Too many attempts. Please wait a few minutes and try again.")}

      false ->
        {:error, gettext("That setup code isn't right.")}
    end
  end

  defp create_owner(socket, params) do
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
