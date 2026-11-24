defmodule Readout.Links.Visit do
  @moduledoc """
  One reading session through a link: it starts when the viewer passes the
  gate. Records the version shown, the email (if gated, and whether it was
  verified), IP, user agent and timestamps. Page-level time is added in the
  tracking milestone.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "visits" do
    field :email, :string
    field :email_verified, :boolean, default: false
    field :ip, :string
    field :user_agent, :string
    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :link, Readout.Links.Link
    belongs_to :document, Readout.Documents.Document
    belongs_to :version, Readout.Documents.Version
  end
end
