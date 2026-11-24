defmodule ReadoutWeb.ShellTest do
  @moduledoc "The app shell: navigation, command palette, theme, shortcuts, style guide."
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "app pages render inside the shell", %{conn: conn} do
    for path <- [~p"/documents", ~p"/analytics", ~p"/settings/profile"] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, "#sidebar")
      assert has_element?(lv, "#command-palette")
      assert has_element?(lv, "#shortcuts")
      assert has_element?(lv, "[data-shortcut='mod+k']")
    end
  end

  test "signed-out visitors are sent to sign in" do
    Readout.AccountsFixtures.user_fixture()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/documents")
  end

  test "the command palette filters commands by role", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/documents")
    assert has_element?(lv, "#palette-go-documents")
    refute has_element?(lv, "#palette-go-audit")
    refute has_element?(lv, "#palette-invite")

    lv |> form("#palette-form", %{"q" => "dark"}) |> render_change()
    assert has_element?(lv, "#palette-theme-dark")
    refute has_element?(lv, "#palette-go-documents")

    lv |> form("#palette-form", %{"q" => "zzzz"}) |> render_change()
    refute has_element?(lv, "[role=option]")
  end

  test "the palette matches without accents", %{conn: conn} do
    assert ReadoutWeb.CommandPalette.normalize("Configuración") == "configuracion"
    {:ok, lv, _html} = live(conn, ~p"/documents")
    lv |> form("#palette-form", %{"q" => "PROFILE"}) |> render_change()
    assert has_element?(lv, "#palette-go-profile")
  end

  test "owners get admin commands in the palette" do
    %{conn: conn} = register_and_log_in_owner(%{conn: build_conn()})
    {:ok, lv, _html} = live(conn, ~p"/documents")
    assert has_element?(lv, "#palette-go-audit")
    assert has_element?(lv, "#palette-go-workspace")
    assert has_element?(lv, "#palette-invite")
  end

  test "the theme toggle persists to the profile", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/documents")
    lv |> element("#sidebar-theme button[data-theme-option=dark]") |> render_click()
    assert Readout.Accounts.get_user!(user.id).theme == "dark"

    conn = get(conn, ~p"/documents")
    assert html_response(conn, 200) =~ ~s(data-theme-pref="dark")
  end

  test "the style guide renders every section", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dev/design")

    for id <- ~w(tokens type motion buttons forms overlays display data charts) do
      assert has_element?(lv, "section##{id}")
    end

    lv |> element("button[phx-value-kind=info]") |> render_click()
    assert has_element?(lv, "#flash-info")
  end
end
