defmodule ReadoutWeb.UserLive.Login do
  use ReadoutWeb, :live_view

  alias Readout.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="mb-6">
        <h1 class="text-xl font-semibold text-fg">
          <%= if @current_scope do %>
            {gettext("Confirm it's you")}
          <% else %>
            {gettext("Sign in")}
          <% end %>
        </h1>
        <p class="mt-1 text-sm text-fg-muted">
          <%= if @current_scope do %>
            {gettext("Sign in again to change sensitive account settings.")}
          <% else %>
            {gettext("Welcome back to Readout.")}
          <% end %>
        </p>
      </div>

      <%= if @mode == :password do %>
        <.form
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={!@current_scope && JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            spellcheck="false"
            required
            phx-mounted={@current_scope && JS.focus()}
          />
          <.input
            :if={!@current_scope}
            field={@form[:remember_me]}
            type="checkbox"
            label={gettext("Keep me signed in on this device")}
            checked
          />
          <.button type="submit" variant="primary" size="lg" class="w-full">
            {gettext("Sign in")}
          </.button>
        </.form>
      <% else %>
        <.form
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="space-y-4"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button type="submit" variant="primary" size="lg" class="w-full">
            {gettext("Email me a sign-in link")}
          </.button>
        </.form>
      <% end %>

      <div :if={@mail_enabled} class="mt-5 border-t border-border pt-4 text-center">
        <button
          :if={@mode == :password}
          id="use-magic-link"
          type="button"
          phx-click="mode"
          phx-value-mode="magic"
          class="cursor-pointer text-sm text-fg-muted transition-colors hover:text-fg"
        >
          {gettext("Forgot your password? Get a sign-in link by email")}
        </button>
        <button
          :if={@mode == :magic}
          id="use-password"
          type="button"
          phx-click="mode"
          phx-value-mode="password"
          class="cursor-pointer text-sm text-fg-muted transition-colors hover:text-fg"
        >
          {gettext("Sign in with your password instead")}
        </button>
      </div>

      <:footer :if={local_mail_adapter?()}>
        {gettext("Development: sent emails appear in the")}
        <.link href="/dev/mailbox" class="font-medium text-fg underline-offset-2 hover:underline">
          {gettext("local mailbox")}
        </.link>
      </:footer>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      email =
        Phoenix.Flash.get(socket.assigns.flash, :email) ||
          get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

      form = to_form(%{"email" => email}, as: "user")

      {:ok,
       assign(socket,
         page_title: gettext("Sign in"),
         form: form,
         trigger_submit: false,
         mode: :password,
         mail_enabled: Readout.Mailer.enabled?()
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/setup")}
    end
  end

  @impl true
  def handle_event("mode", %{"mode" => mode}, socket) do
    mode = if mode == "magic" and socket.assigns.mail_enabled, do: :magic, else: :password
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    info =
      gettext("If your email is in our system, you will receive a sign-in link shortly.")

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:readout, Readout.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
