defmodule Readout.Repo.Migrations.AddTracking do
  use Ecto.Migration

  def change do
    alter table(:visits) do
      # Location from the IP (GeoIP), names by locale.
      add :country_code, :string
      add :country, :map, null: false, default: %{}
      add :city, :map, null: false, default: %{}
      # Running totals, measured on the server.
      add :duration_ms, :bigint, null: false, default: 0
      add :pages_viewed, :integer, null: false, default: 0
      add :page_count, :integer
      add :last_page, :integer
    end

    create table(:page_views, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :visit_id, references(:visits, type: :binary_id, on_delete: :delete_all), null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version_id, references(:document_versions, type: :binary_id, on_delete: :nilify_all)
      add :page, :integer, null: false
      add :duration_ms, :bigint, null: false, default: 0
      add :views, :integer, null: false, default: 1
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:page_views, [:visit_id, :page])
    create index(:page_views, [:document_id, :version_id, :page])
  end
end
