defmodule ReadoutWeb.SettingsLive.SettingsPagesTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Audit

  describe "audit log" do
    test "owners see entries, and new ones arrive live", %{conn: conn} do
      %{conn: conn, user: owner} = register_and_log_in_owner(%{conn: conn})
      event = Audit.log(Scope.for_user(owner), "workspace.updated")

      {:ok, lv, _html} = live(conn, ~p"/settings/audit")
      assert has_element?(lv, "#events-#{event.id}")

      live_event = Audit.log(Scope.for_user(owner), "invitation.revoked", %{email: "z@x.com"})
      assert has_element?(lv, "#events-#{live_event.id}")
    end

    test "members are turned away", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/documents", flash: %{"error" => _}}}} =
               live(conn, ~p"/settings/audit")
    end
  end

  describe "workspace" do
    test "owners rename the workspace", %{conn: conn} do
      %{conn: conn} = register_and_log_in_owner(%{conn: conn})
      {:ok, lv, _html} = live(conn, ~p"/settings/workspace")

      lv
      |> form("#workspace-form", settings: %{"name" => "Crinno"})
      |> render_submit()

      assert Readout.Workspace.get_settings().name == "Crinno"
    end

    test "owners transfer ownership after confirming", %{conn: conn} do
      %{conn: conn, user: owner} = register_and_log_in_owner(%{conn: conn})
      member = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/settings/workspace")

      lv |> form("#transfer-form", transfer: %{"user_id" => member.id}) |> render_submit()
      assert has_element?(lv, "#transfer-dialog")

      assert {:error, {:live_redirect, %{to: "/settings/members"}}} =
               lv |> element("#confirm-transfer") |> render_click()

      assert Readout.Accounts.get_user!(member.id).role == :owner
      assert Readout.Accounts.get_user!(owner.id).role == :admin
    end

    test "admins are turned away", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      assert {:error, {:redirect, %{to: "/documents"}}} = live(conn, ~p"/settings/workspace")
    end
  end

  describe "profile" do
    setup :register_and_log_in_user

    test "saves name and colour", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      lv
      |> form("#profile-form", user: %{"name" => "Renamed", "avatar_color" => "pink"})
      |> render_change()

      lv |> form("#profile-form") |> render_submit()

      user = Readout.Accounts.get_user!(user.id)
      assert user.name == "Renamed"
      assert user.avatar_color == "pink"
    end

    test "changing the language reloads the page in that language", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")
      lv |> form("#profile-form", user: %{"locale" => "es"}) |> render_change()

      assert {:error, {:redirect, %{to: "/settings/profile"}}} =
               lv |> form("#profile-form") |> render_submit()

      assert Readout.Accounts.get_user!(user.id).locale == "es"
      {:ok, _lv, html} = live(conn, ~p"/settings/profile")
      assert html =~ "Preferencias"
    end
  end
end
