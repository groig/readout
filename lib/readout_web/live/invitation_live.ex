defmodule ReadoutWeb.InvitationLive do
  @moduledoc """
  Accepting an invitation: the invitee picks a name and password. The email
  and role come from the invitation and can't be changed here.
  """
  use ReadoutWeb, :live_view

  alias Readout.Accounts
  alias Readout.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} width="26rem">
      <%= if @invitation do %>
        <div class="mb-6">
          <h1 class="text-xl font-semibold text-fg">
            {gettext("Join %{workspace} on Readout", workspace: @workspace.name)}
          </h1>
          <p class="mt-1 text-sm text-fg-muted">
            <%= if @invitation.invited_by do %>
              {gettext("%{name} invited you as %{role}.",
                name: User.display_name(@invitation.invited_by),
                role: Layouts.role_label(@invitation.role)
              )}
            <% else %>
              {gettext("You've been invited as %{role}.", role: Layouts.role_label(@invitation.role))}
            <% end %>
          </p>
        </div>

        <.form
          for={@form}
          id="invitation-form"
          phx-change="validate"
          phx-submit="accept"
          action={~p"/users/log-in?_action=joined"}
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <.input
            name="user[email]"
            id="invitation-email"
            type="email"
            value={@invitation.email}
            label={gettext("Email")}
            readonly
          />
          <.input
            field={@form[:name]}
            label={gettext("Your name")}
            autocomplete="name"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Choose a password")}
            hint={gettext("At least 12 characters.")}
            autocomplete="new-password"
            required
          />
          <input type="hidden" name="user[remember_me]" value="true" />
          <.button type="submit" variant="primary" size="lg" class="w-full">
            {gettext("Join the workspace")}
          </.button>
        </.form>
      <% else %>
        <div id="invitation-invalid" class="text-center">
          <div class="mx-auto mb-4 flex size-11 items-center justify-center rounded-xl border border-border bg-inset text-fg-subtle">
            <.icon name="hero-envelope-open" class="size-5" />
          </div>
          <h1 class="text-lg font-semibold text-fg">{gettext("This invitation can't be used")}</h1>
          <p class="mt-1 text-sm text-fg-muted">
            {gettext(
              "It may have expired, been revoked or already been used. Ask whoever invited you for a new link."
            )}
          </p>
          <.button navigate={~p"/users/log-in"} class="mt-6">{gettext("Go to sign in")}</.button>
        </div>
      <% end %>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    invitation = Accounts.get_invitation_by_token(token)

    socket =
      socket
      |> assign(:page_title, gettext("Join"))
      |> assign(:token, token)
      |> assign(:invitation, invitation)
      |> assign(:workspace, Readout.Workspace.get_settings())
      |> assign(:trigger_submit, false)

    socket =
      if invitation,
        do: assign(socket, :form, to_form(Accounts.change_acceptance(invitation), as: "user")),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.invitation
      |> Accounts.change_acceptance(Map.put(params, "email", socket.assigns.invitation.email))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "user"))}
  end

  def handle_event("accept", %{"user" => params}, socket) do
    case Accounts.accept_invitation(socket.assigns.token, params) do
      {:ok, _user} ->
        params = Map.put(params, "email", socket.assigns.invitation.email)

        {:noreply,
         socket
         |> assign(:trigger_submit, true)
         |> assign(:form, to_form(params, as: "user"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "user"))}

      {:error, _} ->
        {:noreply, assign(socket, :invitation, nil)}
    end
  end
end
