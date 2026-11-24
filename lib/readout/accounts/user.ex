defmodule Readout.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member observer)a
  @avatar_colors ~w(slate red orange amber green teal blue indigo violet pink)
  @locales ~w(auto en es)
  @themes ~w(system light dark)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    field :name, :string, default: ""
    field :role, Ecto.Enum, values: @roles, default: :member
    field :avatar_color, :string, default: "slate"
    field :locale, :string, default: "auto"
    field :timezone, :string
    field :theme, :string, default: "system"
    field :notifications_enabled, :boolean, default: true
    field :deactivated_at, :utc_datetime
    field :last_active_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def avatar_colors, do: @avatar_colors
  def locales, do: @locales
  def themes, do: @themes

  @doc "Whether the user can sign in."
  def active?(%__MODULE__{deactivated_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "The name to show in the UI, falling back to the email."
  def display_name(%__MODULE__{name: name, email: email}) do
    if is_binary(name) and String.trim(name) != "", do: name, else: email
  end

  @doc """
  A changeset for creating a team member (first owner or accepted invitation).

  Role and confirmation are set by the caller, never cast from params.
  """
  def create_changeset(user, attrs, role) when role in @roles do
    user
    |> cast(attrs, [:email, :name, :locale, :timezone])
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_email([])
    |> password_changeset(attrs)
    |> validate_inclusion(:locale, @locales)
    |> validate_timezone()
    |> put_change(:role, role)
    |> put_avatar_color()
    |> put_change(:confirmed_at, DateTime.utc_now(:second))
  end

  defp put_avatar_color(changeset) do
    put_change(changeset, :avatar_color, color_for(get_field(changeset, :email) || ""))
  end

  @doc "Picks a stable avatar colour from the email."
  def color_for(email) when is_binary(email) do
    index = :erlang.phash2(String.downcase(email), length(@avatar_colors))
    Enum.at(@avatar_colors, index)
  end

  @doc "A changeset for the profile and preferences a user edits themselves."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :avatar_color, :locale, :timezone, :theme, :notifications_enabled])
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_inclusion(:avatar_color, @avatar_colors)
    |> validate_inclusion(:locale, @locales)
    |> validate_inclusion(:theme, @themes)
    |> validate_timezone()
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, tz ->
      if Readout.TimeZones.valid?(tz), do: [], else: [timezone: "is not a valid time zone"]
    end)
  end

  @doc "Changes the role. Authorization happens in the Accounts context."
  def role_changeset(user, role) when role in @roles, do: change(user, role: role)

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Readout.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Readout.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
