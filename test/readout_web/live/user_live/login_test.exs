defmodule ReadoutWeb.UserLive.LoginTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  describe "first run" do
    test "redirects to setup when there are no accounts", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/users/log-in")
    end
  end

  describe "login page" do
    setup do
      %{user: user_fixture()}
    end

    test "renders the password form with a link to the email option", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, "#login_form_password")
      assert has_element?(lv, "#use-magic-link")
      refute has_element?(lv, "a[href='/users/register']")
    end

    test "switches to the sign-in link form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("#use-magic-link") |> render_click()
      assert has_element?(lv, "#login_form_magic")
      lv |> element("#use-password") |> render_click()
      assert has_element?(lv, "#login_form_password")
    end

    test "sends a sign-in link when the user exists", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("#use-magic-link") |> render_click()

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert Readout.Repo.get_by!(Readout.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose whether the user exists", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      lv |> element("#use-magic-link") |> render_click()

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end

    test "signs in with valid credentials", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/documents"
    end

    test "shows an error with invalid credentials", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})
      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows the password form with the email filled in and read-only", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(lv, "#login_form_password input[readonly][value='#{user.email}']")
    end
  end
end
