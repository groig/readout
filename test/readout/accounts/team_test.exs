defmodule Readout.Accounts.TeamTest do
  @moduledoc "First-run setup, invitations, members, roles, deactivation and profiles."
  use Readout.DataCase, async: true

  import Readout.AccountsFixtures

  alias Readout.{Accounts, Audit, Repo}
  alias Readout.Accounts.{Invitation, Scope, User, UserToken}

  defp scope(user), do: Scope.for_user(user)

  defp actions do
    Repo.all(from e in Audit.Event, select: e.action, order_by: e.inserted_at)
  end

  describe "bootstrap_owner/1" do
    test "creates the first owner, confirmed, and logs it" do
      assert {:ok, user} =
               Accounts.bootstrap_owner(%{
                 "name" => "Alex",
                 "email" => "owner@example.com",
                 "password" => valid_user_password()
               })

      assert user.role == :owner
      assert user.confirmed_at
      assert "workspace.created" in actions()
    end

    test "refuses once any account exists" do
      user_fixture()

      assert {:error, :already_set_up} =
               Accounts.bootstrap_owner(%{
                 "name" => "Mallory",
                 "email" => "m@example.com",
                 "password" => valid_user_password()
               })
    end

    test "validates the form" do
      assert {:error, changeset} =
               Accounts.bootstrap_owner(%{"name" => "", "email" => "bad", "password" => "short"})

      assert %{name: [_], email: [_], password: [_]} = errors_on(changeset)
    end
  end

  describe "invitations" do
    setup do
      %{owner: owner_fixture(), admin: admin_fixture(), member: user_fixture()}
    end

    test "owners and admins can invite; the token is only returned once", %{admin: admin} do
      assert {:ok, {invitation, token}} =
               Accounts.create_invitation(scope(admin), %{
                 "email" => "new@x.com",
                 "role" => "member"
               })

      assert invitation.role == :member
      refute invitation.token_hash == token
      assert Accounts.get_invitation_by_token(token).id == invitation.id
      assert "invitation.created" in actions()
    end

    test "members can't invite", %{member: member} do
      assert {:error, :unauthorized} =
               Accounts.create_invitation(scope(member), %{
                 "email" => "x@x.com",
                 "role" => "member"
               })
    end

    test "admins can't invite owners", %{admin: admin} do
      assert {:error, :unauthorized} =
               Accounts.create_invitation(scope(admin), %{"email" => "x@x.com", "role" => "owner"})
    end

    test "rejects existing members and duplicate pending invitations", %{
      owner: owner,
      member: member
    } do
      assert {:error, changeset} =
               Accounts.create_invitation(scope(owner), %{
                 "email" => member.email,
                 "role" => "admin"
               })

      assert "is already a member" in errors_on(changeset).email

      {_inv, _token} = invitation_fixture(scope(owner), %{"email" => "dup@x.com"})

      assert {:error, changeset} =
               Accounts.create_invitation(scope(owner), %{
                 "email" => "dup@x.com",
                 "role" => "member"
               })

      assert "already has a pending invitation" in errors_on(changeset).email
    end

    test "expired, revoked and accepted invitations stop working", %{owner: owner} do
      {inv, token} = invitation_fixture(scope(owner))

      Repo.update_all(from(i in Invitation, where: i.id == ^inv.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      refute Accounts.get_invitation_by_token(token)

      {inv, token} = invitation_fixture(scope(owner))
      assert {:ok, _} = Accounts.revoke_invitation(scope(owner), inv)
      refute Accounts.get_invitation_by_token(token)
      refute Accounts.get_invitation_by_token("garbage!!")
    end

    test "resending replaces the link and extends the expiry", %{owner: owner} do
      {inv, old_token} = invitation_fixture(scope(owner))
      assert {:ok, {resent, new_token}} = Accounts.resend_invitation(scope(owner), inv)

      refute Accounts.get_invitation_by_token(old_token)
      assert Accounts.get_invitation_by_token(new_token).id == resent.id
      assert "invitation.resent" in actions()
    end

    test "accepting creates a confirmed account with the invited role and email", %{owner: owner} do
      {inv, token} = invitation_fixture(scope(owner), %{"role" => "observer"})

      assert {:ok, user} =
               Accounts.accept_invitation(token, %{
                 "name" => "Ana",
                 "password" => valid_user_password(),
                 # attempts to change email or role are ignored
                 "email" => "attacker@evil.com",
                 "role" => "owner"
               })

      assert user.email == inv.email
      assert user.role == :observer
      assert user.confirmed_at
      assert Repo.get!(Invitation, inv.id).accepted_at
      refute Accounts.get_invitation_by_token(token)
      assert {:error, :invalid} = Accounts.accept_invitation(token, %{"name" => "x"})
    end

    test "accepting validates name and password", %{owner: owner} do
      {_inv, token} = invitation_fixture(scope(owner))

      assert {:error, changeset} =
               Accounts.accept_invitation(token, %{"name" => "", "password" => "x"})

      assert %{name: [_], password: [_]} = errors_on(changeset)
      assert Accounts.get_invitation_by_token(token)
    end
  end

  describe "members" do
    setup do
      %{
        owner: owner_fixture(name: "Alex"),
        admin: admin_fixture(name: "Adam"),
        member: user_fixture(name: "Mia")
      }
    end

    test "lists and filters", %{owner: owner, member: member} do
      assert length(Accounts.list_members(scope(owner))) == 3
      assert [found] = Accounts.list_members(scope(owner), query: "mia")
      assert found.id == member.id
      assert [_] = Accounts.list_members(scope(owner), role: "admin")
      assert Accounts.list_members(scope(owner), status: "deactivated") == []
    end

    test "changing a role returns the target's sessions to disconnect", %{
      owner: owner,
      member: member
    } do
      token = Accounts.generate_user_session_token(member)

      assert {:ok, {updated, [%UserToken{token: ^token}]}} =
               Accounts.change_role(scope(owner), member, :admin)

      assert updated.role == :admin

      assert %{"from" => "member", "to" => "admin"} =
               Repo.one!(from e in Audit.Event, where: e.action == "user.role_changed").metadata
    end

    test "admins can't promote to owner or touch other admins", %{
      admin: admin,
      member: member,
      owner: owner
    } do
      assert {:error, :unauthorized} = Accounts.change_role(scope(admin), member, :owner)
      assert {:error, :unauthorized} = Accounts.change_role(scope(admin), owner, :member)
      other_admin = admin_fixture()
      assert {:error, :unauthorized} = Accounts.deactivate_user(scope(admin), other_admin)
    end

    test "nobody changes their own role", %{owner: owner} do
      assert {:error, :unauthorized} = Accounts.change_role(scope(owner), owner, :admin)
    end

    test "deactivating ends sessions, blocks sign-in and keeps the user", %{
      admin: admin,
      member: member
    } do
      session = Accounts.generate_user_session_token(member)

      {:ok, _} =
        Accounts.create_invitation(scope(admin), %{"email" => "pending@x.com", "role" => "member"})

      assert {:ok, {user, tokens}} = Accounts.deactivate_user(scope(admin), member)
      assert user.deactivated_at
      assert Enum.any?(tokens, &(&1.token == session))
      refute Accounts.get_user_by_session_token(session)
      refute Accounts.get_user_by_email_and_password(member.email, valid_user_password())
      assert Repo.get(User, member.id)
      assert "user.deactivated" in actions()

      assert {:ok, user} = Accounts.reactivate_user(scope(admin), user)
      assert User.active?(user)
      assert Accounts.get_user_by_email_and_password(member.email, valid_user_password())
    end

    test "transferring ownership swaps roles", %{owner: owner, member: member} do
      assert {:ok, {new_owner, _tokens}} = Accounts.transfer_ownership(scope(owner), member)
      assert new_owner.role == :owner
      assert Repo.get!(User, owner.id).role == :admin
      assert "workspace.ownership_transferred" in actions()
    end

    test "only owners transfer, and never to themselves or deactivated people", %{
      owner: owner,
      admin: admin
    } do
      assert {:error, :unauthorized} = Accounts.transfer_ownership(scope(admin), owner)
      assert {:error, :invalid_target} = Accounts.transfer_ownership(scope(owner), owner)
      gone = deactivated_user_fixture()
      assert {:error, :invalid_target} = Accounts.transfer_ownership(scope(owner), gone)
    end

    test "broadcasts member changes", %{owner: owner, member: member} do
      Accounts.subscribe_members(scope(owner))
      {:ok, _} = Accounts.change_role(scope(owner), member, :observer)
      assert_receive {:member_updated, %User{role: :observer}}
    end
  end

  describe "profile" do
    test "updates profile fields but never role or email" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_profile(scope(user), %{
                 "name" => "New Name",
                 "avatar_color" => "violet",
                 "locale" => "es",
                 "timezone" => "Europe/Madrid",
                 "theme" => "dark",
                 "role" => "owner",
                 "email" => "x@y.com"
               })

      assert updated.name == "New Name"
      assert updated.locale == "es"
      assert updated.timezone == "Europe/Madrid"
      assert updated.role == :member
      assert updated.email == user.email
    end

    test "rejects unknown values" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_profile(scope(user), %{
                 "timezone" => "Mars/Olympus",
                 "locale" => "xx",
                 "avatar_color" => "plaid"
               })

      assert %{timezone: [_], locale: [_], avatar_color: [_]} = errors_on(changeset)
    end

    test "touch_last_active/1 writes at most every five minutes" do
      user = user_fixture()
      user = Accounts.touch_last_active(user)
      first = user.last_active_at
      assert first
      assert Accounts.touch_last_active(user).last_active_at == first
    end
  end
end
