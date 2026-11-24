defmodule Readout.Notifications.RocketChatJob do
  @moduledoc """
  Posts one visit notification to the Rocket.Chat incoming webhook. The
  message is built when the job runs, so the end-of-visit summary has the
  final numbers. Retries if Rocket.Chat is down.
  """
  use Oban.Worker, queue: :default, max_attempts: 5
  use Gettext, backend: ReadoutWeb.Gettext
  use ReadoutWeb, :verified_routes

  alias Readout.{GeoIP, Notifications, Repo, Workspace}
  alias Readout.Links.Visit

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"visit_id" => id, "event" => event}}) do
    with %Visit{} = visit <-
           Repo.get(Visit, id) |> Repo.preload([:link, :page_views, document: :members]),
         nil <- visit.document.deleted_at,
         followers when followers != [] <- Notifications.followers(visit.document),
         text when is_binary(text) <- message(event, visit, followers) do
      post(text)
    else
      # Nothing to say (no followers, nothing read, document gone).
      _ -> :ok
    end
  end

  @doc false
  def message(event, visit, followers) do
    locale = Workspace.get_settings().notification_locale

    Gettext.with_locale(ReadoutWeb.Gettext, locale, fn ->
      body = body(event, visit, locale)
      mentions = for %{chat_username: name} <- followers, name not in [nil, ""], do: "@" <> name

      if body do
        url = url(~p"/documents/#{visit.document_id}/analytics?#{%{visit: visit.id}}")
        Enum.join([body, Enum.join(mentions, " "), url] |> Enum.reject(&(&1 == "")), "\n")
      end
    end)
  end

  defp body("opened", visit, locale) do
    gettext("%{viewer} opened «%{title}» via the «%{link}» link",
      viewer: viewer(visit, locale),
      title: visit.document.title,
      link: visit.link.name
    )
  end

  defp body("finished", %Visit{pages_viewed: 0}, _locale), do: nil

  defp body("finished", visit, locale) do
    top = Enum.max_by(visit.page_views, & &1.duration_ms, fn -> nil end)

    gettext(
      "%{viewer} finished reading «%{title}»: %{seen} of %{count} pages in %{time}, most time on page %{top}.",
      viewer: viewer(visit, locale),
      title: visit.document.title,
      seen: visit.pages_viewed,
      count: visit.page_count || "?",
      time: ReadoutWeb.Format.duration(div(visit.duration_ms, 1000)),
      top: (top && top.page) || "?"
    )
  end

  defp body(_event, _visit, _locale), do: nil

  defp viewer(%Visit{email: email, email_verified: true}, _locale) when is_binary(email),
    do: gettext("%{email} (verified)", email: email)

  defp viewer(%Visit{email: email}, _locale) when is_binary(email), do: email

  defp viewer(visit, locale) do
    case GeoIP.label(%{country: visit.country, city: visit.city}, locale) do
      nil -> gettext("An anonymous viewer")
      place -> gettext("Someone in %{place}", place: place)
    end
  end

  defp post(text) do
    options =
      [json: %{text: text, alias: "Readout"}, receive_timeout: 10_000, retry: false]
      |> Keyword.merge(Application.get_env(:readout, :rocketchat_req_options, []))

    case Req.post(Notifications.webhook_url(), options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
