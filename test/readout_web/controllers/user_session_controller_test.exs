defmodule ReadoutWeb.UserSessionControllerTest do
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in and lands in the app", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/documents"

      # A signed-in request reaches the app shell.
      conn = get(conn, ~p"/documents")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_readout_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/documents"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "rejects invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "rejects deactivated users", %{conn: conn} do
      user = deactivated_user_fixture()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/documents"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => "invalid"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed out"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end
  end
end
