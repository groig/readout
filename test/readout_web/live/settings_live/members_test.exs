defmodule ReadoutWeb.SettingsLive.MembersTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  alias Readout.Accounts
  alias Readout.Accounts.Scope

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "lists members and filters them", %{conn: conn, user: me} do
      other = user_fixture(name: "Zoe Member")
      {:ok, lv, _html} = live(conn, ~p"/settings/members")

      assert has_element?(lv, "#members-#{me.id}")
      assert has_element?(lv, "#members-#{other.id}")

      lv |> form("#member-filters", %{"query" => "zoe"}) |> render_change()
      assert_patch(lv, ~p"/settings/members?query=zoe")
      assert has_element?(lv, "#members-#{other.id}")
      refute has_element?(lv, "#members-#{me.id}")
    end

    test "invites someone and shows the copyable link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/members")

      lv |> element("#invite-button") |> render_click()
      assert has_element?(lv, "#invite-dialog")
      # admins can't invite owners
      refute has_element?(lv, "#invite-form input[value='owner']")

      lv
      |> form("#invite-form", invitation: %{"email" => "new@example.com", "role" => "member"})
      |> render_submit()

      assert has_element?(lv, "#invite-link-dialog")

      url =
        lv
        |> element("#invite-link-url")
        |> render()
        |> then(&Regex.run(~r{/invitations/[\w-]+}, &1))

      assert url
      assert has_element?(lv, "#invitations")
    end

    test "opens the invite dialog from ?invite=1 (command palette)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/members?invite=1")
      assert has_element?(lv, "#invite-dialog")
    end

    test "changes a member's role and disconnects their sessions", %{conn: conn} do
      member = user_fixture()
      token = Accounts.generate_user_session_token(member)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      ReadoutWeb.Endpoint.subscribe(topic)

      {:ok, lv, _html} = live(conn, ~p"/settings/members")

      lv
      |> element("#members-#{member.id}-menu button[phx-click*='observer']")
      |> render_click()

      assert Accounts.get_user!(member.id).role == :observer
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end

    test "deactivates after confirmation, ending sessions live", %{conn: conn} do
      member = user_fixture(name: "Mia")
      token = Accounts.generate_user_session_token(member)
      topic = "users_sessions:#{Base.url_encode64(token)}"
      ReadoutWeb.Endpoint.subscribe(topic)

      {:ok, lv, _html} = live(conn, ~p"/settings/members")
      lv |> element("#members-#{member.id}-menu button", "Deactivate") |> render_click()
      assert has_element?(lv, "#deactivate-dialog")

      lv |> element("#confirm-deactivate") |> render_click()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      refute Readout.Accounts.User.active?(Accounts.get_user!(member.id))
      refute Accounts.get_user_by_session_token(token)
    end

    test "has no actions on owners", %{conn: conn} do
      owner = owner_fixture()
      {:ok, lv, _html} = live(conn, ~p"/settings/members")
      assert has_element?(lv, "#members-#{owner.id}")
      refute has_element?(lv, "#members-#{owner.id}-menu")
    end

    test "rejects forged events the UI hides", %{conn: conn} do
      owner = owner_fixture()
      {:ok, lv, _html} = live(conn, ~p"/settings/members")

      render_hook(lv, "change_role", %{"id" => owner.id, "role" => "member"})
      assert Accounts.get_user!(owner.id).role == :owner

      render_hook(lv, "deactivate", %{"id" => owner.id})
      assert Readout.Accounts.User.active?(Accounts.get_user!(owner.id))
    end

    test "updates live when someone else changes the team", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/members")
      owner = owner_fixture()

      {:ok, {inv, _}} =
        Accounts.create_invitation(Scope.for_user(owner), %{
          "email" => "live@x.com",
          "role" => "member"
        })

      assert render(lv) =~ "live@x.com"
      assert has_element?(lv, "#invitations-#{inv.id}")
    end
  end

  describe "as a member" do
    setup :register_and_log_in_user

    test "sees the team but no management controls", %{conn: conn} do
      other = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/settings/members")
      assert has_element?(lv, "#members-#{other.id}")
      refute has_element?(lv, "#invite-button")
      refute has_element?(lv, "#members-#{other.id}-menu")
    end

    test "can't invite even by sending the event", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/members")
      render_hook(lv, "invite", %{"invitation" => %{"email" => "x@x.com", "role" => "admin"}})
      assert Readout.Repo.aggregate(Readout.Accounts.Invitation, :count) == 0
    end
  end
end
