defmodule ReadoutWeb.DocumentLive.IndexTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Documents

  setup :register_and_log_in_user

  test "shows an empty state with an upload action", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/documents")
    assert has_element?(lv, "#documents-empty")
    assert has_element?(lv, "#upload-button")
    assert has_element?(lv, "#uploader input[type=file]")
  end

  test "lists documents in grid and list views", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    fake_ready!(doc, 4)

    {:ok, lv, _html} = live(conn, ~p"/documents")
    assert has_element?(lv, "#documents-#{doc.id}")
    assert render(lv) =~ "4 pages"

    {:ok, lv, _html} = live(conn, ~p"/documents?view=list")
    assert has_element?(lv, "#documents tr#documents-#{doc.id}")
  end

  test "searches by title", %{conn: conn, scope: scope} do
    a = document_fixture(scope)

    {:ok, _} =
      Documents.rename_document(scope, Documents.get_document(scope, a.id), %{
        "title" => "Board deck"
      })

    b = document_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/documents")
    lv |> form("#document-filters", %{"q" => "board"}) |> render_change()
    assert_patch(lv, ~p"/documents?q=board")
    assert has_element?(lv, "#documents-#{a.id}")
    refute has_element?(lv, "#documents-#{b.id}")
  end

  test "renames inline", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents")

    lv |> element("#documents-#{doc.id}-menu button", "Rename") |> render_click()
    assert has_element?(lv, "#rename-#{doc.id}")

    lv |> form("#rename-#{doc.id}", %{"title" => "Q3 Report"}) |> render_submit()
    refute has_element?(lv, "#rename-#{doc.id}")
    assert Documents.get_document(scope, doc.id).title == "Q3 Report"
  end

  test "deletes after confirming", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/documents")

    lv |> element("#documents-#{doc.id}-menu button", "Delete") |> render_click()
    lv |> element("#confirm-delete-document") |> render_click()
    refute has_element?(lv, "#documents-#{doc.id}")
    refute Documents.get_document(scope, doc.id)
  end

  test "status updates live while processing", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/documents")

    doc = document_fixture(scope)
    assert has_element?(lv, "#documents-#{doc.id}")
    assert render(lv) =~ "Queued"

    fake_ready!(doc, 2)
    refute render(lv) =~ "Queued"
    assert render(lv) =~ "2 pages"
  end

  test "others' documents show no edit actions", %{conn: conn} do
    other = Readout.Accounts.Scope.for_user(user_fixture())
    doc = document_fixture(other)
    {:ok, lv, _html} = live(conn, ~p"/documents")
    assert has_element?(lv, "#documents-#{doc.id}")
    refute has_element?(lv, "#documents-#{doc.id}-menu button", "Rename")

    render_hook(lv, "save_rename", %{"id" => doc.id, "title" => "Hijacked"})
    refute Documents.get_document(other, doc.id).title == "Hijacked"
  end

  test "uploads through the shell uploader and tracks status", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/documents")

    upload =
      file_input(lv, "#upload-form", :document, [
        %{
          name: "Q3 Report.pdf",
          content: File.read!(file_path("sample.pdf")),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "Q3 Report.pdf")

    assert has_element?(lv, "#upload-tray")

    assert [%{title: "Q3 Report"} = doc] =
             Documents.list_documents(
               Readout.Accounts.Scope.for_user(Readout.Repo.one!(Readout.Accounts.User))
             )

    assert has_element?(lv, "#upload-recent-#{doc.id}")
    assert has_element?(lv, "#documents-#{doc.id}")
  end

  test "rejects files that aren't documents", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/documents")

    upload =
      file_input(lv, "#upload-form", :document, [
        %{name: "fake.pdf", content: "not a pdf", type: "application/pdf"}
      ])

    render_upload(upload, "fake.pdf")
    assert render(lv) =~ "Only PDF, Word, PowerPoint"
  end

  test "observers get no upload controls", %{conn: _conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: build_conn(), role: :observer})
    {:ok, lv, _html} = live(conn, ~p"/documents")
    refute has_element?(lv, "#upload-button")
    refute has_element?(lv, "#uploader")
  end
end
