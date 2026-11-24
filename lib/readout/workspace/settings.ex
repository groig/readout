defmodule Readout.Workspace.Settings do
  @moduledoc "Workspace-wide settings. There is exactly one row (id = 1)."
  use Ecto.Schema
  import Ecto.Changeset

  @notification_locales ~w(en es)

  @primary_key {:id, :integer, autogenerate: false}
  schema "workspace_settings" do
    field :name, :string, default: "Readout"
    field :notification_locale, :string, default: "en"

    timestamps(type: :utc_datetime)
  end

  def notification_locales, do: @notification_locales

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:name, :notification_locale])
    |> validate_required([:name, :notification_locale])
    |> validate_length(:name, max: 60)
    |> validate_inclusion(:notification_locale, @notification_locales)
  end
end
