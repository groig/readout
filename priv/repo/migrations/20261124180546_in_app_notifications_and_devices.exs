defmodule Readout.Repo.Migrations.InAppNotificationsAndDevices do
  use Ecto.Migration

  def change do
    # Notifications now live in Readout (no chat integration).
    alter table(:users) do
      remove :chat_username, :string
    end

    alter table(:workspace_settings) do
      remove :notification_locale, :string, null: false, default: "en"
    end

    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all)
      add :visit_id, references(:visits, type: :binary_id, on_delete: :nilify_all)
      # A snapshot of what the notification says (who, which link, totals).
      add :data, :map, null: false, default: %{}
      add :read_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:notifications, [:user_id, :inserted_at])

    create index(:notifications, [:user_id],
             where: "read_at IS NULL",
             name: :notifications_unread_index
           )

    # Anonymous viewers are told apart by a random id in a per-link cookie.
    alter table(:visits) do
      add :device_id, :string
    end
  end
end
