defmodule Readout.Workspace.Settings do
  @moduledoc "Workspace-wide settings. There is exactly one row (id = 1)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "workspace_settings" do
    field :name, :string, default: "Readout"

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
  end
end
