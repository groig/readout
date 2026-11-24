defmodule Readout.Notifications do
  @moduledoc """
  In-app notifications: the bell in the sidebar.

  When someone opens a document through a link, its followers get
  "ana@client.com opened «Q3 Report» via «Client X»"; when the visit ends, a
  short summary (pages seen, total time, top page). Uploaders also hear when
  their file is ready or couldn't be processed. New notifications arrive live
  (PubSub topic per person).

  Following is per person and document (the bell on the document page): by
  default you follow the documents you own, if your profile allows
  notifications. Only people who can see a document are notified about it.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.{Scope, User}
  alias Readout.Documents.{Document, Version}
  alias Readout.Links.Visit
  alias Readout.Notifications.{DeliverJob, Notification, Subscription}
  alias Readout.{Policy, Repo}

  @page_size 30

  ## Following documents

  @doc "Whether the scope's user is notified about this document."
  def subscribed?(%Scope{user: user}, %Document{} = doc) do
    case Repo.get_by(Subscription, user_id: user.id, document_id: doc.id) do
      %Subscription{enabled: enabled} -> enabled
      nil -> default?(user, doc)
    end
  end

  defp default?(%User{} = user, %Document{owner_id: owner_id}),
    do: user.id == owner_id and user.notifications_enabled

  def set_subscription(%Scope{user: user} = scope, %Document{} = doc, enabled)
      when is_boolean(enabled) do
    with :ok <- Policy.authorize(scope, :view_document, doc) do
      %Subscription{user_id: user.id, document_id: doc.id, enabled: enabled}
      |> Repo.insert(
        on_conflict: {:replace, [:enabled, :updated_at]},
        conflict_target: [:user_id, :document_id]
      )
    end
  end

  @doc "Active people who can see the document and follow it."
  def followers(%Document{} = doc) do
    doc = Repo.preload(doc, :members)
    overrides = Map.new(Repo.all_by(Subscription, document_id: doc.id), &{&1.user_id, &1.enabled})

    from(u in User, where: is_nil(u.deactivated_at))
    |> Repo.all()
    |> Enum.filter(fn user ->
      Map.get(overrides, user.id, default?(user, doc)) and
        Policy.can?(Scope.for_user(user), :view_document, doc)
    end)
  end

  ## Events

  @doc "Someone passed a link's gate (called by Readout.Links)."
  def visit_started(%Visit{} = visit), do: enqueue(visit, "visit_opened")

  @doc "A visit ended (called by Readout.Links)."
  def visit_ended(%Visit{} = visit), do: enqueue(visit, "visit_finished")

  defp enqueue(visit, kind) do
    %{"visit_id" => visit.id, "kind" => kind} |> DeliverJob.new() |> Oban.insert()
    :ok
  end

  @doc "Tells the uploader their version is ready or failed (called by Readout.Documents)."
  def version_processed(%Version{uploaded_by_id: nil}), do: :ok

  def version_processed(%Version{} = version) do
    doc = Repo.get(Document, version.document_id) |> Repo.preload(:members)
    user = Repo.get(User, version.uploaded_by_id)

    if doc && user && User.active?(user) && Policy.can?(Scope.for_user(user), :view_document, doc) do
      kind = if version.status == :ready, do: "version_ready", else: "version_failed"

      create(user, doc, nil, kind, %{
        "title" => doc.title,
        "version" => version.number,
        "error" => version.error
      })
    end

    :ok
  end

  @doc false
  def create(%User{} = user, %Document{} = doc, visit_id, kind, data) do
    notification =
      Repo.insert!(%Notification{
        user_id: user.id,
        document_id: doc.id,
        visit_id: visit_id,
        kind: kind,
        data: data,
        inserted_at: DateTime.utc_now()
      })

    Phoenix.PubSub.broadcast(Readout.PubSub, topic(user.id), {:notification, notification.id})
    notification
  end

  ## Reading

  def subscribe(%Scope{user: %User{id: id}}),
    do: Phoenix.PubSub.subscribe(Readout.PubSub, topic(id))

  defp topic(user_id), do: "notifications:" <> user_id

  @doc "The scope's notifications, newest first."
  def list(%Scope{user: user}, opts \\ []) do
    from(n in Notification,
      where: n.user_id == ^user.id,
      order_by: [desc: n.inserted_at],
      limit: ^Keyword.get(opts, :limit, @page_size)
    )
    |> Repo.all()
  end

  def get(%Scope{user: user}, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         do: Repo.get_by(Notification, id: id, user_id: user.id),
         else: (_ -> nil)
  end

  def unread_count(%Scope{user: user}) do
    Repo.aggregate(
      from(n in Notification, where: n.user_id == ^user.id and is_nil(n.read_at)),
      :count
    )
  end

  def mark_read(%Scope{user: user}, id) do
    from(n in Notification, where: n.id == ^id and n.user_id == ^user.id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    :ok
  end

  def mark_all_read(%Scope{user: user}) do
    from(n in Notification, where: n.user_id == ^user.id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    :ok
  end
end
