defmodule ReadoutWeb.NotificationLabels do
  @moduledoc "The text of in-app notifications, in the reader's own language."
  use Gettext, backend: ReadoutWeb.Gettext

  alias Readout.GeoIP
  alias Readout.Notifications.Notification

  @doc "A one-line sentence for a notification."
  def text(%Notification{kind: kind, data: d}, locale) do
    case kind do
      "visit_opened" ->
        gettext("%{viewer} opened «%{title}» via «%{link}»",
          viewer: viewer(d, locale),
          title: d["title"],
          link: d["link"]
        )

      "visit_finished" ->
        gettext("%{viewer} read %{seen} of %{count} pages of «%{title}» in %{time}",
          viewer: viewer(d, locale),
          seen: d["pages_viewed"],
          count: d["page_count"] || "?",
          title: d["title"],
          time: ReadoutWeb.Format.duration(div(d["duration_ms"] || 0, 1000))
        )

      "version_ready" ->
        gettext("Version %{n} of «%{title}» is ready", n: d["version"], title: d["title"])

      "version_failed" ->
        gettext("Version %{n} of «%{title}» couldn't be processed",
          n: d["version"],
          title: d["title"]
        )

      _ ->
        ""
    end
  end

  @doc "A secondary line, when there is one."
  def detail(%Notification{kind: "visit_finished", data: %{"top_page" => page}}, _locale)
      when is_integer(page),
      do: gettext("Most time on page %{n}", n: page)

  def detail(%Notification{kind: "version_failed", data: %{"error" => error}}, _locale),
    do: ReadoutWeb.DocumentLabels.error_message(error)

  def detail(_n, _locale), do: nil

  def icon(%Notification{kind: "visit_opened"}), do: "hero-eye-mini"
  def icon(%Notification{kind: "visit_finished"}), do: "hero-check-badge-mini"
  def icon(%Notification{kind: "version_ready"}), do: "hero-document-check-mini"
  def icon(%Notification{kind: "version_failed"}), do: "hero-exclamation-triangle-mini"
  def icon(_), do: "hero-bell-mini"

  defp viewer(%{"email" => email, "verified" => true}, _locale) when is_binary(email),
    do: gettext("%{email} (verified)", email: email)

  defp viewer(%{"email" => email}, _locale) when is_binary(email), do: email

  defp viewer(d, locale) do
    case GeoIP.label(%{country: d["country"] || %{}, city: d["city"] || %{}}, locale) do
      nil -> gettext("An anonymous viewer")
      place -> gettext("Someone in %{place}", place: place)
    end
  end
end
