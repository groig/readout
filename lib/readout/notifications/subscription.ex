defmodule Readout.Notifications.Subscription do
  @moduledoc "A person's notification choice for one document (overrides the default)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "document_subscriptions" do
    field :enabled, :boolean
    belongs_to :user, Readout.Accounts.User
    belongs_to :document, Readout.Documents.Document

    timestamps(type: :utc_datetime)
  end
end
