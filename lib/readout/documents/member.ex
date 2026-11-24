defmodule Readout.Documents.Member do
  @moduledoc """
  A person added to a restricted document: an `:editor` (manages links and
  versions) or a `:viewer` (sees it and its analytics).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "document_members" do
    field :role, Ecto.Enum, values: [:editor, :viewer]

    belongs_to :document, Readout.Documents.Document
    belongs_to :user, Readout.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:document_id, :user_id])
  end
end
