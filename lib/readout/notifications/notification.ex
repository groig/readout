defmodule Readout.Notifications.Notification do
  @moduledoc """
  One in-app notification for one person. `kind` is `"visit_opened"`,
  `"visit_finished"`, `"version_ready"` or `"version_failed"`; `data` is a
  snapshot (viewer, link, title, totals) so the text stays right even if
  things are renamed later.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notifications" do
    field :kind, :string
    field :data, :map, default: %{}
    field :read_at, :utc_datetime
    field :inserted_at, :utc_datetime_usec

    belongs_to :user, Readout.Accounts.User
    belongs_to :document, Readout.Documents.Document
    belongs_to :visit, Readout.Links.Visit
  end
end
