defmodule Readout.NotificationsTest do
  use Readout.DataCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Analytics, Documents, Links, Notifications}
  alias Readout.Notifications.DeliverJob

  setup do
    owner = user_fixture(name: "Alex")
    scope = Scope.for_user(owner)
    {doc, link} = shared_fixture(scope)
    {:ok, link} = Links.fetch_public_link(link.slug)
    %{owner: owner, scope: scope, doc: doc, link: link}
  end

  # Visit notifications only (the fixtures also produce "version ready" ones).
  defp visits(scope),
    do: Enum.filter(Notifications.list(scope), &String.starts_with?(&1.kind, "visit_"))

  # Runs the queued delivery jobs once (manual testing mode keeps them queued).
  defp deliver_all do
    for job <- all_enqueued(worker: DeliverJob) do
      :ok = perform_job(DeliverJob, job.args)
      Readout.Repo.delete!(job)
    end
  end

  test "you follow your own documents by default, and can mute them", %{scope: scope, doc: doc} do
    assert Notifications.subscribed?(scope, doc)
    {:ok, _} = Notifications.set_subscription(scope, doc, false)
    refute Notifications.subscribed?(scope, doc)
  end

  test "the profile switch turns the default off", %{doc: doc} do
    quiet = user_fixture(notifications_enabled: false)
    refute Notifications.subscribed?(Scope.for_user(quiet), doc)
  end

  test "followers must be able to see the document", %{scope: scope, owner: owner, doc: doc} do
    colleague = user_fixture()
    {:ok, _} = Notifications.set_subscription(Scope.for_user(colleague), doc, true)

    assert doc |> Notifications.followers() |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([owner.id, colleague.id])

    {:ok, _} = Documents.update_visibility(scope, doc, :restricted)

    assert Enum.map(Notifications.followers(Documents.get_document(scope, doc.id)), & &1.id) == [
             owner.id
           ]
  end

  test "opening and finishing a visit notify followers, live", %{scope: scope, link: link} do
    Notifications.subscribe(scope)
    visit = Links.start_visit(link, %{email: "ana@client.com", email_verified: true})
    deliver_all()

    assert_receive {:notification, _id}

    assert [%{kind: "visit_opened", data: %{"email" => "ana@client.com", "link" => "Client X"}}] =
             visits(scope)

    assert Notifications.unread_count(scope) == 2

    Analytics.record(visit, %{1 => 30_000, 2 => 90_000}, %{1 => 1, 2 => 1}, 2)
    :ok = Links.end_visit(visit)
    deliver_all()

    assert [%{kind: "visit_finished", data: %{"pages_viewed" => 2, "top_page" => 2}} | _] =
             visits(scope)

    :ok = Notifications.mark_all_read(scope)
    assert Notifications.unread_count(scope) == 0
  end

  test "an empty visit sends no summary", %{scope: scope, link: link} do
    visit = Links.start_visit(link, %{})
    :ok = Links.end_visit(visit)
    deliver_all()
    assert Enum.map(visits(scope), & &1.kind) == ["visit_opened"]
  end

  test "muted documents stay quiet", %{scope: scope, doc: doc, link: link} do
    {:ok, _} = Notifications.set_subscription(scope, doc, false)
    _ = Links.start_visit(link, %{})
    deliver_all()
    assert visits(scope) == []
  end

  test "uploaders hear when processing is done or failed", %{scope: scope} do
    doc = document_fixture(scope)
    version = Documents.get_document(scope, doc.id).latest_version
    Documents.fail_version(version, "password")

    assert [%{kind: "version_failed", data: %{"error" => "password"}} | _] =
             Notifications.list(scope)
  end

  test "notifications read well in each person's language", %{scope: scope, link: link} do
    _ = Links.start_visit(link, %{email: "ana@client.com", email_verified: true})
    deliver_all()
    [n] = visits(scope)

    assert ReadoutWeb.NotificationLabels.text(n, "en") =~
             "ana@client.com (verified) opened «sample» via «Client X»"

    Gettext.put_locale(ReadoutWeb.Gettext, "es")
    assert ReadoutWeb.NotificationLabels.text(n, "es") =~ "abrió «sample»"
  end

  test "anonymous viewers count by device, not by IP", %{scope: scope, doc: doc, link: link} do
    Links.start_visit(link, %{ip: "1.2.3.4", device_id: "device-one-aaaaaaa"})
    Links.start_visit(link, %{ip: "1.2.3.4", device_id: "device-two-bbbbbbb"})
    Links.start_visit(link, %{ip: "1.2.3.4", device_id: "device-two-bbbbbbb"})

    assert Analytics.overview(scope, doc).unique == 2
    assert [_, _] = Analytics.viewers(scope, doc)
    assert [_, _] = Analytics.recent_visits(scope, doc, viewer: "dev:device-two-bbbbbbb")
  end
end
