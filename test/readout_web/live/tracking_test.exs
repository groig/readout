defmodule ReadoutWeb.TrackingTest do
  @moduledoc "The viewer reports pages; the dashboards update live."
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Repo
  alias Readout.Links.Visit
  alias ReadoutWeb.Presence

  setup do
    scope = Scope.for_user(user_fixture())
    {doc, link} = shared_fixture(scope)
    %{scope: scope, doc: doc, link: link}
  end

  test "pages reported by the viewer become page views; closing ends the visit", %{
    doc: doc,
    link: link
  } do
    {:ok, viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")

    render_hook(viewer, "page", %{"page" => 1})
    render_hook(viewer, "page", %{"page" => 2})
    render_hook(viewer, "page", %{"page" => 99})

    assert [%{page: 2}] = Presence.readers(doc.id)

    send(viewer.pid, :tick)
    _ = render(viewer)

    visit = Repo.one!(Visit)
    assert visit.pages_viewed == 2
    assert visit.last_page == 2
    assert visit.page_count == 3

    ref = Process.monitor(viewer.pid)
    GenServer.stop(viewer.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert Repo.one!(Visit).ended_at
  end

  test "the document dashboard shows readers and visits live", %{
    conn: conn,
    scope: scope,
    doc: doc,
    link: link
  } do
    conn = log_in_user(conn, scope.user)
    {:ok, dash, _} = live(conn, ~p"/documents/#{doc.id}/analytics")
    assert has_element?(dash, "#reading-now")
    refute has_element?(dash, "[id^='reader-']")

    {:ok, viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")
    render_hook(viewer, "page", %{"page" => 3})

    visit = Repo.one!(Visit)
    assert render(dash) =~ "p. 3/3"
    assert has_element?(dash, "#reader-#{visit.id}")
    assert has_element?(dash, "#visits-#{visit.id}")

    dash |> element("#visits-#{visit.id} td:first-child") |> render_click()
    assert has_element?(dash, "#visit-sheet")
  end

  test "the workspace feed shows new visits, only for visible documents", %{
    conn: conn,
    scope: scope,
    link: link
  } do
    {:ok, feed, _} = live(log_in_user(conn, scope.user), ~p"/analytics")
    {:ok, _viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")
    visit = Repo.one!(Visit)
    assert has_element?(feed, "#activity-#{visit.id}")
    assert has_element?(feed, "#ws-reader-#{visit.id}")

    # Someone else's restricted document never shows up.
    other = Scope.for_user(user_fixture())
    {other_doc, other_link} = shared_fixture(other)

    {:ok, _} =
      Readout.Documents.update_visibility(
        other,
        Readout.Documents.get_document(other, other_doc.id),
        :restricted
      )

    {:ok, _viewer, _} = live(build_conn(), ~p"/v/#{other_link.slug}")
    hidden = Repo.get_by!(Visit, link_id: other_link.id)
    refute has_element?(feed, "#activity-#{hidden.id}")
    refute has_element?(feed, "#ws-reader-#{hidden.id}")
  end

  test "people who can't see a document can't open its analytics", %{
    conn: conn,
    scope: scope,
    doc: doc
  } do
    {:ok, _} = Readout.Documents.update_visibility(scope, doc, :restricted)
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:live_redirect, %{to: "/documents"}}} =
             live(conn, ~p"/documents/#{doc.id}/analytics")
  end
end
