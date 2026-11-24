defmodule Readout.Repo.Migrations.AddNotifications do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Optional Rocket.Chat username, @mentioned in notifications.
      add :chat_username, :string
    end

    # Per user and document: notifications on or off. No row means the
    # default: on for documents you own (if your profile allows it), off
    # for the rest.
    create table(:document_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enabled, :boolean, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_subscriptions, [:user_id, :document_id])
    create index(:document_subscriptions, [:document_id])
  end
end
