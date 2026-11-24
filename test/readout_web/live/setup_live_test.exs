defmodule ReadoutWeb.SetupLiveTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  test "creates the first owner and signs them in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup")
    assert has_element?(lv, "#setup-form")

    params = %{
      "name" => "Alex",
      "email" => "owner@example.com",
      "password" => valid_user_password(),
      "remember_me" => "true"
    }

    form = form(lv, "#setup-form", user: params)
    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/documents"
    assert Readout.Accounts.get_user_by_email("owner@example.com").role == :owner
  end

  test "shows validation errors", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup")

    html =
      lv
      |> form("#setup-form", user: %{"name" => "", "email" => "nope", "password" => "short"})
      |> render_submit()

    assert html =~ "must have the @ sign"
    assert html =~ "should be at least 12 character"
  end

  test "is closed once an account exists", %{conn: conn} do
    user_fixture()
    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/setup")
  end
end
