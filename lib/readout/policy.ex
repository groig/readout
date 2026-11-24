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
  """

  alias Readout.Accounts.{Scope, User}

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
end
