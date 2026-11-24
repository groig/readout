defmodule ReadoutWeb.InvitationLiveTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  alias Readout.Accounts.Scope

  setup do
    owner = owner_fixture(name: "Alex")
    {invitation, token} = invitation_fixture(Scope.for_user(owner), %{"role" => "admin"})
    %{invitation: invitation, token: token}
  end

  test "accepting creates the account and signs in", %{
    conn: conn,
    invitation: invitation,
    token: token
  } do
    {:ok, lv, html} = live(conn, ~p"/invitations/#{token}")
    assert html =~ "Alex invited you as Admin"
    assert has_element?(lv, "#invitation-email[readonly][value='#{invitation.email}']")

    # The browser posts the read-only email field along with the rest.
    form =
      form(lv, "#invitation-form",
        user: %{"email" => invitation.email, "name" => "Ana", "password" => valid_user_password()}
      )

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/documents"
    assert Readout.Accounts.get_user_by_email(invitation.email).role == :admin
  end

  test "shows an explanation for unusable links", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/invitations/not-a-real-token")
    assert has_element?(lv, "#invitation-invalid")
    refute has_element?(lv, "#invitation-form")
  end
end
