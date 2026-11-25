defmodule Readout.Repo.Migrations.AddLinkAccessRevision do
  use Ecto.Migration

  # Bumped whenever a link's access rules change. Gate grants, session grants
  # and page tokens carry the revision they were issued under, so a change
  # (even within the same second) invalidates them all.
  def change do
    alter table(:links) do
      add :access_revision, :integer, null: false, default: 1
    end
  end
end
