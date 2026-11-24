defmodule Readout.Documents do
  @moduledoc """
  Documents, their versions and pages, and who can see them.

  Uploading stores the original and queues `Readout.Documents.ProcessVersion`,
  which converts Office files to PDF, renders page images and extracts text.
  Status changes are broadcast so lists and pages update live.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.{Scope, User}
  alias Readout.{Audit, Policy, Repo, Storage}
  alias Readout.Documents.{Document, FileType, Member, Page, ProcessVersion, Version}

  @topic "documents"

  ## PubSub
  #
  # Messages carry ids only; subscribers re-read through their own scope, so a
  # broadcast never leaks a document someone can't see.

  def subscribe(%Scope{}), do: Phoenix.PubSub.subscribe(Readout.PubSub, @topic)

  def subscribe_document(%Scope{}, %Document{id: id}),
    do: Phoenix.PubSub.subscribe(Readout.PubSub, "#{@topic}:#{id}")

  defp broadcast(%Document{id: id}, event), do: broadcast(id, event)

  defp broadcast(document_id, event) when is_binary(document_id) do
    message = {event, document_id}
    Phoenix.PubSub.broadcast(Readout.PubSub, @topic, message)
    Phoenix.PubSub.broadcast(Readout.PubSub, "#{@topic}:#{document_id}", message)
  end

  @doc "Tells subscribers a document changed (e.g. its links)."
  def notify(document_id), do: broadcast(document_id, :document_updated)

  ## Configuration

  def max_upload_bytes do
    Application.get_env(:readout, __MODULE__)[:max_upload_bytes] || 100 * 1024 * 1024
  end

  ## Reading

  @doc """
  Documents the scope can see.

  ## Options

    * `:query` - matches the title, or the text of the current version's pages
    * `:sort` - `"recent"` (default, last updated), `"title"` or `"created"`
  """
  def list_documents(%Scope{} = scope, opts \\ []) do
    base()
    |> visible_to(scope)
    |> search(opts[:query])
    |> sort(opts[:sort])
    |> preload([:owner, :members, :current_version])
    |> Repo.all()
    |> put_latest_versions()
  end

  # Admins and owners see everything; others see workspace documents plus the
  # restricted ones they own or were added to.
  defp visible_to(query, %Scope{user: %User{role: role}}) when role in [:owner, :admin] do
    where(query, [d], is_nil(d.deleted_at))
  end

  defp visible_to(query, %Scope{user: %User{id: user_id}}) do
    from d in query,
      where: is_nil(d.deleted_at),
      where:
        d.visibility == :workspace or d.owner_id == ^user_id or
          exists(
            from m in Member,
              where: m.document_id == parent_as(:document).id and m.user_id == ^user_id
          )
  end

  defp search(query, text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        query

      text ->
        pattern = "%" <> Audit.escape_like(text) <> "%"

        from d in query,
          where:
            ilike(d.title, ^pattern) or
              exists(
                from p in Page,
                  where:
                    p.version_id == parent_as(:document).current_version_id and
                      fragment("? @@ websearch_to_tsquery('simple', ?)", p.search, ^text)
              )
    end
  end

  defp search(query, _), do: query

  defp sort(query, "title"), do: order_by(query, [d], asc: fragment("lower(?)", d.title))
  defp sort(query, "created"), do: order_by(query, [d], desc: d.inserted_at)
  defp sort(query, _), do: order_by(query, [d], desc: d.updated_at, desc: d.inserted_at)

  # Named binding used by the subqueries above.
  defp base, do: from(d in Document, as: :document)

  defp put_latest_versions([]), do: []

  defp put_latest_versions(documents) do
    ids = Enum.map(documents, & &1.id)

    latest =
      from(v in Version,
        where: v.document_id in ^ids,
        distinct: v.document_id,
        order_by: [asc: v.document_id, desc: v.number]
      )
      |> Repo.all()
      |> Map.new(&{&1.document_id, &1})

    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    links =
      from(l in Readout.Links.Link,
        where: l.document_id in ^ids and l.enabled,
        group_by: l.document_id,
        select: {l.document_id, count(l.id)}
      )
      |> Repo.all()
      |> Map.new()

    views =
      from(v in Readout.Links.Visit,
        where: v.document_id in ^ids and v.started_at > ^week_ago,
        group_by: v.document_id,
        select: {v.document_id, count(v.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(documents, fn d ->
      %{
        d
        | latest_version: latest[d.id],
          link_count: Map.get(links, d.id, 0),
          views_7d: Map.get(views, d.id, 0)
      }
    end)
  end

  @doc """
  Gets a document the scope can see, with owner, members, versions and the
  current version's pages. Returns nil when missing or not visible.
  """
  def get_document(%Scope{} = scope, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %Document{} = doc <-
           Repo.one(from d in base(), where: d.id == ^id and is_nil(d.deleted_at)),
         doc =
           Repo.preload(doc, [:owner, :current_version, members: :user, versions: :uploaded_by]),
         true <- Policy.can?(scope, :view_document, doc) do
      %{doc | latest_version: List.first(doc.versions)}
    else
      _ -> nil
    end
  end

  @doc "Pages of a version, in order."
  def list_pages(%Version{id: id}) do
    Repo.all(from p in Page, where: p.version_id == ^id, order_by: p.number)
  end

  @doc "Gets a version of a visible document."
  def get_version(%Document{versions: versions}, version_id) when is_list(versions) do
    Enum.find(versions, &(&1.id == version_id))
  end

  ## Uploading

  @doc """
  Creates a document from an uploaded file (`%{path: ..., filename: ...}`),
  stores the original and queues processing.
  """
  def create_document(%Scope{user: user} = scope, %{path: path, filename: filename}) do
    with :ok <- Policy.authorize(scope, :upload_document, :workspace),
         {:ok, file} <- inspect_upload(path) do
      Repo.transact(fn ->
        document =
          Repo.insert!(%Document{
            title: Document.title_from_filename(filename),
            owner_id: user.id,
            visibility: :workspace
          })

        with {:ok, version} <- insert_version(document, user, file, filename, 1) do
          {:ok, %{document | latest_version: version}}
        end
      end)
      |> tap(&broadcast_created/1)
    end
  end

  defp broadcast_created({:ok, document}), do: broadcast(document, :document_created)
  defp broadcast_created(_), do: :ok

  @doc """
  Uploads a new version. The document's links keep working: they show the new
  version once it is processed.
  """
  def add_version(%Scope{user: user} = scope, %Document{} = document, %{
        path: path,
        filename: filename
      }) do
    with :ok <- Policy.authorize(scope, :edit_document, document),
         {:ok, file} <- inspect_upload(path) do
      Repo.transact(fn ->
        # Lock the document so concurrent uploads get distinct numbers.
        Repo.one!(from d in Document, where: d.id == ^document.id, lock: "FOR UPDATE")

        number =
          (Repo.one(
             from v in Version, where: v.document_id == ^document.id, select: max(v.number)
           ) || 0) + 1

        with {:ok, version} <- insert_version(document, user, file, filename, number) do
          Repo.update_all(from(d in Document, where: d.id == ^document.id),
            set: [updated_at: DateTime.utc_now(:second)]
          )

          {:ok, version}
        end
      end)
      |> tap(fn
        {:ok, _} -> broadcast(document, :document_updated)
        _ -> :ok
      end)
    end
  end

  defp inspect_upload(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- check_size(size),
         {:ok, format} <- FileType.detect(path) do
      {:ok, %{path: path, size: size, format: format, checksum: checksum(path)}}
    else
      {:error, :too_large} -> {:error, :too_large}
      {:error, :empty} -> {:error, :empty}
      {:error, :unsupported} -> {:error, :unsupported}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp check_size(0), do: {:error, :empty}
  defp check_size(size), do: if(size > max_upload_bytes(), do: {:error, :too_large}, else: :ok)

  defp checksum(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp insert_version(document, user, file, filename, number) do
    version = %Version{
      document_id: document.id,
      number: number,
      format: file.format,
      original_filename: Path.basename(filename) |> String.slice(0, 255),
      byte_size: file.size,
      checksum: file.checksum,
      uploaded_by_id: user.id
    }

    key = "#{Version.prefix(version)}/original#{FileType.extension(file.format)}"
    version = %{version | original_key: key}

    with :ok <- Storage.put_file(key, file.path),
         {:ok, version} <- Repo.insert(version),
         {:ok, _job} <- version |> ProcessVersion.new_job() |> Oban.insert() do
      {:ok, version}
    else
      {:error, reason} ->
        Storage.delete_prefix(Version.prefix(version))
        {:error, reason}
    end
  end

  @doc "Queues a failed version for another try."
  def retry_version(%Scope{} = scope, %Document{} = document, %Version{status: :failed} = version) do
    with :ok <- Policy.authorize(scope, :edit_document, document) do
      {:ok, version} =
        version |> Ecto.Changeset.change(status: :pending, error: nil) |> Repo.update()

      {:ok, _} = version |> ProcessVersion.new_job() |> Oban.insert()
      broadcast(document, :document_updated)
      {:ok, version}
    end
  end

  ## Processing (called by ProcessVersion)

  @doc false
  def mark_processing(%Version{} = version) do
    version = version |> Ecto.Changeset.change(status: :processing) |> Repo.update!()
    broadcast(version.document_id, :document_updated)
    version
  end

  @doc false
  def complete_version(%Version{} = version, attrs, pages) do
    Repo.transact(fn ->
      Repo.delete_all(from p in Page, where: p.version_id == ^version.id)

      rows =
        for {page, n} <- Enum.with_index(pages, 1) do
          %{
            id: Ecto.UUID.generate(),
            version_id: version.id,
            number: n,
            width: page.width,
            height: page.height,
            text: page.text
          }
        end

      rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Page, &1))

      version =
        version
        |> Ecto.Changeset.change(
          Map.merge(attrs, %{status: :ready, error: nil, processed_at: DateTime.utc_now(:second)})
        )
        |> Repo.update!()

      # A newer ready version becomes current; never step back to an older one.
      older_versions =
        from v in Version,
          where: v.document_id == ^version.document_id and v.number < ^version.number,
          select: v.id

      from(d in Document,
        where: d.id == ^version.document_id,
        where: is_nil(d.current_version_id) or d.current_version_id in subquery(older_versions)
      )
      |> Repo.update_all(
        set: [current_version_id: version.id, updated_at: DateTime.utc_now(:second)]
      )

      {:ok, version}
    end)
    |> tap(fn {:ok, v} -> broadcast(v.document_id, :document_updated) end)
  end

  @doc false
  def fail_version(%Version{} = version, message) do
    version =
      version
      |> Ecto.Changeset.change(status: :failed, error: String.slice(message, 0, 2000))
      |> Repo.update!()

    broadcast(version.document_id, :document_updated)
    version
  end

  ## Changing

  def change_title(%Document{} = document, attrs \\ %{}),
    do: Document.title_changeset(document, attrs)

  def rename_document(%Scope{} = scope, %Document{} = document, attrs) do
    with :ok <- Policy.authorize(scope, :edit_document, document),
         {:ok, document} <- document |> Document.title_changeset(attrs) |> Repo.update() do
      broadcast(document, :document_updated)
      {:ok, document}
    end
  end

  def update_visibility(%Scope{} = scope, %Document{} = document, visibility) do
    with :ok <- Policy.authorize(scope, :manage_document, document),
         {:ok, document} <-
           document |> Document.visibility_changeset(%{visibility: visibility}) |> Repo.update() do
      broadcast(document, :document_updated)
      {:ok, document}
    end
  end

  @doc "Adds someone to a document (or changes their role on it)."
  def put_member(%Scope{} = scope, %Document{} = document, %User{} = user, role) do
    with :ok <- Policy.authorize(scope, :manage_document, document),
         :ok <- if(user.id == document.owner_id, do: {:error, :owner}, else: :ok) do
      %Member{document_id: document.id, user_id: user.id}
      |> Member.changeset(%{role: role})
      |> Repo.insert(
        on_conflict: {:replace, [:role, :updated_at]},
        conflict_target: [:document_id, :user_id]
      )
      |> tap(fn
        {:ok, _} -> broadcast(document, :document_updated)
        _ -> :ok
      end)
    end
  end

  def remove_member(%Scope{} = scope, %Document{} = document, user_id) do
    with :ok <- Policy.authorize(scope, :manage_document, document) do
      Repo.delete_all(
        from m in Member, where: m.document_id == ^document.id and m.user_id == ^user_id
      )

      broadcast(document, :document_updated)
      :ok
    end
  end

  @doc """
  Deletes a document: it disappears everywhere and its files are removed.
  The row is kept (soft delete) so history and analytics stay consistent.
  """
  def delete_document(%Scope{} = scope, %Document{} = document) do
    with :ok <- Policy.authorize(scope, :manage_document, document),
         {:ok, document} <-
           document
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
           |> Repo.update() do
      Storage.delete_prefix("documents/#{document.id}")
      Audit.log(scope, "document.deleted", document)
      broadcast(document, :document_deleted)
      {:ok, document}
    end
  end
end
