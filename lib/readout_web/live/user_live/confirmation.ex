defmodule ReadoutWeb.UserLive.Confirmation do
  @moduledoc "The landing page of an emailed sign-in link."
  use ReadoutWeb, :live_view

  alias Readout.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="mb-6 text-center">
        <.avatar
          name={Readout.Accounts.User.display_name(@user)}
          color={@user.avatar_color}
          size="xl"
          class="mx-auto mb-4"
        />
        <h1 class="text-xl font-semibold text-fg">
          {gettext("Sign in as %{name}", name: Readout.Accounts.User.display_name(@user))}
        </h1>
        <p class="mt-1 text-sm text-fg-muted">{@user.email}</p>
      </div>

      <.form
        for={@form}
        id="login_form"
        phx-submit="submit"
        phx-mounted={JS.focus_first()}
        action={~p"/users/log-in"}
        phx-trigger-action={@trigger_submit}
        class="space-y-2"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <%= if @current_scope do %>
          <.button type="submit" variant="primary" size="lg" class="w-full">
            {gettext("Sign in")}
          </.button>
        <% else %>
          <.button
            type="submit"
            name={@form[:remember_me].name}
            value="true"
            variant="primary"
            size="lg"
            class="w-full"
          >
            {gettext("Keep me signed in on this device")}
          </.button>
          <.button type="submit" variant="ghost" size="lg" class="w-full">
            {gettext("Sign in only this time")}
          </.button>
        <% end %>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok,
       assign(socket,
         page_title: gettext("Sign in"),
         user: user,
         form: form,
         trigger_submit: false
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("That sign-in link is invalid or has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
