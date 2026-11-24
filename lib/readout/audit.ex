defmodule Readout.Audit do
  @moduledoc """
  The audit log: invitations, role changes, deactivations, link changes and
  downloads. Each entry records who, what and when.

  Writing is open to every context (it is a side effect of an authorized
  action); reading is limited to owners and admins.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.{Scope, User}
  alias Readout.Audit.Event
  alias Readout.{Policy, Repo}

  @topic "audit"

  # Known actions. Keep in sync with the labels in ReadoutWeb.AuditLabels.
  @actions ~w(
    workspace.created workspace.updated workspace.ownership_transferred
    invitation.created invitation.resent invitation.revoked invitation.accepted
    user.role_changed user.deactivated user.reactivated
    document.deleted document.downloaded
  )

  def actions, do: @actions

  @doc """
  Records an event. `actor` is a scope, a user or nil (the system).
  `subject` is any struct with an id, or nil.
  """
  def log(actor, action, subject \\ nil, metadata \\ %{}) when is_binary(action) do
    actor_user = actor_user(actor)

    attrs = %{
      action: action,
      actor_id: actor_user && actor_user.id,
      actor_name: actor_user && User.display_name(actor_user),
      subject_type: subject_type(subject),
      subject_id: subject && Map.get(subject, :id),
      subject_label: subject_label(subject),
      metadata: stringify(metadata),
      # Set here, not by the database: now() is fixed for a whole transaction.
      inserted_at: DateTime.utc_now()
    }

    event = Repo.insert!(struct(Event, attrs))
    Phoenix.PubSub.broadcast(Readout.PubSub, @topic, {:audit_event, event})
    event
  end

  defp actor_user(%Scope{user: user}), do: user
  defp actor_user(%User{} = user), do: user
  defp actor_user(nil), do: nil

  defp subject_type(nil), do: nil

  defp subject_type(%module{}),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp subject_type(_map), do: nil

  defp subject_label(nil), do: nil
  defp subject_label(%User{} = user), do: user.email
  defp subject_label(%{email: email}) when is_binary(email), do: email
  defp subject_label(%{name: name}) when is_binary(name), do: name
  defp subject_label(%{title: title}) when is_binary(title), do: title
  defp subject_label(_), do: nil

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp stringify_value(v), do: v

  @doc "Subscribes the caller to new audit events (owners and admins only)."
  def subscribe(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :view_audit_log, :workspace) do
      Phoenix.PubSub.subscribe(Readout.PubSub, @topic)
    end
  end

  @doc """
  Lists events, newest first.

  ## Options

    * `:action` - an exact action, or an action prefix ending in `.` (e.g. `"user."`)
    * `:actor_id` - only events by that user
    * `:query` - matches the actor name or the subject label
    * `:before` - an `inserted_at` cursor for pagination
    * `:limit` - defaults to 50
  """
  def list_events(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :view_audit_log, :workspace) do
      limit = Keyword.get(opts, :limit, 50)

      events =
        Event
        |> filter(opts)
        |> order_by(desc: :inserted_at, desc: :id)
        |> limit(^limit)
        |> Repo.all()

      {:ok, events}
    end
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:action, action}, q when action in [nil, ""] ->
        q

      {:action, action}, q ->
        if String.ends_with?(action, "."),
          do: where(q, [e], like(e.action, ^"#{action}%")),
          else: where(q, [e], e.action == ^action)

      {:actor_id, id}, q when id in [nil, ""] ->
        q

      {:actor_id, id}, q ->
        where(q, [e], e.actor_id == ^id)

      {:query, text}, q when text in [nil, ""] ->
        q

      {:query, text}, q ->
        pattern = "%" <> escape_like(text) <> "%"
        where(q, [e], ilike(e.actor_name, ^pattern) or ilike(e.subject_label, ^pattern))

      {:before, nil}, q ->
        q

      {:before, %DateTime{} = ts}, q ->
        where(q, [e], e.inserted_at < ^ts)

      _, q ->
        q
    end)
  end

  @doc false
  def escape_like(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
end
