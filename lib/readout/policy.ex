defmodule Readout.Policy do
  @moduledoc """
  The one place where authorization is decided.

  Contexts call `authorize/3` before changing anything and LiveViews call
  `can?/3` to decide what to render. The UI hides what you can't do, and the
  context rejects it anyway.

  ## Roles

    * `:owner` - everything, including workspace settings and managing admins.
    * `:admin` - manages users (invite, change roles up to admin, deactivate
      members and observers) and sees every document.
    * `:member` - uploads documents, creates links, sees analytics of the
      documents they can access.
    * `:observer` - read-only.

  ## Resources

  Workspace-wide actions take `:workspace` as the resource. Actions on a
  person take the target `%User{}`. Role assignment takes the role atom.
  Document actions take a `%Document{}` with `members` preloaded.

  ## Documents

    * `:view_document` - see it and its analytics: admins and owners always;
      anyone for workspace documents; for restricted ones, its owner and the
      people added to it.
    * `:edit_document` - rename, upload versions, manage links: admins and
      owners, the document's owner, and people added as editors.
    * `:manage_document` - change visibility and people, delete: admins and
      owners, and the document's owner.

  Observers never change anything, whatever else applies.

    * `:export_analytics` - download visits as CSV (emails, IPs): whoever
      can view the document, except observers.

  ## Rooms

    * `:create_room` (on `:workspace`) - like uploading: owners, admins, members.
    * `:view_room` - admins and owners always; anyone for workspace rooms; the
      room's owner for restricted ones.
    * `:edit_room` (contents, links) and `:manage_room` (visibility, delete) -
      admins and owners, and the room's owner. Adding a document to a room
      also needs `:edit_document` on it (checked by `Readout.Rooms`), so a
      room never shares what its editor couldn't share directly.
  """

  alias Readout.Accounts.{Scope, User}
  alias Readout.Documents.{Document, Member}
  alias Readout.Rooms.Room

  @type action :: atom()
  @type resource :: term()

  @doc "Returns true when the scope may perform `action` on `resource`."
  @spec can?(Scope.t() | nil, action(), resource()) :: boolean()
  def can?(%Scope{user: %User{deactivated_at: nil} = user}, action, resource) do
    allowed?(user, action, resource)
  end

  def can?(_scope, _action, _resource), do: false

  @doc "Like `can?/3`, but returns `:ok` or `{:error, :unauthorized}` for `with` chains."
  @spec authorize(Scope.t() | nil, action(), resource()) :: :ok | {:error, :unauthorized}
  def authorize(scope, action, resource) do
    if can?(scope, action, resource), do: :ok, else: {:error, :unauthorized}
  end

  ## Workspace

  defp allowed?(%User{role: role}, :view_members, :workspace),
    do: role in [:owner, :admin, :member, :observer]

  defp allowed?(%User{role: role}, action, :workspace)
       when action in [:manage_members, :invite, :view_audit_log],
       do: role in [:owner, :admin]

  defp allowed?(%User{role: :owner}, action, :workspace)
       when action in [:manage_workspace, :transfer_ownership],
       do: true

  defp allowed?(%User{role: role}, :upload_document, :workspace),
    do: role in [:owner, :admin, :member]

  defp allowed?(%User{}, :view_analytics, :workspace), do: true

  ## Assigning roles (inviting, or changing someone's role)

  defp allowed?(%User{role: :owner}, :assign_role, role) when is_atom(role),
    do: role in User.roles()

  defp allowed?(%User{role: :admin}, :assign_role, role) when is_atom(role),
    do: role in [:admin, :member, :observer]

  ## Documents

  defp allowed?(%User{role: role}, :view_document, %Document{}) when role in [:owner, :admin],
    do: true

  defp allowed?(%User{} = user, :view_document, %Document{} = doc) do
    doc.visibility == :workspace or doc.owner_id == user.id or member_role(doc, user) != nil
  end

  defp allowed?(%User{role: :observer}, action, %Document{})
       when action in [:edit_document, :manage_document],
       do: false

  defp allowed?(%User{role: role}, action, %Document{})
       when role in [:owner, :admin] and action in [:edit_document, :manage_document],
       do: true

  defp allowed?(%User{id: id}, action, %Document{owner_id: id})
       when action in [:edit_document, :manage_document],
       do: true

  defp allowed?(%User{} = user, :edit_document, %Document{} = doc),
    do: member_role(doc, user) == :editor

  # Exports hold viewers' emails and IPs: not for observers.
  defp allowed?(%User{role: :observer}, :export_analytics, %Document{}), do: false

  defp allowed?(%User{} = user, :export_analytics, %Document{} = doc),
    do: allowed?(user, :view_document, doc)

  ## Rooms

  defp allowed?(%User{role: role}, :create_room, :workspace),
    do: role in [:owner, :admin, :member]

  defp allowed?(%User{role: role}, :view_room, %Room{}) when role in [:owner, :admin], do: true

  defp allowed?(%User{id: id}, :view_room, %Room{} = room),
    do: room.visibility == :workspace or room.owner_id == id

  defp allowed?(%User{role: :observer}, action, %Room{})
       when action in [:edit_room, :manage_room],
       do: false

  defp allowed?(%User{role: role}, action, %Room{})
       when role in [:owner, :admin] and action in [:edit_room, :manage_room],
       do: true

  defp allowed?(%User{id: id}, action, %Room{owner_id: id})
       when action in [:edit_room, :manage_room],
       do: true

  ## Acting on another person

  # Nobody changes their own role or deactivates themselves; owners step down
  # by transferring ownership, so the workspace is never left without one.
  defp allowed?(%User{id: id}, action, %User{id: id})
       when action in [:change_role, :deactivate, :reactivate],
       do: false

  defp allowed?(%User{role: :owner}, action, %User{})
       when action in [:change_role, :deactivate, :reactivate],
       do: true

  # Admins manage members and observers. Admins and owners are managed by owners.
  defp allowed?(%User{role: :admin}, action, %User{role: target_role})
       when action in [:change_role, :deactivate, :reactivate],
       do: target_role in [:member, :observer]

  defp allowed?(_user, _action, _resource), do: false

  defp member_role(%Document{members: members}, %User{id: user_id}) when is_list(members) do
    Enum.find_value(members, fn
      %Member{user_id: ^user_id, role: role} -> role
      _ -> nil
    end)
  end

  defp member_role(%Document{members: %Ecto.Association.NotLoaded{}}, _user) do
    raise ArgumentError, "Readout.Policy needs document members preloaded"
  end
end
