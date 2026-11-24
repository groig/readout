defmodule Readout.Rooms.RoomDocument do
  @moduledoc "A document's place in a room."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_documents" do
    field :position, :integer
    belongs_to :room, Readout.Rooms.Room
    belongs_to :document, Readout.Documents.Document

    timestamps(type: :utc_datetime)
  end
end
