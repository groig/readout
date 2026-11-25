defmodule ReadoutWeb.SheetsViewerTest do
  use ReadoutWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Links, Repo}
  alias Readout.Links.Visit

  @moduletag :tools

  setup do
    scope = Scope.for_user(user_fixture())
    doc = document_fixture(scope, "sample.xlsx")
    version = process!(doc)
    %{scope: scope, doc: Documents.get_document(scope, doc.id), version: version}
  end

  test "spreadsheets are processed into sheets, searchable", %{
    scope: scope,
    doc: doc,
    version: version
  } do
    assert version.status == :ready
    assert version.page_count == 2
    assert [%{"name" => "Revenue"}, %{"name" => "Customers"}] = version.metadata["sheets"]
    assert [_] = Documents.list_documents(scope, query: "Acme")
    _ = doc
  end

  test "the team sees tables with sheet tabs", %{scope: scope, doc: doc} do
    conn = log_in_user(build_conn(), scope.user)
    {:ok, lv, _} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#sheets")
    assert has_element?(lv, "#sheets-tab-2")
    assert render(lv) =~ "Jan"

    lv |> element("#sheets-tab-2") |> render_click()
    assert render(lv) =~ "Acme"
  end

  test "viewers read sheets; time is tracked per sheet", %{scope: scope, doc: doc} do
    {:ok, link} = Links.create_link(scope, doc, %{"name" => "Board"})
    {:ok, viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")
    assert has_element?(viewer, "#sheets")

    viewer |> element("#sheets-tab-2") |> render_click()
    send(viewer.pid, :tick)
    _ = render(viewer)

    visit = Repo.one!(Visit)
    assert visit.pages_viewed == 2
    assert visit.last_page == 2
  end

  test "an open sheet stops serving rows once the link is disabled or expires", %{
    scope: scope,
    doc: doc
  } do
    {:ok, link} = Links.create_link(scope, doc, %{"name" => "Board"})

    for change <- [
          [enabled: false],
          [expires_at: DateTime.add(DateTime.utc_now(:second), -60)]
        ] do
      Repo.update_all(Readout.Links.Link, set: [enabled: true, expires_at: nil])
      {:ok, viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")
      assert has_element?(viewer, "#sheets-tab-2")

      # Changed behind the viewer's back (no broadcast): the next event checks.
      Repo.update_all(Readout.Links.Link, set: change)
      viewer |> element("#sheets-tab-2") |> render_click()
      assert_redirect(viewer, ~p"/v/#{link.slug}")
    end
  end
end
