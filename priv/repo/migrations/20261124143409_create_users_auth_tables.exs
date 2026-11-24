defmodule Readout.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :name, :string, null: false, default: ""
      add :role, :string, null: false, default: "member"
      add :avatar_color, :string, null: false, default: "slate"
      add :locale, :string, null: false, default: "auto"
      add :timezone, :string
      add :theme, :string, null: false, default: "system"
      add :notifications_enabled, :boolean, null: false, default: true
      add :deactivated_at, :utc_datetime
      add :last_active_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:role])

    create constraint(:users, :role_must_be_valid,
             check: "role IN ('owner', 'admin', 'member', 'observer')"
           )

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
