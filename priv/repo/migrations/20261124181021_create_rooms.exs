defmodule Readout.Repo.Migrations.CreateRooms do
  use Ecto.Migration

  def change do
    # A data room: several documents behind one link.
    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :visibility, :string, null: false, default: "workspace"
      add :owner_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:rooms, :visibility_must_be_valid,
             check: "visibility IN ('workspace', 'restricted')"
           )

    create table(:room_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:room_documents, [:room_id, :document_id])
    create index(:room_documents, [:document_id])

    # A link points to a document or to a room.
    alter table(:links) do
      modify :document_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
    end

    create index(:links, [:room_id])

    create constraint(:links, :document_or_room,
             check: "(document_id IS NULL) <> (room_id IS NULL)"
           )
  end
end
