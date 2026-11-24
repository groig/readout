defmodule Readout.Repo.Migrations.CreateLinksAndVisits do
  use Ecto.Migration

  def change do
    create table(:links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :expires_at, :utc_datetime
      add :password_hash, :string
      add :require_email, :boolean, null: false, default: false
      add :require_verification, :boolean, null: false, default: false
      # Entries are full emails ("ana@client.com") or domains ("client.com").
      add :allow_list, {:array, :string}, null: false, default: []
      add :deny_list, {:array, :string}, null: false, default: []
      add :allow_download, :boolean, null: false, default: false
      add :allow_original_download, :boolean, null: false, default: false
      add :watermark, :boolean, null: false, default: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:links, [:slug])
    create index(:links, [:document_id])

    create table(:visits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :link_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version_id, references(:document_versions, type: :binary_id, on_delete: :nilify_all)
      add :email, :citext
      add :email_verified, :boolean, null: false, default: false
      add :ip, :string
      add :user_agent, :string
      add :started_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create index(:visits, [:document_id, :started_at])
    create index(:visits, [:link_id, :started_at])
    create index(:visits, [:email])

    create table(:link_verifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :link_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :code_hash, :binary, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:link_verifications, [:link_id, :email, :inserted_at])
  end
end
