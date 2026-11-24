defmodule Readout.Analytics.PageView do
  @moduledoc """
  Time spent on one page during one visit, measured on the server. `views`
  counts how many times the reader came to the page.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "page_views" do
    field :page, :integer
    field :duration_ms, :integer, default: 0
    field :views, :integer, default: 1
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :visit, Readout.Links.Visit
    belongs_to :document, Readout.Documents.Document
    belongs_to :version, Readout.Documents.Version
  end
end
