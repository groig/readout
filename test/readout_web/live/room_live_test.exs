defmodule ReadoutWeb.RoomLiveTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.DocumentsFixtures

  alias Readout.{Documents, Links, Repo, Rooms}
  alias Readout.Links.Visit

  setup :register_and_log_in_user

  setup %{scope: scope} do
    docs =
      for title <- ["Deck", "Financials"] do
        doc = document_fixture(scope)
        fake_ready!(doc, 2)

        {:ok, doc} =
          Documents.rename_document(scope, Documents.get_document(scope, doc.id), %{
            "title" => title
          })

        Documents.get_document(scope, doc.id)
      end

    %{docs: docs}
  end

  test "creates a room, adds documents and shares it", %{
    conn: conn,
    scope: scope,
    docs: [deck, fin]
  } do
    {:ok, lv, _} = live(conn, ~p"/rooms")
    assert has_element?(lv, "#rooms-empty")
    lv |> element("#new-room-button") |> render_click()

    {:error, {:live_redirect, %{to: "/rooms/" <> id}}} =
      lv |> form("#room-form", room: %{name: "Board pack"}) |> render_submit()

    {:ok, lv, _} = live(conn, ~p"/rooms/#{id}")
    lv |> element("#add-documents") |> render_click()
    lv |> element("#candidate-#{deck.id} button") |> render_click()
    lv |> element("#candidate-#{fin.id} button") |> render_click()
    assert has_element?(lv, "#room-document-#{deck.id}")
    assert has_element?(lv, "#room-document-#{fin.id}")

    lv |> element("#share-room") |> render_click()
    lv |> form("#link-form", link: %{name: "Board"}) |> render_submit()
    assert_patch(lv, ~p"/rooms/#{id}/links")
    assert [%{name: "Board"}] = Links.list_links(scope, Rooms.get_room(scope, id))
  end

  test "viewers browse the room, and each document is its own visit", %{
    scope: scope,
    docs: [deck, fin]
  } do
    {:ok, room} = Rooms.create_room(scope, %{"name" => "Board pack"})
    for d <- [deck, fin], do: {:ok, _} = Rooms.add_document(scope, room, d)
    {:ok, link} = Links.create_link(scope, room, %{"name" => "Board"})

    {:ok, viewer, _} = live(build_conn(), ~p"/v/#{link.slug}")
    assert has_element?(viewer, "#room-index")
    assert has_element?(viewer, "#room-doc-#{deck.id}")

    viewer |> element("#room-doc-#{deck.id} a") |> render_click()
    assert_patch(viewer, ~p"/v/#{link.slug}/d/#{deck.id}")
    assert has_element?(viewer, "#viewer")
    first = Repo.get_by!(Visit, document_id: deck.id)

    viewer |> element("#back-to-room") |> render_click()
    assert Repo.reload!(first).ended_at

    viewer |> element("#room-doc-#{fin.id} a") |> render_click()
    assert Repo.get_by!(Visit, document_id: fin.id)
  end

  test "documents outside the room can't be opened through it", %{scope: scope, docs: [deck, fin]} do
    {:ok, room} = Rooms.create_room(scope, %{"name" => "Only the deck"})
    {:ok, _} = Rooms.add_document(scope, room, deck)
    {:ok, link} = Links.create_link(scope, room, %{"name" => "x"})

    # Sent back to the room's index.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(build_conn(), ~p"/v/#{link.slug}/d/#{fin.id}")

    assert to == ~p"/v/#{link.slug}"
    refute Repo.get_by(Visit, document_id: fin.id)
  end

  test "the analytics tab rolls up visits", %{conn: conn, scope: scope, docs: [deck | _]} do
    {:ok, room} = Rooms.create_room(scope, %{"name" => "Pack"})
    {:ok, _} = Rooms.add_document(scope, room, deck)
    {:ok, link} = Links.create_link(scope, room, %{"name" => "x"})
    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit!(link, %{document: hd(link.room.documents), email: "a@b.com"})

    {:ok, lv, _} = live(conn, ~p"/rooms/#{room.id}/analytics")
    assert has_element?(lv, "#room-visit-#{visit.id}")
  end
end
