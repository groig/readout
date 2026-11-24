defmodule Readout.Audit.Event do
  @moduledoc """
  One entry in the audit log: who did what, to what, and when.

  The actor's name and the subject's label are copied in at write time so
  entries stay readable after renames or deletions.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :action, :string
    field :actor_name, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :subject_label, :string
    field :metadata, :map, default: %{}
    belongs_to :actor, Readout.Accounts.User

    field :inserted_at, :utc_datetime_usec
  end
end
