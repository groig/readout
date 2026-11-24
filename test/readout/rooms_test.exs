defmodule Readout.RoomsTest do
  use Readout.DataCase, async: true

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Analytics, Documents, Links, Policy, Rooms}

  setup do
    scope = Scope.for_user(user_fixture())

    {:ok, room} =
      Rooms.create_room(scope, %{"name" => "Series A", "description" => "Due diligence"})

    docs =
      for title <- ["Deck", "Financials", "Cap table"] do
        doc = document_fixture(scope)
        fake_ready!(doc, 2)

        {:ok, doc} =
          Documents.rename_document(scope, Documents.get_document(scope, doc.id), %{
            "title" => title
          })

        Documents.get_document(scope, doc.id)
      end

    %{scope: scope, room: room, docs: docs}
  end

  defp add_all(scope, room, docs) do
    for d <- docs, do: {:ok, _} = Rooms.add_document(scope, room, d)
    Rooms.get_room(scope, room.id)
  end

  test "documents keep their order and can be moved and removed", %{
    scope: scope,
    room: room,
    docs: docs
  } do
    room = add_all(scope, room, docs)
    assert Enum.map(room.documents, & &1.title) == ["Deck", "Financials", "Cap table"]

    [deck, fin, _cap] = docs
    :ok = Rooms.move_document(scope, room, fin.id, :up)

    assert Enum.map(Rooms.get_room(scope, room.id).documents, & &1.title) == [
             "Financials",
             "Deck",
             "Cap table"
           ]

    :ok = Rooms.remove_document(scope, room, deck.id)

    assert Enum.map(Rooms.get_room(scope, room.id).documents, & &1.title) == [
             "Financials",
             "Cap table"
           ]
  end

  test "you can only add documents you could share yourself", %{room: room} do
    other = Scope.for_user(user_fixture())
    foreign = document_fixture(other)
    owner_scope = Scope.for_user(Readout.Repo.get!(Readout.Accounts.User, room.owner_id))

    assert {:error, :unauthorized} =
             Rooms.add_document(
               owner_scope,
               room,
               Documents.get_document(owner_scope, foreign.id)
             )
  end

  test "deleted documents leave the room; deleted rooms disappear", %{
    scope: scope,
    room: room,
    docs: [deck | _] = docs
  } do
    room = add_all(scope, room, docs)
    {:ok, _} = Documents.delete_document(scope, deck)
    assert length(Rooms.get_room(scope, room.id).documents) == 2

    {:ok, _} = Rooms.delete_room(scope, room)
    refute Rooms.get_room(scope, room.id)
    assert Rooms.list_rooms(scope) == []
  end

  test "room policy" do
    s = fn role ->
      Scope.for_user(%Readout.Accounts.User{id: Ecto.UUID.generate(), role: role})
    end

    room = %Readout.Rooms.Room{owner_id: Ecto.UUID.generate(), visibility: :restricted}

    assert Policy.can?(s.(:admin), :view_room, room)
    refute Policy.can?(s.(:member), :view_room, room)
    assert Policy.can?(s.(:member), :view_room, %{room | visibility: :workspace})
    refute Policy.can?(s.(:member), :edit_room, %{room | visibility: :workspace})
    refute Policy.can?(s.(:observer), :create_room, :workspace)

    %Scope{user: me} = mine = s.(:member)
    assert Policy.can?(mine, :manage_room, %{room | owner_id: me.id})

    refute Policy.can?(%Scope{user: %{me | role: :observer}}, :edit_room, %{
             room
             | owner_id: me.id
           })
  end

  test "room links open the ready documents; analytics roll up", %{
    scope: scope,
    room: room,
    docs: docs
  } do
    room = add_all(scope, room, docs)
    {:ok, link} = Links.create_link(scope, room, %{"name" => "Investors"})
    {:ok, link} = Links.fetch_public_link(link.slug)
    assert link.room.name == "Series A"
    assert length(link.room.documents) == 3

    [deck, fin | _] = link.room.documents
    v1 = Links.start_visit(link, %{document: deck, email: "a@vc.com"})
    v2 = Links.start_visit(link, %{document: fin, email: "a@vc.com"})
    assert v1.document_id == deck.id and v2.document_id == fin.id
    Analytics.record(v1, %{1 => 10_000}, %{1 => 1}, 1)

    overview = Analytics.room_overview(scope, Rooms.get_room(scope, room.id))
    assert overview.totals.visits == 2
    assert overview.totals.unique == 1
    assert [%{title: "Deck", visits: 1, avg_ms: 10_000} | _] = overview.per_document

    # The document's own analytics show the room link.
    assert [%{name: "Investors", visits: 1}] =
             Analytics.per_link(scope, Documents.get_document(scope, deck.id))
  end

  test "empty rooms aren't viewable yet", %{scope: scope, room: room} do
    {:ok, link} = Links.create_link(scope, room, %{"name" => "Early"})
    assert {:error, :not_ready} = Links.fetch_public_link(link.slug)
  end
end
