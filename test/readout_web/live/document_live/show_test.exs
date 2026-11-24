defmodule ReadoutWeb.DocumentLive.ShowTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Documents

  setup :register_and_log_in_user

  test "shows the viewer with every page once ready", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    fake_ready!(doc, 3)

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#viewer")
    for n <- 1..3, do: assert(has_element?(lv, "#page-#{n}"))
    assert has_element?(lv, "#thumb-3")
    assert has_element?(lv, "#page-1 img[src*='/pages/1/1600']")
  end

  test "shows a processing state, then the pages, live", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#document-processing")

    fake_ready!(doc, 2)
    assert has_element?(lv, "#page-2")
    refute has_element?(lv, "#document-processing")
  end

  test "explains failures and retries", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    version = Documents.get_document(scope, doc.id).latest_version
    Documents.fail_version(version, "password")

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#document-failed")
    assert render(lv) =~ "password-protected"

    lv |> element("#retry-processing") |> render_click()
    assert Documents.get_document(scope, doc.id).latest_version.status == :pending
  end

  test "renames from the title", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

    lv |> element("#document-title") |> render_click()
    lv |> form("#title-form", document: %{title: "Investor update"}) |> render_submit()
    assert has_element?(lv, "#document-title", "Investor update")
  end

  test "lists versions and uploads a new one", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    fake_ready!(doc)

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/versions")
    assert has_element?(lv, "#versions tr", "v1")

    upload =
      file_input(lv, "#version-upload-form", :version, [
        %{name: "v2.docx", content: File.read!(file_path("sample.docx"))}
      ])

    render_upload(upload, "v2.docx")
    assert has_element?(lv, "#versions tr", "v2")
    assert has_element?(lv, "#tab-versions", "2")
  end

  test "restricts the document and adds people", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    colleague = user_fixture(name: "Carla")

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    lv |> element("#visibility-restricted") |> render_click()
    assert Documents.get_document(scope, doc.id).visibility == :restricted
    refute Documents.get_document(Scope.for_user(colleague), doc.id)

    lv
    |> form("#add-member-form", member: %{user_id: colleague.id, role: "viewer"})
    |> render_submit()

    assert has_element?(lv, "#document-member-#{colleague.id}")
    assert Documents.get_document(Scope.for_user(colleague), doc.id)

    lv |> element("#document-member-#{colleague.id} button") |> render_click()
    refute has_element?(lv, "#document-member-#{colleague.id}")
  end

  test "people who can't see a document are sent back", %{conn: conn} do
    owner = Scope.for_user(user_fixture())
    doc = document_fixture(owner)

    {:ok, _} =
      Documents.update_visibility(owner, Documents.get_document(owner, doc.id), :restricted)

    assert {:error, {:live_redirect, %{to: "/documents"}}} = live(conn, ~p"/documents/#{doc.id}")
    assert {:error, {:live_redirect, %{to: "/documents"}}} = live(conn, ~p"/documents/not-a-uuid")
  end

  test "viewers of a workspace document can't change it", %{conn: conn} do
    owner = Scope.for_user(user_fixture())
    doc = document_fixture(owner)

    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
    refute has_element?(lv, "#new-version-button")
    refute has_element?(lv, "#add-member-form")

    render_hook(lv, "set_visibility", %{"visibility" => "restricted"})
    render_hook(lv, "delete", %{})
    assert Documents.get_document(owner, doc.id).visibility == :workspace
  end

  test "deletes and goes back to the list", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

    assert {:error, {:live_redirect, %{to: "/documents"}}} =
             lv |> element("#confirm-delete-document") |> render_click()
  end
end
