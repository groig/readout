defmodule ReadoutWeb.UserLive.ConfirmationTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  alias Readout.Accounts

  setup do
    %{user: user_fixture()}
  end

  defp magic_token(user) do
    extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)
  end

  describe "sign-in link page" do
    test "renders the sign-in form for a valid link", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{magic_token(user)}")
      assert has_element?(lv, "#login_form")
      assert has_element?(lv, "#login_form button[name='user[remember_me]']")
    end

    test "offers a single sign-in button to an already signed-in user", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{magic_token(user)}")
      assert has_element?(lv, "#login_form")
      refute has_element?(lv, "#login_form button[name='user[remember_me]']")
    end

    test "signs the user in once", %{conn: conn, user: user} do
      token = magic_token(user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back"
      assert redirected_to(conn) == ~p"/documents"
      assert get_session(conn, :user_token)

      # the link can't be used again
      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/users/log-in/#{token}")
    end

    test "redirects for an invalid token", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/log-in", flash: flash}}} =
               live(conn, ~p"/users/log-in/invalid-token")

      assert flash["error"] =~ "invalid or has expired"
    end
  end
end
