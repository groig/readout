defmodule Readout.Repo.Migrations.AddLinkLimits do
  use Ecto.Migration

  def change do
    alter table(:links) do
      # The first N devices may open the link (1 = a one-time link); null = anyone.
      add :max_viewers, :integer
      # Notify only on a viewer's first visit through this link.
      add :notify_first_only, :boolean, null: false, default: false
    end

    create constraint(:links, :max_viewers_positive,
             check: "max_viewers IS NULL OR max_viewers > 0"
           )

    create index(:visits, [:link_id, :device_id])
  end
end
