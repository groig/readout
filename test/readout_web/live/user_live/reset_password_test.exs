defmodule ReadoutWeb.UserLive.ResetPasswordTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  alias Readout.Accounts

  setup do
    %{user: user_fixture()}
  end

  test "requests a reset link without revealing whether the email exists", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _} = live(conn, ~p"/users/reset-password")

    {:ok, _lv, html} =
      lv
      |> form("#reset-request-form", user: %{email: user.email})
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

    assert html =~ "If your email is in our system"
    assert Readout.Repo.get_by!(Accounts.UserToken, user_id: user.id).context == "reset_password"
  end

  test "sets a new password once and signs out other sessions", %{conn: conn, user: user} do
    session = Accounts.generate_user_session_token(user)

    token =
      extract_user_token(fn url -> Accounts.deliver_reset_password_instructions(user, url) end)

    {:ok, lv, _} = live(conn, ~p"/users/reset-password/#{token}")

    lv
    |> form("#reset-password-form", user: %{password: "short", password_confirmation: "short"})
    |> render_submit()

    assert has_element?(lv, "#reset-password-form")

    {:ok, _lv, _html} =
      lv
      |> form("#reset-password-form",
        user: %{password: "a brand new password", password_confirmation: "a brand new password"}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

    assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
    refute Accounts.get_user_by_session_token(session)

    assert {:error, {:live_redirect, %{to: "/users/reset-password"}}} =
             live(conn, ~p"/users/reset-password/#{token}")
  end
end
