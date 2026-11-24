defmodule Readout.Rooms.Room do
  @moduledoc """
  A data room: an ordered set of documents shared behind one link. Each
  document read through a room is still its own visit, so per-document
  analytics keep working; the room adds a roll-up.

  Visibility (inside the team) follows documents: `:workspace` (everyone) or
  `:restricted` (its owner and admins).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rooms" do
    field :name, :string
    field :description, :string, default: ""
    field :visibility, Ecto.Enum, values: [:workspace, :restricted], default: :workspace
    field :deleted_at, :utc_datetime

    belongs_to :owner, Readout.Accounts.User
    has_many :room_documents, Readout.Rooms.RoomDocument, preload_order: [asc: :position]

    # Filled by queries: the documents in order (only live ones).
    field :documents, {:array, :any}, virtual: true, default: []
    field :link_count, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :description, :visibility])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> validate_length(:description, max: 2000)
  end
end
