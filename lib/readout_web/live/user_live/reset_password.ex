defmodule ReadoutWeb.UserLive.ResetPassword do
  @moduledoc """
  Password reset: ask for a link (`:new`), then choose a new password from the
  emailed link (`:edit`). Setting it signs the person out everywhere.
  """
  use ReadoutWeb, :live_view

  alias Readout.Accounts
  alias ReadoutWeb.UserAuth

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="mb-6">
        <h1 class="text-xl font-semibold text-fg">{gettext("Reset your password")}</h1>
        <p class="mt-1 text-sm text-fg-muted">
          {gettext("We'll email you a link to choose a new one.")}
        </p>
      </div>
      <.form for={@form} id="reset-request-form" phx-submit="request" class="space-y-4">
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          required
          phx-mounted={JS.focus()}
        />
        <.button type="submit" variant="primary" size="lg" class="w-full">
          {gettext("Send reset link")}
        </.button>
      </.form>
      <:footer>
        <.link navigate={~p"/users/log-in"} class="hover:text-fg">{gettext("Back to sign in")}</.link>
      </:footer>
    </Layouts.auth>
    """
  end

  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="mb-6">
        <h1 class="text-xl font-semibold text-fg">{gettext("Choose a new password")}</h1>
        <p class="mt-1 text-sm text-fg-muted">{@user.email}</p>
      </div>
      <.form
        for={@form}
        id="reset-password-form"
        phx-change="validate"
        phx-submit="reset"
        class="space-y-4"
      >
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("New password")}
          hint={gettext("At least 12 characters.")}
          autocomplete="new-password"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={gettext("Confirm new password")}
          autocomplete="new-password"
          required
        />
        <.button type="submit" variant="primary" size="lg" class="w-full">
          {gettext("Set new password")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      {:ok,
       socket
       |> assign(page_title: gettext("Choose a new password"), user: user, token: token)
       |> assign(:form, to_form(Accounts.change_user_password(user, %{}, hash_password: false)))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("That reset link is invalid or has expired."))
       |> push_navigate(to: ~p"/users/reset-password")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Reset your password"))
     |> assign(:form, to_form(%{"email" => ""}, as: "user"))}
  end

  @impl true
  def handle_event("request", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(String.trim(email)) do
      Accounts.deliver_reset_password_instructions(user, &url(~p"/users/reset-password/#{&1}"))
    end

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("If your email is in our system, you'll get a reset link shortly.")
     )
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("reset", %{"user" => params}, socket) do
    # Re-check the token: it may have been used in another tab.
    with %{} = user <- Accounts.get_user_by_reset_password_token(socket.assigns.token),
         {:ok, {_user, tokens}} <- Accounts.reset_user_password(user, params) do
      UserAuth.disconnect_sessions(tokens)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Password changed. Sign in with your new password."))
       |> push_navigate(to: ~p"/users/log-in")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That reset link is invalid or has expired."))
         |> push_navigate(to: ~p"/users/reset-password")}
    end
  end
end
