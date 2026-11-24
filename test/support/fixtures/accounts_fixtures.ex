defmodule Readout.AccountsFixtures do
  @moduledoc """
  Test helpers for creating accounts, invitations and scopes.
  """

  import Ecto.Query

  alias Readout.Accounts
  alias Readout.Accounts.{Scope, User}
  alias Readout.Repo

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      name: "Test User",
      password: valid_user_password()
    })
  end

  @doc """
  Creates an active, confirmed user. Pass `role:` (default `:member`).
  """
  def user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {role, attrs} = Map.pop(attrs, :role, :member)

    %User{}
    |> User.create_changeset(valid_user_attributes(attrs), role)
    |> Repo.insert!()
  end

  def owner_fixture(attrs \\ %{}), do: user_fixture(Map.put(Map.new(attrs), :role, :owner))
  def admin_fixture(attrs \\ %{}), do: user_fixture(Map.put(Map.new(attrs), :role, :admin))
  def observer_fixture(attrs \\ %{}), do: user_fixture(Map.put(Map.new(attrs), :role, :observer))

  def deactivated_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    user
    |> Ecto.Changeset.change(deactivated_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  @doc "Creates an invitation as the given owner/admin scope; returns {invitation, token}."
  def invitation_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{"email" => unique_user_email(), "role" => "member"})
    {:ok, {invitation, token}} = Accounts.create_invitation(scope, attrs)
    {invitation, token}
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Readout.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Readout.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Readout.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
