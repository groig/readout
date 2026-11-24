defmodule Readout.Repo.Migrations.CreateWorkspaceSettings do
  use Ecto.Migration

  def change do
    # A single-row table: one workspace for the whole team.
    create table(:workspace_settings, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :name, :string, null: false, default: "Readout"
      add :notification_locale, :string, null: false, default: "en"

      timestamps(type: :utc_datetime)
    end

    create constraint(:workspace_settings, :single_row, check: "id = 1")
  end
end
