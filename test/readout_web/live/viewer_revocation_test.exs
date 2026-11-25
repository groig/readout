defmodule ReadoutWeb.ViewerRevocationTest do
  @moduledoc """
  Withdrawing access stops further reads: old page URLs, open viewers and
  grants issued under rules that have since changed.
  """
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Links, Rooms, Storage}
  alias Readout.Documents.Version
  alias Readout.Links.Link
  alias ReadoutWeb.ViewerAccess

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  defp ready_doc(scope) do
    doc = document_fixture(scope)
    version = fake_ready!(doc, 2)
    :ok = Storage.put_file(Version.page_key(version, 1, 1600), file_path("sample.pdf"))
    Documents.get_document(scope, doc.id)
  end

  defp page_url(link, token), do: ~p"/v/#{link.slug}/p/#{token}/1/1600"

  describe "page URLs" do
    test "stop working when the document leaves the room", %{conn: conn, scope: scope} do
      [deck, fin] = [ready_doc(scope), ready_doc(scope)]
      {:ok, room} = Rooms.create_room(scope, %{"name" => "Pack"})
      for d <- [deck, fin], do: {:ok, _} = Rooms.add_document(scope, room, d)
      {:ok, link} = Links.create_link(scope, room, %{"name" => "VC"})
      {:ok, link} = Links.fetch_public_link(link.slug)

      visit = Links.start_visit!(link, %{document: deck})
      token = ViewerAccess.sign_visit(visit.id, link.access_revision)
      assert response(get(conn, page_url(link, token)), 200)

      :ok = Rooms.remove_document(scope, room, deck.id)
      assert response(get(build_conn(), page_url(link, token)), 404)
    end

    test "stop working when the link's rules change, even in the same second", %{
      conn: conn,
      scope: scope
    } do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X"})
      {:ok, link} = Links.fetch_public_link(link.slug)
      visit = Links.start_visit!(link, %{})
      token = ViewerAccess.sign_visit(visit.id, link.access_revision)
      assert response(get(conn, page_url(link, token)), 200)

      # A rename isn't an access change.
      {:ok, link} = Links.update_link(scope, doc, link, %{"name" => "Y"})
      assert response(get(build_conn(), page_url(link, token)), 200)

      {:ok, _} = Links.update_link(scope, doc, link, %{"password" => "secret1"})
      assert response(get(build_conn(), page_url(link, token)), 404)
    end

    test "stop working for an old version once a new one is current", %{
      conn: conn,
      scope: scope
    } do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X"})
      {:ok, link} = Links.fetch_public_link(link.slug)
      visit = Links.start_visit!(link, %{})
      token = ViewerAccess.sign_visit(visit.id, link.access_revision)

      {:ok, _} = Documents.add_version(scope, doc, upload("sample.pdf"))
      fake_ready!(doc, 2)
      assert response(get(conn, page_url(link, token)), 404)
    end
  end

  describe "open viewers" do
    test "a room reader can't open a document removed from the room", %{
      conn: conn,
      scope: scope
    } do
      [deck, fin] = [ready_doc(scope), ready_doc(scope)]
      {:ok, room} = Rooms.create_room(scope, %{"name" => "Pack"})
      for d <- [deck, fin], do: {:ok, _} = Rooms.add_document(scope, room, d)
      {:ok, link} = Links.create_link(scope, room, %{"name" => "VC"})

      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
      assert has_element?(lv, "#room-doc-#{deck.id}")

      :ok = Rooms.remove_document(scope, room, deck.id)
      # The index updates from the room event...
      refute has_element?(lv, "#room-doc-#{deck.id}")
      # ...and the stale URL goes back to the index.
      render_patch(lv, ~p"/v/#{link.slug}/d/#{deck.id}")
      refute has_element?(lv, "#viewer")
    end

    test "a reader is sent away when the document leaves the room", %{
      conn: conn,
      scope: scope
    } do
      [deck, fin] = [ready_doc(scope), ready_doc(scope)]
      {:ok, room} = Rooms.create_room(scope, %{"name" => "Pack"})
      for d <- [deck, fin], do: {:ok, _} = Rooms.add_document(scope, room, d)
      {:ok, link} = Links.create_link(scope, room, %{"name" => "VC"})

      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}/d/#{deck.id}")
      assert has_element?(lv, "#viewer")

      :ok = Rooms.remove_document(scope, room, deck.id)
      assert_redirect(lv, ~p"/v/#{link.slug}/d/#{deck.id}")
    end

    test "disabling the link reloads an open viewer", %{conn: conn, scope: scope} do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X"})
      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
      assert has_element?(lv, "#viewer")

      {:ok, _} = Links.set_enabled(scope, doc, link, false)
      assert_redirect(lv, ~p"/v/#{link.slug}")
    end

    test "an expired link is noticed on the next tick", %{conn: conn, scope: scope} do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X"})
      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")

      Readout.Repo.update_all(Link, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])
      send(lv.pid, :tick)
      assert_redirect(lv, ~p"/v/#{link.slug}")
    end
  end

  describe "gates and grants" do
    test "an open gate reloads when the rules change", %{conn: conn, scope: scope} do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X", "password" => "oldpass"})
      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")

      {:ok, _} = Links.update_link(scope, doc, link, %{"password" => "newpass"})
      assert_redirect(lv, ~p"/v/#{link.slug}")
    end

    test "a grant issued before a change can't be redeemed", %{conn: conn, scope: scope} do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X", "password" => "oldpass"})
      {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
      lv |> form("#gate-form", gate: %{password: "oldpass"}) |> render_submit()

      [grant] =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#access-form input[name=grant]")
        |> LazyHTML.attribute("value")

      {:ok, _} = Links.update_link(scope, doc, link, %{"password" => "newpass"})

      conn = post(conn, ~p"/v/#{link.slug}/access", %{"grant" => grant})
      {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
      assert has_element?(lv, "#gate-form")
      refute has_element?(lv, "#viewer")
    end
  end

  describe "viewer limits" do
    test "two new readers racing for the last slot: exactly one gets in", %{scope: scope} do
      doc = ready_doc(scope)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "X", "one_time" => "true"})
      {:ok, link} = Links.fetch_public_link(link.slug)

      results =
        ["dev-a", "dev-b"]
        |> Enum.map(fn device ->
          Task.async(fn -> Links.start_visit(link, %{device_id: device}) end)
        end)
        |> Task.await_many()

      assert [{:error, :used_up}, {:ok, _}] = Enum.sort_by(results, &elem(&1, 0))

      # The one who got in can come back.
      {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
      assert {:ok, _} = Links.start_visit(link, %{device_id: winner.device_id})
    end
  end
end
