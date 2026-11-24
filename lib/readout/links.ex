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

  ## Managing links

  @doc "Links of a document (anyone who can see the document), newest first."
  def list_links(%Scope{} = scope, %Document{} = document) do
    if Policy.can?(scope, :view_document, document) do
      visits =
        from v in Visit, where: v.link_id == parent_as(:link).id, select: count(v.id)

      from(l in Link,
        as: :link,
        where: l.document_id == ^document.id,
        order_by: [desc: l.inserted_at],
        select_merge: %{visit_count: subquery(visits)}
      )
      |> Repo.all()
    else
      []
    end
  end

  def get_link(%Document{} = document, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Repo.get_by(Link, id: id, document_id: document.id)
    else
      _ -> nil
    end
  end

  def change_link(%Link{} = link, attrs \\ %{}) do
    Link.changeset(link, attrs, mail_enabled: Readout.Mailer.enabled?())
  end

  def create_link(%Scope{user: user} = scope, %Document{} = document, attrs) do
    with :ok <- Policy.authorize(scope, :edit_document, document),
         {:ok, link} <-
           %Link{document_id: document.id, created_by_id: user.id, slug: Link.generate_slug()}
           |> change_link(attrs)
           |> Repo.insert() do
      Audit.log(scope, "link.created", link, %{document: document.title})
      Documents.notify(document.id)
      {:ok, link}
    end
  end

  def update_link(%Scope{} = scope, %Document{} = document, %Link{} = link, attrs) do
    with :ok <- Policy.authorize(scope, :edit_document, document),
         :ok <- same_document(document, link),
         changeset = change_link(link, attrs),
         {:ok, updated} <- Repo.update(changeset) do
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
        document: document.title,
        changed: Enum.map(changed, &to_string/1)
      })

      Documents.notify(document.id)
      {:ok, updated}
    end
  end

  def set_enabled(scope, document, link, enabled?) when is_boolean(enabled?),
    do: update_link(scope, document, link, %{"enabled" => enabled?})

  defp same_document(%Document{id: id}, %Link{document_id: id}), do: :ok
  defp same_document(_, _), do: {:error, :unauthorized}

  ## Public side

  @doc """
  Resolves a slug for the public viewer. Returns the link with its document
  and current version, or why it can't be viewed.
  """
  def fetch_public_link(slug) when is_binary(slug) do
    link =
      from(l in Link,
        join: d in assoc(l, :document),
        where: l.slug == ^slug and is_nil(d.deleted_at),
        preload: [document: {d, [:current_version]}]
      )
      |> Repo.one()

    cond do
      is_nil(link) -> {:error, :not_found}
      not link.enabled -> {:error, :disabled}
      Link.expired?(link) -> {:error, :expired}
      is_nil(link.document.current_version) -> {:error, :not_ready}
      true -> {:ok, link}
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
        document: link.document.title,
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

  @doc "Starts a visit once the viewer is through the gate."
  def start_visit(%Link{} = link, attrs) do
    now = DateTime.utc_now()

    %Visit{
      link_id: link.id,
      document_id: link.document_id,
      version_id: link.document.current_version_id,
      email: attrs[:email],
      email_verified: !!attrs[:email_verified],
      ip: attrs[:ip],
      user_agent: attrs[:user_agent] && String.slice(attrs[:user_agent], 0, 400),
      started_at: now,
      last_seen_at: now
    }
    |> Repo.insert!()
  end

  def get_visit(id) do
    with {:ok, _} <- Ecto.UUID.cast(id), do: Repo.get(Visit, id), else: (_ -> nil)
  end

  def end_visit(%Visit{} = visit) do
    now = DateTime.utc_now()

    from(v in Visit, where: v.id == ^visit.id and is_nil(v.ended_at))
    |> Repo.update_all(set: [ended_at: now, last_seen_at: now])

    :ok
  end
end
