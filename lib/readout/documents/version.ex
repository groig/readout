defmodule Readout.Documents.Version do
  @moduledoc """
  One uploaded file of a document. The original is always kept; Office files
  are also converted to PDF. Pages are rendered and their text extracted by
  `Readout.Documents.ProcessVersion`.

  Status: `:pending` (queued), `:processing`, `:ready` or `:failed`.
  """
  use Ecto.Schema

  @formats [:pdf, :docx, :pptx, :odt, :odp]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "document_versions" do
    field :number, :integer
    field :status, Ecto.Enum, values: [:pending, :processing, :ready, :failed], default: :pending
    field :error, :string
    field :format, Ecto.Enum, values: @formats
    field :original_filename, :string
    field :byte_size, :integer
    field :checksum, :string
    field :original_key, :string
    field :pdf_key, :string
    field :page_count, :integer
    field :metadata, :map, default: %{}
    field :processed_at, :utc_datetime

    belongs_to :document, Readout.Documents.Document
    belongs_to :uploaded_by, Readout.Accounts.User
    has_many :pages, Readout.Documents.Page, preload_order: [asc: :number]

    timestamps(type: :utc_datetime)
  end

  def formats, do: @formats

  @doc "Whether the original is an Office file (converted to PDF)."
  def office?(%__MODULE__{format: format}), do: format != :pdf

  @doc "Storage prefix for everything belonging to this version."
  def prefix(%__MODULE__{document_id: doc_id, number: n}), do: "documents/#{doc_id}/v#{n}"

  @doc "Storage key of a rendered page image."
  def page_key(%__MODULE__{} = version, page_number, width),
    do: "#{prefix(version)}/pages/#{page_number}-#{width}.webp"
end
