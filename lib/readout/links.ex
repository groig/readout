defmodule Readout.Links do
  @moduledoc """
  Share links, the gate in front of them, email verification codes and visits.

  Managing links needs `:edit_document` on the link's document. The public
  side (`fetch_public_link/1`, the gate, visits) is used by the viewer and
  trusts nothing from the client beyond what each function validates.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.Scope
  alias Readout.{Audit, Documents, Policy, RateLimit, Repo}
  alias Readout.Documents.Document
  alias Readout.Links.{Link, Verification, Visit}
  alias Readout.Rooms
  alias Readout.Rooms.Room

  ## Managing links

  @doc "Links of a document or room (anyone who can see it), newest first."
  def list_links(%Scope{} = scope, target) do
    if Policy.can?(scope, view_action(target), target) do
      visits =
        from v in Visit, where: v.link_id == parent_as(:link).id, select: count(v.id)

      from(l in Link,
        as: :link,
        where: ^target_filter(target),
        order_by: [desc: l.inserted_at],
        select_merge: %{visit_count: subquery(visits)}
      )
      |> Repo.all()
    else
      []
    end
  end

  def get_link(target, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Link |> where([l], l.id == ^id) |> where(^target_filter(target)) |> Repo.one()
    else
      _ -> nil
    end
  end

  defp target_filter(%Document{id: id}), do: dynamic([l], l.document_id == ^id)
  defp target_filter(%Room{id: id}), do: dynamic([l], l.room_id == ^id)

  defp view_action(%Document{}), do: :view_document
  defp view_action(%Room{}), do: :view_room
  defp edit_action(%Document{}), do: :edit_document
  defp edit_action(%Room{}), do: :edit_room

  defp target_title(%Document{title: title}), do: title
  defp target_title(%Room{name: name}), do: name

  defp notify(%Document{id: id}), do: Documents.notify(id)

  defp notify(%Room{} = room),
    do: Phoenix.PubSub.broadcast(Readout.PubSub, "rooms", {:room_updated, room.id})

  def change_link(%Link{} = link, attrs \\ %{}) do
    Link.changeset(link, attrs, mail_enabled: Readout.Mailer.enabled?())
  end

  def create_link(%Scope{user: user} = scope, target, attrs) do
    base =
      case target do
        %Document{id: id} -> %Link{document_id: id}
        %Room{id: id} -> %Link{room_id: id}
      end

    with :ok <- Policy.authorize(scope, edit_action(target), target),
         {:ok, link} <-
           %{base | created_by_id: user.id, slug: Link.generate_slug()}
           |> change_link(attrs)
           |> Repo.insert() do
      Audit.log(scope, "link.created", link, %{document: target_title(target)})
      notify(target)
      {:ok, link}
    end
  end

  def update_link(%Scope{} = scope, target, %Link{} = link, attrs) do
    with :ok <- Policy.authorize(scope, edit_action(target), target),
         :ok <- same_target(target, link),
         changeset = change_link(link, attrs),
         {:ok, updated} <- update_and_revise(changeset) do
      action =
        case Ecto.Changeset.get_change(changeset, :enabled) do
          false -> "link.disabled"
          true -> "link.enabled"
          nil -> "link.updated"
        end

      changed =
        changeset.changes
        |> Map.keys()
        |> Enum.reject(&(&1 in [:password, :allow_list_text, :deny_list_text]))

      Audit.log(scope, action, updated, %{
        document: target_title(target),
        changed: Enum.map(changed, &to_string/1)
      })

      notify(target)
      {:ok, updated}
    end
  end

  # Access changes bump the revision in the same transaction, atomically (two
  # concurrent edits get two revisions), so every grant and page token issued
  # under the old rules stops working.
  defp update_and_revise(changeset) do
    if Link.access_changed?(changeset) do
      Repo.transaction(fn ->
        with {:ok, updated} <- Repo.update(changeset) do
          {1, [revision]} =
            from(l in Link, where: l.id == ^updated.id, select: l.access_revision)
            |> Repo.update_all(inc: [access_revision: 1])

          %{updated | access_revision: revision}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      Repo.update(changeset)
    end
  end

  def set_enabled(scope, target, link, enabled?) when is_boolean(enabled?),
    do: update_link(scope, target, link, %{"enabled" => enabled?})

  defp same_target(%Document{id: id}, %Link{document_id: id}), do: :ok
  defp same_target(%Room{id: id}, %Link{room_id: id}), do: :ok
  defp same_target(_, _), do: {:error, :unauthorized}

  ## Public side

  @doc """
  Resolves a slug for the public viewer. Returns the link with its document
  and current version, or why it can't be viewed.
  """
  def fetch_public_link(slug) when is_binary(slug) do
    link =
      from(l in Link,
        left_join: d in assoc(l, :document),
        left_join: r in assoc(l, :room),
        where: l.slug == ^slug,
        where:
          (not is_nil(d.id) and is_nil(d.deleted_at)) or
            (not is_nil(r.id) and is_nil(r.deleted_at)),
        preload: [document: {d, [:current_version]}, room: r]
      )
      |> Repo.one()
      |> put_room_documents()

    cond do
      is_nil(link) -> {:error, :not_found}
      not link.enabled -> {:error, :disabled}
      Link.expired?(link) -> {:error, :expired}
      Link.room?(link) and link.room.documents == [] -> {:error, :not_ready}
      not Link.room?(link) and is_nil(link.document.current_version) -> {:error, :not_ready}
      true -> {:ok, link}
    end
  end

  @doc """
  Re-checks, against the current state, that a reader may still read a
  document through a link. Every public read (page images, downloads, sheets,
  room navigation) goes through this, so revoking access takes effect on the
  next request:

    * the link is still viewable (enabled, not expired, not deleted);
    * its access rules haven't changed since `revision` was issued;
    * it still shares the document (a room may have dropped it);
    * `version_id` is still the document's current version.

  Returns the fresh link and document.
  """
  def check_access(slug, revision, document_id, version_id) do
    with {:ok, link} <- fetch_public_link(slug),
         true <- link.access_revision == revision || {:error, :changed},
         %Document{} = document <- shared_document(link, document_id) || {:error, :removed},
         true <- current_version?(document, version_id) || {:error, :new_version} do
      {:ok, link, document}
    end
  end

  defp current_version?(%Document{current_version: %{id: id, status: :ready}}, id), do: true
  defp current_version?(_document, _version_id), do: false

  @doc "The document a link shares with this id (one of its room's, for room links)."
  def shared_document(%Link{room: %Room{documents: documents}}, id),
    do: Enum.find(documents, &(&1.id == id))

  def shared_document(%Link{document: %Document{id: id} = document}, id), do: document
  def shared_document(_link, _id), do: nil

  @doc """
  Subscribes a viewer's process to changes that can affect what a link
  shows: `{:document_updated, id}` (and other document events) for its
  documents, `{:room_updated, id}` for its room. Messages carry ids only; the
  viewer re-checks with `check_access/4`.
  """
  def subscribe_viewer(%Link{room_id: nil, document_id: id}),
    do: Phoenix.PubSub.subscribe(Readout.PubSub, "documents:#{id}")

  def subscribe_viewer(%Link{}) do
    Phoenix.PubSub.subscribe(Readout.PubSub, "rooms")
    Phoenix.PubSub.subscribe(Readout.PubSub, "documents")
  end

  # A room link shows only documents that are ready.
  defp put_room_documents(%Link{room: %Room{} = room} = link) do
    [room] = Rooms.put_documents([room])
    %{link | room: %{room | documents: Enum.filter(room.documents, & &1.current_version)}}
  end

  defp put_room_documents(link), do: link

  @doc """
  Whether a viewer may open a link with a viewer limit: always if they opened
  it before (same device, or same email), otherwise while fewer than
  `max_viewers` people have. People are counted by device (then email, then
  IP), so refreshing never uses up the limit.
  """
  def admits?(%Link{max_viewers: nil}, _viewer), do: true

  def admits?(%Link{max_viewers: max} = link, viewer) do
    known? =
      case same_viewer(viewer[:device_id], viewer[:email]) do
        nil -> false
        cond -> Repo.exists?(from v in Visit, where: v.link_id == ^link.id, where: ^cond)
      end

    known? or viewer_count(link) < max
  end

  # Visits by the same device or the same email (nil when neither is known).
  defp same_viewer(device, email) do
    [device && dynamic([v], v.device_id == ^device), email && dynamic([v], v.email == ^email)]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn
      d, nil -> d
      d, acc -> dynamic([v], ^acc or ^d)
    end)
  end

  @doc "How many people (devices) have opened a link."
  def viewer_count(%Link{id: id}) do
    from(v in Visit,
      where: v.link_id == ^id,
      select: count(fragment("DISTINCT coalesce(?, ?::text, ?)", v.device_id, v.email, v.ip))
    )
    |> Repo.one()
  end

  @doc "Whether a visit is the viewer's first through its link."
  def first_visit?(%Visit{} = visit) do
    case same_viewer(visit.device_id, visit.email) do
      nil ->
        true

      cond ->
        not Repo.exists?(
          from v in Visit,
            where: v.link_id == ^visit.link_id and v.id != ^visit.id,
            where: v.started_at < ^visit.started_at,
            where: ^cond
        )
    end
  end

  @doc """
  Checks the gate's form: password (if any) and email (if required, against
  the allow and deny lists). Rate-limited per link and client.
  """
  def check_gate(%Link{} = link, params, client_key) do
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
    password = Map.get(params, "password", "")

    with :ok <- RateLimit.hit({:gate, link.id, client_key}, 10, :timer.minutes(10)),
         :ok <- check_password(link, password),
         :ok <- check_email(link, email) do
      {:ok, if(link.require_email, do: email)}
    end
  end

  defp check_password(%Link{password_hash: nil}, _), do: :ok

  defp check_password(link, password) do
    if Link.valid_password?(link, password), do: :ok, else: {:error, :wrong_password}
  end

  defp check_email(%Link{require_email: false}, _), do: :ok

  defp check_email(link, email) do
    cond do
      not Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, email) -> {:error, :invalid_email}
      not Link.allows_email?(link, email) -> {:error, :email_not_allowed}
      true -> :ok
    end
  end

  @doc """
  Emails a 6-digit code. At most 3 codes per email and link every 15 minutes,
  and 10 per client.
  """
  def send_verification(%Link{} = link, email, locale, client_key) do
    with :ok <- RateLimit.hit({:code, link.id, email}, 3, :timer.minutes(15)),
         :ok <- RateLimit.hit({:code_client, client_key}, 10, :timer.minutes(15)) do
      code = Verification.generate_code()

      %Verification{
        link_id: link.id,
        email: email,
        code_hash: Verification.hash(link.id, code),
        expires_at:
          DateTime.add(DateTime.utc_now(:second), Verification.validity_minutes(), :minute)
      }
      |> Repo.insert!()

      email
      |> ReadoutWeb.Emails.verification_code(locale, %{
        code: code,
        document: Link.title(link),
        workspace: Readout.Workspace.get_settings().name,
        minutes: Verification.validity_minutes()
      })
      |> Readout.Mailer.deliver_later()

      :ok
    end
  end

  @doc """
  Checks a code against the latest unexpired one for this link and email.
  Each code allows a few attempts; a correct code works once.
  """
  def verify_code(%Link{} = link, email, code) do
    code = code |> to_string() |> String.replace(~r/\D/, "")
    now = DateTime.utc_now(:second)

    verification =
      from(v in Verification,
        where: v.link_id == ^link.id and v.email == ^email,
        where: is_nil(v.consumed_at) and v.expires_at > ^now,
        order_by: [desc: v.inserted_at],
        limit: 1
      )
      |> Repo.one()

    cond do
      is_nil(verification) ->
        {:error, :expired}

      verification.attempts >= Verification.max_attempts() ->
        {:error, :too_many_attempts}

      Plug.Crypto.secure_compare(verification.code_hash, Verification.hash(link.id, code)) ->
        verification |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()
        :ok

      true ->
        from(v in Verification, where: v.id == ^verification.id)
        |> Repo.update_all(inc: [attempts: 1])

        {:error, :wrong_code}
    end
  end

  ## Visits

  @doc """
  Starts a visit once the viewer is through the gate. For room links, pass
  the document being read as `:document`.

  For links with a viewer limit, admission and the visit are one step: a
  per-link lock serializes them, so two new readers racing for the last slot
  can't both get in. Returns `{:error, :used_up}` for the one that loses.
  """
  def start_visit(%Link{max_viewers: nil} = link, attrs) do
    {:ok, link |> insert_visit(attrs) |> announce_visit()}
  end

  def start_visit(%Link{} = link, attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["link:" <> link.id])

      if admits?(link, %{device_id: attrs[:device_id], email: attrs[:email]}),
        do: insert_visit(link, attrs),
        else: Repo.rollback(:used_up)
    end)
    |> case do
      {:ok, visit} -> {:ok, announce_visit(visit)}
      error -> error
    end
  end

  @doc "Like `start_visit/2`, raising when the link is used up (seeds and tests)."
  def start_visit!(link, attrs) do
    {:ok, visit} = start_visit(link, attrs)
    visit
  end

  defp announce_visit(visit) do
    visit
    |> tap(&Readout.Analytics.broadcast(:visit_started, &1))
    |> tap(&Readout.Notifications.visit_started/1)
  end

  defp insert_visit(link, attrs) do
    now = DateTime.utc_now()
    location = Readout.GeoIP.lookup(attrs[:ip]) || %{country_code: nil, country: %{}, city: %{}}
    document = attrs[:document] || link.document
    version = document.current_version

    %Visit{
      link_id: link.id,
      document_id: document.id,
      version_id: version && version.id,
      email: attrs[:email],
      email_verified: !!attrs[:email_verified],
      device_id: attrs[:device_id],
      ip: attrs[:ip],
      user_agent: attrs[:user_agent] && String.slice(attrs[:user_agent], 0, 400),
      started_at: now,
      last_seen_at: now,
      country_code: location.country_code,
      country: location.country,
      city: location.city,
      page_count: version && version.page_count
    }
    |> Repo.insert!()
  end

  def get_visit(id) do
    with {:ok, _} <- Ecto.UUID.cast(id), do: Repo.get(Visit, id), else: (_ -> nil)
  end

  def end_visit(%Visit{} = visit) do
    now = DateTime.utc_now()

    {count, _} =
      from(v in Visit, where: v.id == ^visit.id and is_nil(v.ended_at))
      |> Repo.update_all(set: [ended_at: now, last_seen_at: now])

    if count > 0 do
      Readout.Analytics.broadcast(:visit_ended, visit)
      Readout.Notifications.visit_ended(visit)
    end

    :ok
  end
end
