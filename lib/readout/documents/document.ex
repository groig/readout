defmodule Readout.Documents.Document do
  @moduledoc """
  A shared document. Its content lives in versions; `current_version` is the
  newest version that processed successfully, so links keep working while a
  new version is processing (or if it fails).

  Visibility:

    * `:workspace` - every user can see it;
    * `:restricted` - only its owner, the people added to it, and admins.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Readout.Documents.{Member, Version}

  @visibilities [:workspace, :restricted]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :title, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :workspace
    field :deleted_at, :utc_datetime

    belongs_to :owner, Readout.Accounts.User
    belongs_to :current_version, Version
    has_many :versions, Version, preload_order: [desc: :number]
    has_many :members, Member

    # Filled by list queries.
    field :latest_version, :any, virtual: true
    field :link_count, :integer, virtual: true, default: 0
    field :views_7d, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def visibilities, do: @visibilities

  def title_changeset(document, attrs) do
    document
    |> cast(attrs, [:title])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
  end

  def visibility_changeset(document, attrs) do
    document
    |> cast(attrs, [:visibility])
    |> validate_required([:visibility])
  end

  @doc "A title from a file name: no extension, separators to spaces."
  def title_from_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[_]+/, " ")
    |> String.trim()
    |> case do
      "" -> "Untitled"
      title -> String.slice(title, 0, 200)
    end
  end
end
