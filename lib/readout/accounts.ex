defmodule Readout.Accounts do
  @moduledoc """
  Team accounts: sign-in, invitations, members, roles and profiles.

  There is no open registration. The first owner is created on the first-run
  setup screen, and everyone else joins through an invitation.

  Functions that act on behalf of someone take a `%Scope{}` first and check it
  with `Readout.Policy`. Functions that end or change someone's sessions return
  the affected session tokens so the web layer can disconnect their LiveViews.
  """

  import Ecto.Query, warn: false

  alias Readout.{Audit, Policy, Repo}
  alias Readout.Accounts.{Invitation, Scope, User, UserNotifier, UserToken}

  @members_topic "workspace:members"

  ## PubSub

  @doc "Subscribes to member and invitation changes."
  def subscribe_members(%Scope{}), do: Phoenix.PubSub.subscribe(Readout.PubSub, @members_topic)

  defp broadcast_members(message) do
    Phoenix.PubSub.broadcast(Readout.PubSub, @members_topic, message)
  end

  ## Database getters

  @doc "Gets a user by email."
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets an active user by email and password. Deactivated users can't sign in.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    if User.valid_password?(user, password) and User.active?(user), do: user
  end

  @doc "Gets a single user. Raises if not found."
  def get_user!(id), do: Repo.get!(User, id)

  ## First run

  @doc "Whether any account exists. The setup screen is only open when not."
  def any_users?, do: Repo.exists?(User)

  def change_setup(attrs \\ %{}) do
    User.create_changeset(%User{}, attrs, :owner)
  end

  @doc """
  Creates the first owner. Fails with `{:error, :already_set_up}` once any user
  exists, so the setup screen can't be replayed.
  """
  def bootstrap_owner(attrs) do
    Repo.transact(fn ->
      # Serialise concurrent first-run submissions.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext('readout:bootstrap'))")

      if any_users?() do
        {:error, :already_set_up}
      else
        with {:ok, user} <- %User{} |> User.create_changeset(attrs, :owner) |> Repo.insert() do
          Readout.Workspace.get_settings()
          Audit.log(user, "workspace.created", user)
          {:ok, user}
        end
      end
    end)
  end

  ## Members

  @doc """
  Lists members.

  ## Options

    * `:query` - matches name or email
    * `:role` - `"owner"`, `"admin"`, `"member"` or `"observer"`
    * `:status` - `"active"` or `"deactivated"`
  """
  def list_members(%Scope{} = scope, opts \\ []) do
    if Policy.can?(scope, :view_members, :workspace) do
      User
      |> filter_members(opts)
      |> order_by([u], asc: fragment("lower(coalesce(nullif(?, ''), ?))", u.name, u.email))
      |> Repo.all()
    else
      []
    end
  end

  defp filter_members(query, opts) do
    Enum.reduce(opts, query, fn
      {:query, text}, q when is_binary(text) and text != "" ->
        pattern = "%" <> Audit.escape_like(String.trim(text)) <> "%"
        where(q, [u], ilike(u.name, ^pattern) or ilike(u.email, ^pattern))

      {:role, role}, q when is_binary(role) and role != "" ->
        case Enum.find(User.roles(), &(Atom.to_string(&1) == role)) do
          nil -> q
          role -> where(q, [u], u.role == ^role)
        end

      {:status, "active"}, q ->
        where(q, [u], is_nil(u.deactivated_at))

      {:status, "deactivated"}, q ->
        where(q, [u], not is_nil(u.deactivated_at))

      _, q ->
        q
    end)
  end

  @doc "Counts members by status, for the filter chips."
  def count_members do
    from(u in User,
      select: %{
        total: count(u.id),
        active: filter(count(u.id), is_nil(u.deactivated_at)),
        deactivated: filter(count(u.id), not is_nil(u.deactivated_at))
      }
    )
    |> Repo.one()
  end

  @doc """
  Changes a member's role.

  Returns the target's session tokens so their open LiveViews can be
  disconnected; they reconnect with the new role.
  """
  def change_role(%Scope{} = scope, %User{} = target, role) when is_atom(role) do
    with :ok <- Policy.authorize(scope, :change_role, target),
         :ok <- Policy.authorize(scope, :assign_role, role),
         :ok <- ensure_owner_remains(target, role) do
      if target.role == role do
        {:ok, {target, []}}
      else
        Repo.transact(fn ->
          with {:ok, user} <- target |> User.role_changeset(role) |> Repo.update() do
            Audit.log(scope, "user.role_changed", user, %{from: target.role, to: role})
            {:ok, {user, session_tokens(user)}}
          end
        end)
        |> tap(&broadcast_ok(&1, :member_updated))
      end
    end
  end

  def change_role(%Scope{} = scope, %User{} = target, role) when is_binary(role) do
    case Enum.find(User.roles(), &(Atom.to_string(&1) == role)) do
      nil -> {:error, :invalid_role}
      role -> change_role(scope, target, role)
    end
  end

  # The actor can never target themselves, and an owner actor is always active,
  # so this holds by construction. Kept as a guard against future changes.
  defp ensure_owner_remains(%User{role: :owner} = target, new_role) when new_role != :owner do
    other_owners =
      Repo.aggregate(
        from(u in User,
          where: u.role == :owner and is_nil(u.deactivated_at) and u.id != ^target.id
        ),
        :count
      )

    if other_owners > 0, do: :ok, else: {:error, :last_owner}
  end

  defp ensure_owner_remains(_target, _role), do: :ok

  @doc """
  Deactivates a member: they can't sign in, and every session is deleted.

  Returns the deleted session tokens so the caller can disconnect open
  LiveViews (`ReadoutWeb.UserAuth.disconnect_sessions/1`). The user is never
  deleted, so history keeps their name.
  """
  def deactivate_user(%Scope{} = scope, %User{} = target) do
    with :ok <- Policy.authorize(scope, :deactivate, target),
         :ok <- ensure_owner_remains(target, :deactivated) do
      Repo.transact(fn ->
        changeset = Ecto.Changeset.change(target, deactivated_at: DateTime.utc_now(:second))

        with {:ok, user} <- Repo.update(changeset) do
          tokens = Repo.all_by(UserToken, user_id: user.id)
          Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
          revoke_open_invitations_for(user.email)
          Audit.log(scope, "user.deactivated", user)
          {:ok, {user, tokens}}
        end
      end)
      |> tap(&broadcast_ok(&1, :member_updated))
    end
  end

  defp revoke_open_invitations_for(email) do
    from(i in Invitation,
      where: i.email == ^email and is_nil(i.accepted_at) and is_nil(i.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])
  end

  @doc "Reactivates a deactivated member."
  def reactivate_user(%Scope{} = scope, %User{} = target) do
    with :ok <- Policy.authorize(scope, :reactivate, target),
         {:ok, user} <- target |> Ecto.Changeset.change(deactivated_at: nil) |> Repo.update() do
      Audit.log(scope, "user.reactivated", user)
      broadcast_members({:member_updated, user})
      {:ok, user}
    end
  end

  @doc """
  Transfers ownership: the target becomes an owner and the caller an admin.

  Returns the target's session tokens to disconnect.
  """
  def transfer_ownership(%Scope{user: actor} = scope, %User{} = target) do
    with :ok <- Policy.authorize(scope, :transfer_ownership, :workspace),
         :ok <- validate_transfer_target(actor, target) do
      Repo.transact(fn ->
        with {:ok, new_owner} <- target |> User.role_changeset(:owner) |> Repo.update(),
             {:ok, former} <- actor |> User.role_changeset(:admin) |> Repo.update() do
          Audit.log(scope, "workspace.ownership_transferred", new_owner, %{from: actor.email})
          broadcast_members({:member_updated, former})
          {:ok, {new_owner, session_tokens(new_owner) ++ session_tokens(former)}}
        end
      end)
      |> tap(&broadcast_ok(&1, :member_updated))
    end
  end

  defp validate_transfer_target(%User{id: id}, %User{id: id}), do: {:error, :invalid_target}

  defp validate_transfer_target(_actor, %User{} = target) do
    if User.active?(target), do: :ok, else: {:error, :invalid_target}
  end

  defp session_tokens(%User{id: id}), do: Repo.all_by(UserToken, user_id: id, context: "session")

  defp broadcast_ok({:ok, {user, _tokens}} = result, event) do
    broadcast_members({event, user})
    result
  end

  defp broadcast_ok(result, _event), do: result

  ## Invitations

  @doc "Lists pending (not accepted, not revoked) invitations, newest first."
  def list_pending_invitations(%Scope{} = scope) do
    if Policy.can?(scope, :invite, :workspace) do
      from(i in Invitation,
        where: is_nil(i.accepted_at) and is_nil(i.revoked_at),
        order_by: [desc: i.inserted_at],
        preload: [:invited_by]
      )
      |> Repo.all()
    else
      []
    end
  end

  def change_invitation(attrs \\ %{}) do
    Invitation.changeset(%Invitation{role: :member}, attrs)
  end

  @doc """
  Invites someone. Returns `{:ok, {invitation, token}}`; the raw token is only
  returned here, to build the copyable link.
  """
  def create_invitation(%Scope{} = scope, attrs, url_fun \\ nil) do
    changeset = change_invitation(attrs)
    role = Ecto.Changeset.get_field(changeset, :role)

    with :ok <- Policy.authorize(scope, :invite, :workspace),
         :ok <- Policy.authorize(scope, :assign_role, role),
         {:ok, changeset} <- validate_not_member(changeset) do
      {token, hash} = Invitation.generate_token()
      now = DateTime.utc_now(:second)

      changeset
      |> Ecto.Changeset.put_change(:token_hash, hash)
      |> Ecto.Changeset.put_change(:expires_at, Invitation.new_expiry())
      |> Ecto.Changeset.put_change(:last_sent_at, now)
      |> Ecto.Changeset.put_assoc(:invited_by, scope.user)
      |> Repo.insert()
      |> case do
        {:ok, invitation} ->
          Audit.log(scope, "invitation.created", invitation, %{role: invitation.role})
          broadcast_members({:invitation_updated, invitation})
          maybe_email_invitation(scope, invitation, token, url_fun)
          {:ok, {invitation, token}}

        error ->
          error
      end
    end
  end

  defp validate_not_member(changeset) do
    email = Ecto.Changeset.get_field(changeset, :email)

    cond do
      not changeset.valid? ->
        {:error, Map.put(changeset, :action, :insert)}

      email && get_user_by_email(email) ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:email, "is already a member")
         |> Map.put(:action, :insert)}

      true ->
        {:ok, changeset}
    end
  end

  @doc "Issues a fresh link (and 7 more days) for a pending invitation."
  def resend_invitation(%Scope{} = scope, %Invitation{} = invitation, url_fun \\ nil) do
    with :ok <- Policy.authorize(scope, :invite, :workspace),
         :ok <- Policy.authorize(scope, :assign_role, invitation.role),
         :ok <- ensure_open(invitation) do
      {token, hash} = Invitation.generate_token()

      {:ok, invitation} =
        invitation
        |> Ecto.Changeset.change(
          token_hash: hash,
          expires_at: Invitation.new_expiry(),
          last_sent_at: DateTime.utc_now(:second)
        )
        |> Repo.update()

      Audit.log(scope, "invitation.resent", invitation)
      broadcast_members({:invitation_updated, invitation})
      maybe_email_invitation(scope, invitation, token, url_fun)
      {:ok, {invitation, token}}
    end
  end

  @doc "Revokes a pending invitation; its link stops working."
  def revoke_invitation(%Scope{} = scope, %Invitation{} = invitation) do
    with :ok <- Policy.authorize(scope, :invite, :workspace),
         :ok <- ensure_open(invitation),
         {:ok, invitation} <-
           invitation
           |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
           |> Repo.update() do
      Audit.log(scope, "invitation.revoked", invitation)
      broadcast_members({:invitation_updated, invitation})
      {:ok, invitation}
    end
  end

  # Without SMTP (or a URL builder) the invitation is only a copyable link.
  defp maybe_email_invitation(%Scope{user: inviter}, invitation, token, url_fun)
       when is_function(url_fun, 1) do
    if Readout.Mailer.enabled?() do
      UserNotifier.deliver_invitation(invitation, url_fun.(token), inviter, %{
        role: ReadoutWeb.Layouts.role_label(invitation.role),
        workspace: Readout.Workspace.get_settings().name,
        expires_on: invitation.expires_at
      })
    end
  end

  defp maybe_email_invitation(_scope, _invitation, _token, _url_fun), do: :ok

  defp ensure_open(%Invitation{accepted_at: nil, revoked_at: nil}), do: :ok
  defp ensure_open(_), do: {:error, :not_pending}

  @doc "Gets a pending invitation by id (for admin actions)."
  def get_pending_invitation!(id) do
    Repo.one!(
      from i in Invitation, where: i.id == ^id and is_nil(i.accepted_at) and is_nil(i.revoked_at)
    )
  end

  @doc "Finds a usable (pending, unexpired) invitation from the token in a link."
  def get_invitation_by_token(token) when is_binary(token) do
    with hash when is_binary(hash) <- Invitation.hash_encoded(token),
         %Invitation{} = invitation <- Repo.get_by(Invitation, token_hash: hash),
         :pending <- Invitation.status(invitation) do
      Repo.preload(invitation, :invited_by)
    else
      _ -> nil
    end
  end

  def change_acceptance(%Invitation{} = invitation, attrs \\ %{}) do
    User.create_changeset(%User{email: invitation.email}, attrs, invitation.role)
  end

  @doc """
  Accepts an invitation: creates the account (confirmed, with the invited
  role) and marks the invitation used.
  """
  def accept_invitation(token, attrs) when is_binary(token) do
    Repo.transact(fn ->
      with %Invitation{} = invitation <- get_invitation_by_token(token) || {:error, :invalid},
           # The email comes from the invitation, never from the form.
           attrs =
             attrs
             |> Map.new(fn {k, v} -> {to_string(k), v} end)
             |> Map.put("email", invitation.email),
           {:ok, user} <-
             %User{} |> User.create_changeset(attrs, invitation.role) |> Repo.insert(),
           {:ok, invitation} <-
             invitation
             |> Ecto.Changeset.change(accepted_at: DateTime.utc_now(:second), user_id: user.id)
             |> Repo.update() do
        Audit.log(user, "invitation.accepted", invitation, %{role: invitation.role})
        {:ok, user}
      end
    end)
    |> case do
      {:ok, user} ->
        broadcast_members({:member_updated, user})
        {:ok, user}

      error ->
        error
    end
  end

  ## Profile

  def change_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc "Updates the caller's own profile and preferences."
  def update_profile(%Scope{user: user}, attrs) do
    with {:ok, user} <- user |> User.profile_changeset(attrs) |> Repo.update() do
      broadcast_members({:member_updated, user})
      {:ok, user}
    end
  end

  @doc "Updates only the theme preference (from the theme toggle)."
  def update_theme(%Scope{user: user}, theme) when theme in ["system", "light", "dark"] do
    user |> Ecto.Changeset.change(theme: theme) |> Repo.update()
  end

  @last_active_resolution_seconds 300

  @doc """
  Records activity, at most every five minutes per user, so "last active" in
  the members table stays meaningful without a write per request.
  """
  def touch_last_active(%User{} = user) do
    now = DateTime.utc_now(:second)

    if is_nil(user.last_active_at) or
         DateTime.diff(now, user.last_active_at) >= @last_active_resolution_seconds do
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [last_active_at: now])

      %{user | last_active_at: now}
    else
      user
    end
  end

  ## Settings (email and password)

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "Returns a changeset for changing the user email."
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc "Returns a changeset for changing the user password."
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.
  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc "Generates a session token."
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  Deactivated users never resolve.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Gets the user with the given magic link token."
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  Every account is created confirmed (first-run setup or an accepted
  invitation), so a valid link simply signs the user in and is consumed.
  """
  def login_user_by_magic_link(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, token} <- Repo.one(query) do
      Repo.delete!(token)
      {:ok, {user, []}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Delivers the update email instructions to the given user."
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given (active) user.
  At most 5 per address every 15 minutes.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    if User.active?(user) and
         Readout.RateLimit.hit({:login_email, user.id}, 5, :timer.minutes(15)) == :ok do
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
    else
      {:error, :deactivated}
    end
  end

  @doc """
  Emails a password reset link (valid for an hour). Silently does nothing for
  deactivated users or when rate-limited (5 per address every 15 minutes).
  """
  def deliver_reset_password_instructions(%User{} = user, url_fun) when is_function(url_fun, 1) do
    if User.active?(user) and
         Readout.RateLimit.hit({:reset_email, user.id}, 5, :timer.minutes(15)) == :ok do
      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      Repo.insert!(user_token)
      UserNotifier.deliver_reset_password_instructions(user, url_fun.(encoded_token))
    else
      {:error, :not_sent}
    end
  end

  @doc "Gets the user for a valid password reset token, or nil."
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Sets a new password from a reset link. Every session and token of the user
  is deleted (so the link can't be reused); the caller disconnects them.
  """
  def reset_user_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc "Deletes the signed token with the given context."
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
