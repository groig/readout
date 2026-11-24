defmodule ReadoutWeb.PageControllerTest do
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures

  test "GET / sends a fresh install to setup", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/setup"
  end

  test "GET / sends signed-out people to sign in", %{conn: conn} do
    user_fixture()
    assert redirected_to(get(conn, ~p"/")) == ~p"/users/log-in"
  end

  test "GET / sends signed-in people to their documents", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/documents"
  end

  test "sets a strict content security policy with a nonce", %{conn: conn} do
    user_fixture()
    conn = get(conn, ~p"/users/log-in")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self' 'nonce-"
    assert csp =~ "frame-ancestors 'none'"
    refute csp =~ "unsafe-eval"

    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
    assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
  end
end
