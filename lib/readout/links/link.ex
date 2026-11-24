defmodule Readout.Links.Link do
  @moduledoc """
  A share link for a document: a random, unguessable slug plus the rules for
  who gets in (expiry, password, email gate with allow and deny lists, email
  verification) and what they can do (download, watermark).

  Links always show the document's current version, so uploading a new
  version keeps every link working.

  A link points to a document or to a room (`Readout.Rooms.Room`): a room link
  opens an index of the room's documents behind the same gate.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "links" do
    field :name, :string
    field :slug, :string
    field :enabled, :boolean, default: true
    field :expires_at, :utc_datetime
    field :password_hash, :string, redact: true
    field :require_email, :boolean, default: false
    field :require_verification, :boolean, default: false
    field :allow_list, {:array, :string}, default: []
    field :deny_list, {:array, :string}, default: []
    field :allow_download, :boolean, default: false
    field :allow_original_download, :boolean, default: false
    field :watermark, :boolean, default: false

    # Form-only fields.
    field :password, :string, virtual: true, redact: true
    field :remove_password, :boolean, virtual: true, default: false
    field :allow_list_text, :string, virtual: true
    field :deny_list_text, :string, virtual: true

    # Filled by queries.
    field :visit_count, :integer, virtual: true, default: 0

    belongs_to :document, Readout.Documents.Document
    belongs_to :room, Readout.Rooms.Room
    belongs_to :created_by, Readout.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @fields ~w(name enabled expires_at password remove_password require_email require_verification
             allow_list_text deny_list_text allow_download allow_original_download watermark)a

  @doc """
  The link settings form. Options: `:mail_enabled` (email verification needs
  SMTP).
  """
  def changeset(link, attrs, opts \\ []) do
    link
    |> cast(attrs, @fields, empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_expiry()
    |> put_lists()
    |> put_password()
    |> validate_verification(Keyword.get(opts, :mail_enabled, false))
    |> normalize_dependencies()
  end

  defp validate_expiry(changeset) do
    validate_change(changeset, :expires_at, fn :expires_at, at ->
      if at && DateTime.before?(at, DateTime.utc_now()),
        do: [expires_at: "must be in the future"],
        else: []
    end)
  end

  defp put_lists(changeset) do
    Enum.reduce([allow_list_text: :allow_list, deny_list_text: :deny_list], changeset, fn
      {text_field, field}, cs ->
        case fetch_change(cs, text_field) do
          {:ok, text} ->
            entries = parse_list(text)

            case Enum.reject(entries, &valid_entry?/1) do
              [] ->
                put_change(cs, field, entries)

              bad ->
                add_error(cs, text_field, "has invalid entries: %{entries}",
                  entries: Enum.join(bad, ", ")
                )
            end

          :error ->
            cs
        end
    end)
  end

  @doc "Splits a textarea into normalised entries (one per line or comma)."
  def parse_list(nil), do: []

  def parse_list(text) do
    text
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.map(&(&1 |> String.downcase() |> String.trim_leading("@")))
    |> Enum.uniq()
  end

  defp valid_entry?(entry) do
    Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, entry) or
      Regex.match?(~r/^([a-z0-9-]+\.)+[a-z]{2,}$/, entry)
  end

  defp put_password(changeset) do
    cond do
      get_change(changeset, :remove_password) ->
        put_change(changeset, :password_hash, nil)

      (password = get_change(changeset, :password)) not in [nil, ""] ->
        changeset
        |> validate_length(:password, min: 4, max: 72)
        |> then(fn cs ->
          if cs.valid?,
            do: put_change(cs, :password_hash, Bcrypt.hash_pwd_salt(password)),
            else: cs
        end)

      true ->
        changeset
    end
  end

  defp validate_verification(changeset, mail_enabled?) do
    if get_field(changeset, :require_verification) and not mail_enabled? and
         get_change(changeset, :require_verification) do
      add_error(changeset, :require_verification, "needs email (SMTP) to be configured")
    else
      changeset
    end
  end

  # Verification implies an email gate; original downloads imply downloads.
  defp normalize_dependencies(changeset) do
    changeset
    |> then(
      &if(get_field(&1, :require_verification),
        do: put_change(&1, :require_email, true),
        else: &1
      )
    )
    |> then(
      &if(get_field(&1, :allow_download),
        do: &1,
        else: put_change(&1, :allow_original_download, false)
      )
    )
    # Originals can't carry a watermark.
    |> then(
      &if(get_field(&1, :watermark),
        do: put_change(&1, :allow_original_download, false),
        else: &1
      )
    )
  end

  @doc "A new random, unguessable slug (128 bits)."
  def generate_slug, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  def password?(%__MODULE__{password_hash: hash}), do: is_binary(hash)

  def room?(%__MODULE__{room_id: id}), do: not is_nil(id)

  @doc "What the link shares: the document's title or the room's name."
  def title(%__MODULE__{room: %{name: name}}) when is_binary(name), do: name
  def title(%__MODULE__{document: %{title: title}}) when is_binary(title), do: title
  def title(_), do: ""

  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password),
      do: Bcrypt.verify_pass(password, hash)

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  def expired?(%__MODULE__{expires_at: nil}), do: false
  def expired?(%__MODULE__{expires_at: at}), do: DateTime.before?(at, DateTime.utc_now())

  @doc """
  Whether an email may pass the gate: the deny list wins; a non-empty allow
  list must match (by full address or domain).
  """
  def allows_email?(%__MODULE__{allow_list: allow, deny_list: deny}, email) do
    email = String.downcase(String.trim(email))
    domain = email |> String.split("@") |> List.last()
    matches? = fn list -> email in list or domain in list end

    cond do
      matches?.(deny) -> false
      allow == [] -> true
      true -> matches?.(allow)
    end
  end
end
