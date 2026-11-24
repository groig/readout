defmodule ReadoutWeb.NotificationSettingsTest do
  # Changes the webhook config: not async.
  use ReadoutWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Readout.DocumentsFixtures

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:readout, :rocketchat_webhook_url)
    Application.put_env(:readout, :rocketchat_webhook_url, "https://chat.example/hooks/x")
    on_exit(fn -> Application.put_env(:readout, :rocketchat_webhook_url, previous) end)
  end

  test "the bell mutes and follows a document", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#notify-toggle[aria-pressed=true]")

    lv |> element("#notify-toggle") |> render_click()
    assert has_element?(lv, "#notify-toggle[aria-pressed=false]")
    refute Readout.Notifications.subscribed?(scope, doc)
  end

  test "the profile saves a Rocket.Chat username", %{conn: conn, user: user} do
    {:ok, lv, _} = live(conn, ~p"/settings/profile")
    lv |> form("#profile-form", user: %{chat_username: "@alex.morgan"}) |> render_change()
    lv |> form("#profile-form") |> render_submit()
    assert Readout.Accounts.get_user!(user.id).chat_username == "alex.morgan"
  end
end
