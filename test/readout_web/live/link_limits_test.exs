defmodule ReadoutWeb.LinkLimitsTest do
  use ReadoutWeb.ConnCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Links, Notifications, Repo}
  alias Readout.Links.{Link, Visit}

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  describe "settings" do
    test "one-time is a limit of one; turning it off clears it", %{scope: scope} do
      {doc, link} = shared_fixture(scope, %{"one_time" => "true"})
      assert link.max_viewers == 1
      assert Link.one_time?(link)

      {:ok, link} = Links.update_link(scope, doc, link, %{"one_time" => "false"})
      assert link.max_viewers == nil

      {:ok, link} = Links.update_link(scope, doc, link, %{"max_viewers" => "5"})
      assert link.max_viewers == 5
      refute Link.one_time?(link)
      assert {:error, _} = Links.update_link(scope, doc, link, %{"max_viewers" => "0"})
    end
  end

  describe "one-time links" do
    test "the first device reads, returns, and nobody else gets in", %{conn: conn, scope: scope} do
      {_doc, link} = shared_fixture(scope, %{"one_time" => "true"})

      # The first device opens it and can come back (same session cookie).
      conn = get(conn, ~p"/v/#{link.slug}")
      {:ok, lv, _} = live(conn)
      assert has_element?(lv, "#viewer")
      {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
      assert has_element?(lv, "#viewer")

      # Another device is turned away.
      {:ok, other, _} = live(build_conn(), ~p"/v/#{link.slug}")
      refute has_element?(other, "#viewer")
      assert render(other) =~ "already been used"

      assert Links.viewer_count(link) == 1
    end

    test "a gated link checks the limit after the email", %{conn: conn, scope: scope} do
      {_doc, link} = shared_fixture(scope, %{"max_viewers" => "2", "require_email" => "true"})

      for email <- ["a@x.com", "b@x.com"] do
        assert {:ok, lv} = pass_gate(link, email)
        assert has_element?(lv, "#viewer")
      end

      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
      html = lv |> form("#gate-form", gate: %{email: "c@x.com"}) |> render_submit()
      assert html =~ "already been opened"
      refute has_element?(lv, "#viewer")

      # A known reader on a new device still gets in.
      assert {:ok, lv} = pass_gate(link, "a@x.com")
      assert has_element?(lv, "#viewer")
    end
  end

  defp pass_gate(link, email) do
    conn = build_conn()
    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    lv |> form("#gate-form", gate: %{email: email}) |> render_submit()
    conn = follow_trigger_action(form(lv, "#access-form"), conn)
    {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
    {:ok, lv}
  end

  describe "notify on first open only" do
    test "repeat visits by the same viewer don't notify", %{scope: scope} do
      {doc, link} = shared_fixture(scope, %{"notify_first_only" => "true"})
      Notifications.mark_all_read(scope)
      {:ok, link} = Links.fetch_public_link(link.slug)

      first = Links.start_visit!(link, %{device_id: "dev-1"})
      Process.sleep(5)
      again = Links.start_visit!(link, %{device_id: "dev-1"})
      other = Links.start_visit!(link, %{device_id: "dev-2"})

      assert Links.first_visit?(first)
      refute Links.first_visit?(again)
      assert Links.first_visit?(other)

      for visit <- [first, again, other] do
        perform_job(Readout.Notifications.DeliverJob, %{
          "visit_id" => visit.id,
          "kind" => "visit_started"
        })
      end

      visit_ids =
        scope
        |> Notifications.list()
        |> Enum.filter(&(&1.kind == "visit_started" and &1.document_id == doc.id))
        |> Enum.map(& &1.visit_id)
        |> Enum.sort()

      assert visit_ids == Enum.sort([first.id, other.id])
      assert Repo.aggregate(Visit, :count) == 3
    end
  end
end
