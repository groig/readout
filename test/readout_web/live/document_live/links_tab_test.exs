defmodule ReadoutWeb.DocumentLive.LinksTabTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Links

  setup :register_and_log_in_user

  test "creates a link from the Share button", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    fake_ready!(doc)

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    lv |> element("#share-button") |> render_click()
    assert has_element?(lv, "#link-sheet")

    lv
    |> form("#link-form", link: %{name: "Client X", require_email: "true", watermark: "true"})
    |> render_change()

    lv |> form("#link-form") |> render_submit()
    assert_patch(lv, ~p"/documents/#{doc.id}/links")

    [link] = Links.list_links(scope, Readout.Documents.get_document(scope, doc.id))
    assert link.name == "Client X"
    assert link.require_email and link.watermark
    assert has_element?(lv, "#links-#{link.id}")
    assert has_element?(lv, "#links-#{link.id}-copy")
  end

  test "edits and disables a link; expiry is a date", %{conn: conn, scope: scope} do
    {doc, link} = shared_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/links")

    lv |> element("#links-#{link.id}-edit") |> render_click()
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    lv
    |> form("#link-form", link: %{name: "Investors", enabled: "false", expires_on: tomorrow})
    |> render_submit()

    link = Links.get_link(doc, link.id)
    assert link.name == "Investors"
    refute link.enabled
    assert link.expires_at
  end

  test "opens the new-link sheet from ?new=1 (command palette)", %{conn: conn, scope: scope} do
    {doc, _} = shared_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/links?new=1")
    assert has_element?(lv, "#link-sheet")
  end

  test "people who can't edit see links but can't change them", %{conn: conn} do
    owner = Scope.for_user(user_fixture())
    {doc, link} = shared_fixture(owner)

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/links")
    assert has_element?(lv, "#links-#{link.id}")
    refute has_element?(lv, "#links-#{link.id}-edit")
    refute has_element?(lv, "#share-button")

    render_hook(lv, "edit_link", %{"id" => link.id})
    render_hook(lv, "save_link", %{"link" => %{"name" => "Hijacked"}})
    assert Links.get_link(doc, link.id).name == "Client X"
  end
end
