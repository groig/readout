defmodule Readout.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :role, :string, null: false
      # Only the SHA-256 of the token is stored; the raw token lives in the link.
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_sent_at, :utc_datetime
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token_hash])
    create index(:invitations, [:email])

    # At most one open invitation per email.
    create unique_index(:invitations, [:email],
             where: "accepted_at IS NULL AND revoked_at IS NULL",
             name: :invitations_pending_email_index
           )
  end
end
