defmodule Readout.Notifications.DeliverJob do
  @moduledoc """
  Creates the in-app notifications for one visit event, for every follower of
  the document. Runs in the background so the viewer never waits, and builds
  the snapshot when it runs (so an end-of-visit summary has final numbers).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Readout.Links.Visit
  alias Readout.{Notifications, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"visit_id" => id, "kind" => kind}}) do
    with %Visit{} = visit <-
           Repo.get(Visit, id) |> Repo.preload([:link, :page_views, document: :members]),
         nil <- visit.document.deleted_at,
         # Links can ask to hear only about a viewer's first visit.
         true <- not visit.link.notify_first_only or Readout.Links.first_visit?(visit),
         %{} = data <- snapshot(kind, visit) do
      for user <- Notifications.followers(visit.document) do
        Notifications.create(user, visit.document, visit.id, kind, data)
      end

      :ok
    else
      _ -> :ok
    end
  end

  # Nothing to report for visits that ended without reading.
  defp snapshot("visit_finished", %Visit{pages_viewed: 0}), do: nil

  defp snapshot(_kind, visit) do
    top = Enum.max_by(visit.page_views, & &1.duration_ms, fn -> nil end)

    %{
      "title" => visit.document.title,
      "link" => visit.link.name,
      "email" => visit.email,
      "verified" => visit.email_verified,
      "country" => visit.country,
      "city" => visit.city,
      "pages_viewed" => visit.pages_viewed,
      "page_count" => visit.page_count,
      "duration_ms" => visit.duration_ms,
      "top_page" => top && top.page
    }
  end
end
