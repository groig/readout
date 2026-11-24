defmodule Readout.Rooms do
  @moduledoc """
  Data rooms: several documents behind one link.

  A room keeps its documents in order. Adding a document needs both
  `:edit_room` and `:edit_document` on it, so a room can't share a document
  its editor couldn't share directly. Deleted documents disappear from rooms;
  documents without a ready version are hidden from viewers until processed.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.Scope
  alias Readout.Documents.Document
  alias Readout.Links.Link
  alias Readout.Rooms.{Room, RoomDocument}
  alias Readout.{Audit, Policy, Repo}

  @topic "rooms"

  def subscribe(%Scope{}), do: Phoenix.PubSub.subscribe(Readout.PubSub, @topic)

  defp broadcast(%Room{id: id}),
    do: Phoenix.PubSub.broadcast(Readout.PubSub, @topic, {:room_updated, id})

  ## Reading

  @doc "Rooms the scope can see, most recently updated first."
  def list_rooms(%Scope{user: user} = scope) do
    query = from(r in Room, where: is_nil(r.deleted_at), order_by: [desc: r.updated_at])

    query =
      if Policy.can?(scope, :manage_members, :workspace),
        do: query,
        else: where(query, [r], r.visibility == :workspace or r.owner_id == ^user.id)

    rooms = query |> preload(:owner) |> Repo.all()
    ids = Enum.map(rooms, & &1.id)

    counts =
      from(l in Link,
        where: l.room_id in ^ids and l.enabled,
        group_by: l.room_id,
        select: {l.room_id, count(l.id)}
      )
      |> Repo.all()
      |> Map.new()

    rooms
    |> Enum.map(&%{&1 | link_count: Map.get(counts, &1.id, 0)})
    |> put_documents()
  end

  @doc "A room the scope can see, with its documents in order, or nil."
  def get_room(%Scope{} = scope, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %Room{} = room <- Repo.one(from r in Room, where: r.id == ^id and is_nil(r.deleted_at)),
         true <- Policy.can?(scope, :view_room, room) do
      room |> Repo.preload(:owner) |> List.wrap() |> put_documents() |> hd()
    else
      _ -> nil
    end
  end

  @doc false
  # Fills `documents` (live documents in order, with their current version).
  def put_documents([]), do: []

  def put_documents(rooms) do
    ids = Enum.map(rooms, & &1.id)

    rows =
      from(rd in RoomDocument,
        join: d in assoc(rd, :document),
        where: rd.room_id in ^ids and is_nil(d.deleted_at),
        order_by: [asc: rd.position],
        preload: [document: {d, [:current_version, :members]}]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.room_id, & &1.document)

    Enum.map(rooms, &%{&1 | documents: Map.get(rows, &1.id, [])})
  end

  ## Changing

  def change_room(%Room{} = room, attrs \\ %{}), do: Room.changeset(room, attrs)

  def create_room(%Scope{user: user} = scope, attrs) do
    with :ok <- Policy.authorize(scope, :create_room, :workspace),
         {:ok, room} <- %Room{owner_id: user.id} |> Room.changeset(attrs) |> Repo.insert() do
      Audit.log(scope, "room.created", room)
      broadcast(room)
      {:ok, %{room | documents: []}}
    end
  end

  def update_room(%Scope{} = scope, %Room{} = room, attrs) do
    changeset = Room.changeset(room, attrs)

    action =
      if Ecto.Changeset.get_change(changeset, :visibility), do: :manage_room, else: :edit_room

    with :ok <- Policy.authorize(scope, action, room),
         {:ok, updated} <- Repo.update(changeset) do
      broadcast(updated)
      {:ok, %{updated | documents: room.documents}}
    end
  end

  def delete_room(%Scope{} = scope, %Room{} = room) do
    with :ok <- Policy.authorize(scope, :manage_room, room),
         {:ok, room} <-
           room |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second)) |> Repo.update() do
      Audit.log(scope, "room.deleted", room)
      broadcast(room)
      {:ok, room}
    end
  end

  @doc "Adds a document at the end of the room."
  def add_document(%Scope{} = scope, %Room{} = room, %Document{} = doc) do
    with :ok <- Policy.authorize(scope, :edit_room, room),
         :ok <- Policy.authorize(scope, :edit_document, doc) do
      position =
        (Repo.one(
           from rd in RoomDocument, where: rd.room_id == ^room.id, select: max(rd.position)
         ) || 0) + 1

      %RoomDocument{room_id: room.id, document_id: doc.id, position: position}
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:room_id, :document_id])
      |> tap(fn _ -> touch(room) end)
    end
  end

  def remove_document(%Scope{} = scope, %Room{} = room, document_id) do
    with :ok <- Policy.authorize(scope, :edit_room, room) do
      Repo.delete_all(
        from rd in RoomDocument, where: rd.room_id == ^room.id and rd.document_id == ^document_id
      )

      touch(room)
      :ok
    end
  end

  @doc "Moves a document one place up or down."
  def move_document(%Scope{} = scope, %Room{} = room, document_id, direction)
      when direction in [:up, :down] do
    with :ok <- Policy.authorize(scope, :edit_room, room) do
      Repo.transact(fn ->
        rows =
          Repo.all(from rd in RoomDocument, where: rd.room_id == ^room.id, order_by: rd.position)

        index = Enum.find_index(rows, &(&1.document_id == document_id))
        other = index && Enum.at(rows, if(direction == :up, do: index - 1, else: index + 1))

        if index && other && (direction == :down or index > 0) do
          a = Enum.at(rows, index)
          # Swap via a temporary position to keep the order unique.
          Repo.update_all(from(rd in RoomDocument, where: rd.id == ^a.id), set: [position: -1])

          Repo.update_all(from(rd in RoomDocument, where: rd.id == ^other.id),
            set: [position: a.position]
          )

          Repo.update_all(from(rd in RoomDocument, where: rd.id == ^a.id),
            set: [position: other.position]
          )
        end

        {:ok, :moved}
      end)

      touch(room)
      :ok
    end
  end

  defp touch(room) do
    Repo.update_all(from(r in Room, where: r.id == ^room.id),
      set: [updated_at: DateTime.utc_now(:second)]
    )

    broadcast(room)
  end

  @doc "Documents the scope may add to a room (those it can share), not yet in it."
  def addable_documents(%Scope{} = scope, %Room{} = room) do
    in_room = MapSet.new(room.documents, & &1.id)

    scope
    |> Readout.Documents.list_documents()
    |> Enum.filter(
      &(Policy.can?(scope, :edit_document, &1) and not MapSet.member?(in_room, &1.id))
    )
  end
end
