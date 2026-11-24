defmodule Readout.Notifications do
  @moduledoc """
  Rocket.Chat notifications (optional: `ROCKETCHAT_WEBHOOK_URL`, an incoming
  webhook for the team channel).

  When someone opens a document through a link, the channel gets
  "ana@client.com opened «Q3 Report» via the «Client X» link"; when the visit
  ends, a short summary (pages seen, total time, top page). Messages use the
  workspace's notification language.

  Each person chooses per document (`set_subscription/3`); by default you
  follow the documents you own, if your profile allows notifications. A
  document posts only when someone who can see it follows it, and followers
  with a Rocket.Chat username are @mentioned.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.{Scope, User}
  alias Readout.Documents.Document
  alias Readout.Links.Visit
  alias Readout.Notifications.{RocketChatJob, Subscription}
  alias Readout.{Policy, Repo}

  def enabled?, do: webhook_url() not in [nil, ""]
  def webhook_url, do: Application.get_env(:readout, :rocketchat_webhook_url)

  ## Following documents

  @doc "Whether the scope's user gets notifications for this document."
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

  ## Events (called by Readout.Links)

  def visit_started(%Visit{} = visit), do: enqueue(visit, "opened")

  def visit_ended(%Visit{} = visit), do: enqueue(visit, "finished")

  defp enqueue(visit, event) do
    if enabled?() do
      %{"visit_id" => visit.id, "event" => event} |> RocketChatJob.new() |> Oban.insert()
    end

    :ok
  end
end
