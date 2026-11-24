defmodule Readout.Accounts.Invitation do
  @moduledoc """
  An invitation to join the workspace with a given role.

  The raw token only ever exists in the invitation link; the database keeps its
  SHA-256 hash, so a database read cannot be turned into a working link.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Readout.Accounts.User

  @validity_in_days 7
  @rand_size 32

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: User.roles()
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_sent_at, :utc_datetime

    belongs_to :invited_by, User
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def validity_in_days, do: @validity_in_days

  @doc "Changeset for the invite form (email and role only)."
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> validate_required([:email, :role])
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email,
      name: :invitations_pending_email_index,
      message: "already has a pending invitation"
    )
  end

  @doc "Generates a fresh token, returning `{raw_token, token_hash}`."
  def generate_token do
    raw = :crypto.strong_rand_bytes(@rand_size)
    {Base.url_encode64(raw, padding: false), hash(raw)}
  end

  @doc "Hashes an encoded token as received in a link. Returns nil when malformed."
  def hash_encoded(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> hash(raw)
      :error -> nil
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  def new_expiry, do: DateTime.utc_now(:second) |> DateTime.add(@validity_in_days, :day)

  @doc "pending, accepted, revoked or expired"
  def status(%__MODULE__{accepted_at: %DateTime{}}), do: :accepted
  def status(%__MODULE__{revoked_at: %DateTime{}}), do: :revoked

  def status(%__MODULE__{expires_at: expires_at}) do
    if DateTime.after?(expires_at, DateTime.utc_now()), do: :pending, else: :expired
  end
end
