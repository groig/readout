defmodule ReadoutWeb.SettingsLive.Members do
  @moduledoc """
  Settings → Members: the team, pending invitations, roles and deactivation.

  Everyone can see the list; owners and admins act on it (as `Readout.Policy`
  allows). Changes from anyone show up live.
  """
  use ReadoutWeb, :live_view

  on_mount {ReadoutWeb.UserAuth, {:can, :view_members}}

  alias Readout.Accounts
  alias Readout.Accounts.{Invitation, User}
  alias Readout.Policy
  alias ReadoutWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <:crumb navigate={~p"/settings/profile"}>{gettext("Settings")}</:crumb>
      <:crumb>{gettext("Members")}</:crumb>

      <Layouts.settings_nav current_scope={@current_scope} active={:members} />

      <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold text-fg">{gettext("Members")}</h2>
          <p class="text-sm text-fg-muted tabular-nums">
            {ngettext("%{count} person", "%{count} people", @counts.total)}
            <span :if={@counts.deactivated > 0} class="text-fg-subtle">
              · {ngettext("%{count} deactivated", "%{count} deactivated", @counts.deactivated)}
            </span>
          </p>
        </div>
        <.button
          :if={@can_invite}
          id="invite-button"
          variant="primary"
          icon="hero-user-plus-mini"
          phx-click="open_invite"
        >
          {gettext("Invite people")}
        </.button>
      </div>

      <.form
        for={@filter_form}
        id="member-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-3 flex flex-wrap items-center gap-2"
      >
        <.search_input
          id="member-search"
          name="query"
          value={@filters["query"]}
          placeholder={gettext("Search by name or email")}
          shortcut
          phx-debounce="150"
          class="w-full sm:w-72"
        />
        <.input
          type="select"
          name="role"
          id="member-role-filter"
          value={@filters["role"]}
          prompt={gettext("All roles")}
          options={for role <- User.roles(), do: {Layouts.role_label(role), role}}
          wrapper_class="w-40"
        />
        <.input
          type="segmented"
          name="status"
          id="member-status-filter"
          value={@filters["status"]}
          options={[
            {gettext("All"), ""},
            {gettext("Active"), "active"},
            {gettext("Deactivated"), "deactivated"}
          ]}
        />
      </.form>

      <.table id="members" rows={@streams.members} row_class={&member_row_class/1}>
        <:col :let={{_id, user}} label={gettext("Name")}>
          <div class="flex min-w-0 items-center gap-3">
            <.avatar name={User.display_name(user)} color={user.avatar_color} size="md" />
            <div class="min-w-0">
              <p class="flex items-center gap-1.5 truncate font-medium text-fg">
                {User.display_name(user)}
                <.badge :if={user.id == @current_scope.user.id} tone="accent">
                  {gettext("You")}
                </.badge>
              </p>
              <p class="truncate text-xs text-fg-muted">{user.email}</p>
            </div>
          </div>
        </:col>
        <:col :let={{_id, user}} label={gettext("Role")}>
          <span class="text-sm text-fg">{Layouts.role_label(user.role)}</span>
        </:col>
        <:col :let={{_id, user}} label={gettext("Last active")} class="text-fg-muted">
          <.relative_time at={user.last_active_at} scope={@current_scope} />
        </:col>
        <:col :let={{_id, user}} label={gettext("Status")}>
          <.badge :if={User.active?(user)} tone="success" dot>{gettext("Active")}</.badge>
          <.badge :if={!User.active?(user)}>{gettext("Deactivated")}</.badge>
        </:col>
        <:action :let={{id, user}}>
          <.dropdown :if={actions?(@current_scope, user)} id={"#{id}-menu"}>
            <:trigger>
              <.icon_button
                icon="hero-ellipsis-horizontal-mini"
                label={gettext("Actions for %{name}", name: User.display_name(user))}
                tooltip={false}
              />
            </:trigger>
            <:item :if={can?(@current_scope, :change_role, user) and User.active?(user)} label>
              {gettext("Change role")}
            </:item>
            <:item
              :for={role <- assignable_roles(@current_scope, user)}
              :if={can?(@current_scope, :change_role, user) and User.active?(user)}
              icon="hero-arrows-right-left-mini"
              phx-click="change_role"
              phx-value-id={user.id}
              phx-value-role={role}
            >
              {gettext("Make %{role}", role: Layouts.role_label(role))}
            </:item>
            <:item :if={can?(@current_scope, :change_role, user) and User.active?(user)} separator />
            <:item
              :if={User.active?(user) and can?(@current_scope, :deactivate, user)}
              icon="hero-no-symbol-mini"
              danger
              phx-click="confirm_deactivate"
              phx-value-id={user.id}
            >
              {gettext("Deactivate")}
            </:item>
            <:item
              :if={!User.active?(user) and can?(@current_scope, :reactivate, user)}
              icon="hero-arrow-uturn-left-mini"
              phx-click="reactivate"
              phx-value-id={user.id}
            >
              {gettext("Reactivate")}
            </:item>
          </.dropdown>
        </:action>
        <:empty>
          <.empty_state icon="hero-users" title={gettext("No one matches")}>
            {gettext("Try another search or clear the filters.")}
          </.empty_state>
        </:empty>
      </.table>

      <section :if={@can_invite and @invitation_count > 0} class="mt-10">
        <h2 class="mb-1 text-lg font-semibold text-fg">{gettext("Pending invitations")}</h2>
        <p class="mb-4 text-sm text-fg-muted">
          {gettext("Links expire after %{days} days. A new link replaces the old one.",
            days: Invitation.validity_in_days()
          )}
        </p>
        <.table id="invitations" rows={@streams.invitations}>
          <:col :let={{_id, invitation}} label={gettext("Email")}>
            <span class="font-medium text-fg">{invitation.email}</span>
          </:col>
          <:col :let={{_id, invitation}} label={gettext("Role")}>
            {Layouts.role_label(invitation.role)}
          </:col>
          <:col :let={{_id, invitation}} label={gettext("Invited by")} class="text-fg-muted">
            {invitation.invited_by && User.display_name(invitation.invited_by)}
          </:col>
          <:col :let={{_id, invitation}} label={gettext("Expires")}>
            <%= if Invitation.status(invitation) == :expired do %>
              <.badge tone="warning">{gettext("Expired")}</.badge>
            <% else %>
              <span class="text-fg-muted tabular-nums">
                {Format.date(invitation.expires_at, @current_scope)}
              </span>
            <% end %>
          </:col>
          <:action :let={{id, invitation}}>
            <.button
              id={"#{id}-resend"}
              size="sm"
              variant="ghost"
              icon="hero-link-mini"
              phx-click="resend"
              phx-value-id={invitation.id}
            >
              {gettext("New link")}
            </.button>
            <.icon_button
              id={"#{id}-revoke"}
              icon="hero-x-mark-mini"
              label={gettext("Revoke invitation")}
              phx-click="revoke"
              phx-value-id={invitation.id}
            />
          </:action>
        </.table>
      </section>

      <.dialog
        :if={@invite_form}
        id="invite-dialog"
        show
        title={gettext("Invite people")}
        description={
          gettext("They'll get a link to join. It expires in %{days} days.",
            days: Invitation.validity_in_days()
          )
        }
        on_close={JS.push("close_invite")}
      >
        <.form
          for={@invite_form}
          id="invite-form"
          phx-change="validate_invite"
          phx-submit="invite"
          class="space-y-4"
        >
          <.input
            field={@invite_form[:email]}
            type="email"
            label={gettext("Email")}
            placeholder="ana@example.com"
            autocomplete="off"
            required
            autofocus
          />
          <fieldset>
            <legend class="mb-2 text-sm font-medium text-fg">{gettext("Role")}</legend>
            <div class="space-y-1.5">
              <label
                :for={role <- @invite_roles}
                class="flex cursor-pointer items-start gap-3 rounded-lg border border-border p-3 transition-colors hover:bg-hover/50 has-checked:border-accent has-checked:bg-accent-soft/50"
              >
                <input
                  type="radio"
                  name={@invite_form[:role].name}
                  value={role}
                  checked={to_string(@invite_form[:role].value) == to_string(role)}
                  class="mt-0.5 size-4 accent-accent"
                />
                <span>
                  <span class="block text-sm font-medium text-fg">{Layouts.role_label(role)}</span>
                  <span class="block text-xs text-fg-muted">{Layouts.role_description(role)}</span>
                </span>
              </label>
            </div>
          </fieldset>
        </.form>
        <:footer>
          <.button phx-click={close_dialog("invite-dialog")}>{gettext("Cancel")}</.button>
          <.button type="submit" form="invite-form" variant="primary" id="send-invite">
            {gettext("Create invitation")}
          </.button>
        </:footer>
      </.dialog>

      <.dialog
        :if={@invite_link}
        id="invite-link-dialog"
        show
        title={gettext("Invitation ready")}
        description={
          gettext("Share this link with %{email}. Anyone with it can join as %{role}.",
            email: @invite_link.email,
            role: Layouts.role_label(@invite_link.role)
          )
        }
        on_close={JS.push("close_link")}
      >
        <div class="flex items-center gap-2">
          <input
            id="invite-link-url"
            type="text"
            readonly
            value={@invite_link.url}
            class="h-8 min-w-0 flex-1 rounded-md border border-border-strong bg-inset px-2.5 font-mono text-xs text-fg"
            phx-mounted={JS.focus()}
          />
          <.button
            id="copy-invite-link"
            variant="primary"
            icon="hero-clipboard-document-mini"
            phx-click={copy(@invite_link.url, gettext("Invitation link copied"))}
          >
            {gettext("Copy")}
          </.button>
        </div>
        <p class="mt-3 text-xs text-fg-subtle">
          {gettext("Expires on %{date}.", date: Format.date(@invite_link.expires_at, @current_scope))}
          <span :if={@mail_enabled}>{gettext("We've also emailed it.")}</span>
        </p>
        <:footer>
          <.button phx-click={close_dialog("invite-link-dialog")}>{gettext("Done")}</.button>
        </:footer>
      </.dialog>

      <.dialog
        :if={@confirm_deactivate}
        id="deactivate-dialog"
        show
        title={gettext("Deactivate %{name}?", name: User.display_name(@confirm_deactivate))}
        on_close={JS.push("cancel_deactivate")}
      >
        <p class="text-sm text-fg-muted">
          {gettext(
            "They'll be signed out everywhere right away and won't be able to sign in. Their name stays in the history, and you can reactivate them later."
          )}
        </p>
        <:footer>
          <.button phx-click={close_dialog("deactivate-dialog")}>{gettext("Cancel")}</.button>
          <.button
            id="confirm-deactivate"
            variant="danger"
            phx-click="deactivate"
            phx-value-id={@confirm_deactivate.id}
          >
            {gettext("Deactivate")}
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Accounts.subscribe_members(scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Members"))
     |> assign(:can_invite, Policy.can?(scope, :invite, :workspace))
     |> assign(:invite_roles, Enum.filter(User.roles(), &Policy.can?(scope, :assign_role, &1)))
     |> assign(invite_form: nil, invite_link: nil, confirm_deactivate: nil)
     |> assign(:mail_enabled, Readout.Mailer.enabled?())
     |> load_invitations()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, ["query", "role", "status"])
    filters = Map.merge(%{"query" => "", "role" => "", "status" => ""}, filters)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters))
      |> load_members()

    socket =
      if params["invite"] && socket.assigns.can_invite,
        do: open_invite(socket),
        else: socket

    {:noreply, socket}
  end

  ## Filters

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(["query", "role", "status"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/settings/members?#{filters}", replace: true)}
  end

  ## Invitations

  def handle_event("open_invite", _params, socket) do
    {:noreply, open_invite(socket)}
  end

  def handle_event("close_invite", _params, socket) do
    {:noreply, assign(socket, :invite_form, nil)}
  end

  def handle_event("close_link", _params, socket) do
    {:noreply, assign(socket, :invite_link, nil)}
  end

  def handle_event("validate_invite", %{"invitation" => params}, socket) do
    changeset = params |> Accounts.change_invitation() |> Map.put(:action, :validate)
    {:noreply, assign(socket, :invite_form, to_form(changeset))}
  end

  def handle_event("invite", %{"invitation" => params}, socket) do
    case Accounts.create_invitation(
           socket.assigns.current_scope,
           params,
           &url(~p"/invitations/#{&1}")
         ) do
      {:ok, {invitation, token}} ->
        {:noreply,
         socket
         |> assign(:invite_form, nil)
         |> assign(:invite_link, link_info(invitation, token))
         |> load_invitations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :invite_form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("resend", %{"id" => id}, socket) do
    invitation = Accounts.get_pending_invitation!(id)

    case Accounts.resend_invitation(
           socket.assigns.current_scope,
           invitation,
           &url(~p"/invitations/#{&1}")
         ) do
      {:ok, {invitation, token}} ->
        {:noreply,
         socket
         |> assign(:invite_link, link_info(invitation, token))
         |> load_invitations()}

      {:error, _} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    invitation = Accounts.get_pending_invitation!(id)

    case Accounts.revoke_invitation(socket.assigns.current_scope, invitation) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation for %{email} revoked.", email: invitation.email))
         |> load_invitations()}

      {:error, _} ->
        {:noreply, unauthorized(socket)}
    end
  end

  ## Members

  def handle_event("change_role", %{"id" => id, "role" => role}, socket) do
    target = Accounts.get_user!(id)

    case Accounts.change_role(socket.assigns.current_scope, target, role) do
      {:ok, {user, tokens}} ->
        # Their open pages reconnect with the new role.
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is now %{role}.",
             name: User.display_name(user),
             role: Layouts.role_label(user.role)
           )
         )
         |> load_members()}

      {:error, :last_owner} ->
        {:noreply, put_flash(socket, :error, gettext("The workspace needs at least one owner."))}

      {:error, _} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("confirm_deactivate", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_deactivate, Accounts.get_user!(id))}
  end

  def handle_event("cancel_deactivate", _params, socket) do
    {:noreply, assign(socket, :confirm_deactivate, nil)}
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    target = Accounts.get_user!(id)

    case Accounts.deactivate_user(socket.assigns.current_scope, target) do
      {:ok, {user, tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> assign(:confirm_deactivate, nil)
         |> put_flash(:info, gettext("%{name} was deactivated.", name: User.display_name(user)))
         |> load_members()}

      {:error, _} ->
        {:noreply, socket |> assign(:confirm_deactivate, nil) |> unauthorized()}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    target = Accounts.get_user!(id)

    case Accounts.reactivate_user(socket.assigns.current_scope, target) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} was reactivated.", name: User.display_name(user)))
         |> load_members()}

      {:error, _} ->
        {:noreply, unauthorized(socket)}
    end
  end

  ## Live updates

  @impl true
  def handle_info({event, _}, socket) when event in [:member_updated, :invitation_updated] do
    {:noreply, socket |> load_members() |> load_invitations()}
  end

  ## Helpers

  defp open_invite(socket) do
    assign(socket, :invite_form, to_form(Accounts.change_invitation()))
  end

  defp link_info(invitation, token) do
    %{
      email: invitation.email,
      role: invitation.role,
      expires_at: invitation.expires_at,
      url: url(~p"/invitations/#{token}")
    }
  end

  defp load_members(socket) do
    scope = socket.assigns.current_scope
    filters = socket.assigns.filters

    members =
      Accounts.list_members(scope,
        query: filters["query"],
        role: filters["role"],
        status: filters["status"]
      )

    socket
    |> assign(:counts, Accounts.count_members())
    |> stream(:members, members, reset: true)
  end

  defp load_invitations(socket) do
    invitations = Accounts.list_pending_invitations(socket.assigns.current_scope)

    socket
    |> assign(:invitation_count, length(invitations))
    |> stream(:invitations, invitations, reset: true)
  end

  defp unauthorized(socket) do
    put_flash(socket, :error, gettext("You can't do that."))
  end

  defp can?(scope, action, user), do: Policy.can?(scope, action, user)

  defp actions?(scope, user) do
    Enum.any?([:change_role, :deactivate, :reactivate], &Policy.can?(scope, &1, user))
  end

  defp assignable_roles(scope, user) do
    Enum.filter(User.roles(), &(&1 != user.role and Policy.can?(scope, :assign_role, &1)))
  end

  defp member_row_class({_id, user}), do: if(User.active?(user), do: nil, else: "opacity-60")
end
