defmodule Readout.Links.Verification do
  @moduledoc """
  A 6-digit email verification code for a link. Only its hash is stored. It
  expires after 10 minutes and allows a few attempts.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "link_verifications" do
    field :email, :string
    field :code_hash, :binary, redact: true
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    belongs_to :link, Readout.Links.Link

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @validity_minutes 10
  @max_attempts 5

  def validity_minutes, do: @validity_minutes
  def max_attempts, do: @max_attempts

  def generate_code do
    <<n::unsigned-32>> = :crypto.strong_rand_bytes(4)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # Codes are short, so the hash is keyed with the link id: a leaked table
  # can't be brute-forced across links with one precomputed table.
  def hash(link_id, code), do: :crypto.mac(:hmac, :sha256, link_id, code)
end
