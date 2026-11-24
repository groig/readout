defmodule ReadoutWeb.UserLive.Settings do
  @moduledoc "Email and password. Requires a recent sign-in (sudo mode)."
  use ReadoutWeb, :live_view

  on_mount {ReadoutWeb.UserAuth, :require_sudo_mode}

  alias Readout.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <:crumb navigate={~p"/settings/profile"}>{gettext("Settings")}</:crumb>
      <:crumb>{gettext("Email and password")}</:crumb>

      <Layouts.settings_nav current_scope={@current_scope} active={:account} />

      <div class="space-y-8">
        <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
          <div>
            <h2 class="text-md font-semibold text-fg">{gettext("Email")}</h2>
            <p class="mt-1 text-sm text-fg-muted">
              {gettext("We'll send a confirmation link to the new address.")}
            </p>
          </div>
          <.card>
            <.form
              for={@email_form}
              id="email_form"
              phx-submit="update_email"
              phx-change="validate_email"
              class="space-y-4"
            >
              <.input
                field={@email_form[:email]}
                type="email"
                label={gettext("Email")}
                autocomplete="username"
                spellcheck="false"
                required
              />
              <div class="flex justify-end">
                <.button type="submit" variant="primary">{gettext("Change email")}</.button>
              </div>
            </.form>
          </.card>
        </section>

        <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
          <div>
            <h2 class="text-md font-semibold text-fg">{gettext("Password")}</h2>
            <p class="mt-1 text-sm text-fg-muted">
              {gettext("Changing it signs you out everywhere else.")}
            </p>
          </div>
          <.card>
            <.form
              for={@password_form}
              id="password_form"
              action={~p"/users/update-password"}
              method="post"
              phx-change="validate_password"
              phx-submit="update_password"
              phx-trigger-action={@trigger_submit}
              class="space-y-4"
            >
              <input
                name={@password_form[:email].name}
                type="hidden"
                id="hidden_user_email"
                spellcheck="false"
                value={@current_email}
              />
              <.input
                field={@password_form[:password]}
                type="password"
                label={gettext("New password")}
                hint={gettext("At least 12 characters.")}
                autocomplete="new-password"
                spellcheck="false"
                required
              />
              <.input
                field={@password_form[:password_confirmation]}
                type="password"
                label={gettext("Confirm new password")}
                autocomplete="new-password"
                spellcheck="false"
              />
              <div class="flex justify-end">
                <.button type="submit" variant="primary">{gettext("Save password")}</.button>
              </div>
            </.form>
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed."))

        {:error, _} ->
          put_flash(socket, :error, gettext("That email change link is invalid or has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/settings/account")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, gettext("Email and password"))
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/settings/account/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
