defmodule ReadoutWeb.NotificationsComponentTest do
  use ReadoutWeb.ConnCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Phoenix.LiveViewTest
  import Readout.DocumentsFixtures

  alias Readout.Links

  setup :register_and_log_in_user

  test "the bell counts new notifications live and opens the visit", %{conn: conn, scope: scope} do
    {_doc, link} = shared_fixture(scope)
    :ok = Readout.Notifications.mark_all_read(scope)
    {:ok, lv, _} = live(conn, ~p"/documents")
    refute has_element?(lv, "#notifications-unread")

    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit!(link, %{email: "ana@client.com"})

    for job <- all_enqueued(worker: Readout.Notifications.DeliverJob),
        do: perform_job(Readout.Notifications.DeliverJob, job.args)

    assert_push_event(lv, "toast", %{message: _})
    assert has_element?(lv, "#notifications-unread", "1")
    [n | _] = Readout.Notifications.list(scope)
    assert has_element?(lv, "#notification-#{n.id}")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("#notification-#{n.id} button") |> render_click()

    assert to =~ "/analytics?visit=#{visit.id}"
    assert Readout.Notifications.unread_count(scope) == 0
  end

  test "the document bell mutes and follows", %{conn: conn, scope: scope} do
    doc = document_fixture(scope)
    {:ok, lv, _} = live(conn, ~p"/documents/#{doc.id}")
    assert has_element?(lv, "#notify-toggle[aria-pressed=true]")
    lv |> element("#notify-toggle") |> render_click()
    assert has_element?(lv, "#notify-toggle[aria-pressed=false]")
    refute Readout.Notifications.subscribed?(scope, doc)
  end

  test "viewers get a device cookie per link", %{scope: scope} do
    {_doc, link} = shared_fixture(scope)
    conn = get(build_conn(), ~p"/v/#{link.slug}")
    assert %{max_age: _, http_only: true} = conn.resp_cookies["rd_" <> link.slug]
  end
end
