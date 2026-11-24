defmodule Readout.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      # Denormalised so the log stays readable whatever happens to the actor.
      add :actor_name, :string
      add :subject_type, :string
      add :subject_id, :binary_id
      add :subject_label, :string
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_events, [:inserted_at])
    create index(:audit_events, [:action, :inserted_at])
    create index(:audit_events, [:actor_id, :inserted_at])
  end
end
