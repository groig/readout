defmodule Readout.AnalyticsTest do
  use Readout.DataCase, async: true

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Analytics, Documents, Links, Repo}
  alias Readout.Links.Visit

  setup do
    scope = Scope.for_user(user_fixture())
    {doc, link} = shared_fixture(scope)
    {:ok, other_link} = Links.create_link(scope, doc, %{"name" => "Investors"})
    {:ok, link} = Links.fetch_public_link(link.slug)
    {:ok, other_link} = Links.fetch_public_link(other_link.slug)
    %{scope: scope, doc: Documents.get_document(scope, doc.id), link: link, other: other_link}
  end

  # A visit reading `pages` (%{page => seconds}).
  defp read(link, attrs, pages, started_ago_days \\ 0) do
    visit = Links.start_visit!(link, attrs)

    started = DateTime.add(DateTime.utc_now(), -started_ago_days, :day)
    visit = visit |> Ecto.Changeset.change(started_at: started) |> Repo.update!()

    ms = Map.new(pages, fn {p, s} -> {p, s * 1000} end)
    views = Map.new(pages, fn {p, _} -> {p, 1} end)
    Analytics.record(visit, ms, views, pages |> Map.keys() |> Enum.max(fn -> nil end))
  end

  test "record/4 keeps page views and visit totals", %{link: link} do
    visit = read(link, %{email: "a@x.com"}, %{1 => 10, 2 => 5})
    visit = Analytics.record(visit, %{2 => 3_000}, %{2 => 1}, 2)

    assert visit.duration_ms == 18_000
    assert visit.pages_viewed == 2
    assert visit.last_page == 2
    pv = Repo.get_by!(Readout.Analytics.PageView, visit_id: visit.id, page: 2)
    assert pv.duration_ms == 8_000
    assert pv.views == 2
  end

  test "overview: visits, unique viewers, average time, completion, deltas", %{
    scope: scope,
    doc: doc,
    link: link
  } do
    read(link, %{email: "ana@x.com"}, %{1 => 10, 2 => 10, 3 => 10})
    read(link, %{email: "ana@x.com"}, %{1 => 20})
    read(link, %{ip: "9.9.9.9"}, %{1 => 30})
    read(link, %{email: "old@x.com"}, %{1 => 5}, 10)

    o = Analytics.overview(scope, doc, range: "7d")
    assert o.visits == 3
    assert o.unique == 2
    assert o.avg_ms == 26_666
    assert_in_delta o.completion, 33.3, 0.1
    assert o.deltas.visits == 200.0
    assert length(o.series) == 7
    assert List.last(o.series) == 3

    assert Analytics.overview(scope, doc, range: "all").visits == 4
  end

  test "time per page shows attention and reach", %{scope: scope, doc: doc, link: link} do
    read(link, %{}, %{1 => 20, 2 => 10, 3 => 4})
    read(link, %{}, %{1 => 10})

    assert [
             %{page: 1, avg_ms: 15_000, reach: 100.0},
             %{page: 2, avg_ms: 5_000, reach: 50.0},
             %{page: 3, avg_ms: 2_000, reach: 50.0}
           ] = Analytics.time_per_page(scope, doc, doc.current_version, range: "30d")
  end

  test "per link and viewers", %{scope: scope, doc: doc, link: link, other: other} do
    read(link, %{email: "ana@x.com", email_verified: true}, %{1 => 10})
    read(link, %{email: "ana@x.com"}, %{1 => 20})
    read(other, %{ip: "1.2.3.4"}, %{1 => 6})

    assert [
             %{name: "Client X", visits: 2, unique: 1, avg_ms: 15_000},
             %{name: "Investors", visits: 1}
           ] =
             Analytics.per_link(scope, doc)

    viewers = Analytics.viewers(scope, doc)
    ana = Enum.find(viewers, &(&1.email == "ana@x.com"))
    assert ana.visits == 2 and ana.total_ms == 30_000 and ana.verified
    assert Enum.find(viewers, &(&1.key == "ip:1.2.3.4"))

    assert [_] = Analytics.recent_visits(scope, doc, viewer: "ip:1.2.3.4")
    assert [_, _] = Analytics.recent_visits(scope, doc, viewer: "ana@x.com")
  end

  test "a visit's timeline, only for people who can see the document", %{
    scope: scope,
    doc: doc,
    link: link
  } do
    visit = read(link, %{}, %{2 => 4, 1 => 3})
    assert %Visit{page_views: [_, _]} = Analytics.get_visit(scope, visit.id)

    {:ok, _} = Documents.update_visibility(scope, doc, :restricted)
    refute Analytics.get_visit(Scope.for_user(user_fixture()), visit.id)
  end

  test "analytics follow document visibility", %{scope: scope, doc: doc, link: link} do
    read(link, %{}, %{1 => 3})
    {:ok, _} = Documents.update_visibility(scope, doc, :restricted)
    stranger = Scope.for_user(user_fixture())

    overview = Analytics.workspace_overview(stranger)
    assert overview.totals.visits == 0
    assert Analytics.recent_activity(stranger, overview.document_ids) == []

    mine = Analytics.workspace_overview(scope)
    assert mine.totals.visits == 1
    assert [%{title: _}] = mine.top_documents

    restricted = Documents.get_document(scope, doc.id)
    assert_raise ArgumentError, fn -> Analytics.overview(stranger, restricted) end
  end

  test "visits broadcast to subscribers", %{scope: scope, doc: doc, link: link} do
    Analytics.subscribe_document(scope, doc)
    visit = Links.start_visit!(link, %{})
    assert_receive {:analytics, :visit_started, %{visit_id: id}} when id == visit.id
    Links.end_visit(visit)
    assert_receive {:analytics, :visit_ended, _}
  end
end
