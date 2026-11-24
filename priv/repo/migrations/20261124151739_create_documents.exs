defmodule Readout.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :visibility, :string, null: false, default: "workspace"
      add :owner_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:owner_id])
    create index(:documents, [:updated_at], where: "deleted_at IS NULL")

    create constraint(:documents, :visibility_must_be_valid,
             check: "visibility IN ('workspace', 'restricted')"
           )

    create table(:document_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :format, :string, null: false
      add :original_filename, :string, null: false
      add :byte_size, :bigint, null: false
      add :checksum, :string, null: false
      add :original_key, :string, null: false
      add :pdf_key, :string
      add :page_count, :integer
      add :metadata, :map, null: false, default: %{}
      add :processed_at, :utc_datetime
      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_versions, [:document_id, :number])

    create constraint(:document_versions, :status_must_be_valid,
             check: "status IN ('pending', 'processing', 'ready', 'failed')"
           )

    # The version people see: the newest one that processed successfully.
    alter table(:documents) do
      add :current_version_id,
          references(:document_versions, type: :binary_id, on_delete: :nilify_all)
    end

    create table(:document_pages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :version_id, references(:document_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      # PDF page size in points, so viewers can reserve space before images load.
      add :width, :float, null: false
      add :height, :float, null: false
      add :text, :text, null: false, default: ""
    end

    create unique_index(:document_pages, [:version_id, :number])

    # Full-text search over page text ('simple' config: works for English and Spanish).
    execute(
      """
      ALTER TABLE document_pages ADD COLUMN search tsvector
        GENERATED ALWAYS AS (to_tsvector('simple', coalesce(text, ''))) STORED
      """,
      "ALTER TABLE document_pages DROP COLUMN search"
    )

    execute(
      "CREATE INDEX document_pages_search_index ON document_pages USING GIN (search)",
      "DROP INDEX document_pages_search_index"
    )

    create table(:document_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_members, [:document_id, :user_id])
    create index(:document_members, [:user_id])

    create constraint(:document_members, :role_must_be_valid,
             check: "role IN ('editor', 'viewer')"
           )
  end
end
