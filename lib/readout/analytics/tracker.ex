defmodule Readout.Analytics.Tracker do
  @moduledoc """
  Measures reading time on the server, one tracker per open viewer.

  The client only reports *which* page is in view, whether the tab is
  visible, and that the reader is active (scrolling, keys, pointer). The time
  itself always comes from the server's monotonic clock, so it can't be faked
  by the client:

    * time accrues to the current page only while the tab is visible;
    * an idle reader (no activity for `idle_ms`, default 2 minutes) stops
      accruing; reading a long page without scrolling still counts up to then;
    * after `end_after_ms` (30 minutes) without activity the visit ends.

  Pure functions: the LiveView owns the struct and flushes it periodically
  with `Readout.Analytics.record/2`.
  """

  defstruct page: nil,
            page_count: 1,
            visible: true,
            segment_start: 0,
            last_activity: 0,
            idle_ms: 120_000,
            end_after_ms: 1_800_000,
            pending_ms: %{},
            pending_views: %{}

  @type t :: %__MODULE__{}

  def new(page_count, now, opts \\ []) do
    %__MODULE__{
      page_count: max(page_count, 1),
      segment_start: now,
      last_activity: now,
      idle_ms: Keyword.get(opts, :idle_ms, 120_000),
      end_after_ms: Keyword.get(opts, :end_after_ms, 1_800_000)
    }
  end

  @doc "The reader moved to `page` (ignored if out of range or unchanged)."
  def page(%__MODULE__{} = t, page, now) when is_integer(page) do
    cond do
      page < 1 or page > t.page_count ->
        t

      page == t.page ->
        %{t | last_activity: now}

      true ->
        t = credit(t, now)

        %{
          t
          | page: page,
            segment_start: now,
            last_activity: now,
            pending_views: Map.update(t.pending_views, page, 1, &(&1 + 1))
        }
    end
  end

  def page(t, _page, _now), do: t

  @doc "The tab became visible or hidden."
  def visibility(%__MODULE__{} = t, false, now), do: %{credit(t, now) | visible: false}

  def visibility(%__MODULE__{} = t, true, now),
    do: %{t | visible: true, segment_start: now, last_activity: now}

  @doc "The reader did something (scroll, key, pointer)."
  def activity(%__MODULE__{} = t, now) do
    # Coming back from idle starts a fresh segment, so the idle gap isn't counted.
    t = if idle?(t, now), do: %{credit(t, now) | segment_start: now}, else: t
    %{t | last_activity: now}
  end

  @doc """
  Credits time up to `now` and takes what is pending: returns
  `{tracker, %{page => ms}, %{page => views}}`.
  """
  def flush(%__MODULE__{} = t, now) do
    t = credit(t, now)
    {%{t | pending_ms: %{}, pending_views: %{}}, t.pending_ms, t.pending_views}
  end

  @doc "Whether the visit should end for inactivity."
  def ended?(%__MODULE__{} = t, now), do: now - t.last_activity >= t.end_after_ms

  defp idle?(t, now), do: now - t.last_activity >= t.idle_ms

  # Adds the current segment's time (visible, and not past the idle limit) to
  # the current page, and starts a new segment at `now`.
  defp credit(%__MODULE__{page: nil} = t, now), do: %{t | segment_start: now}
  defp credit(%__MODULE__{visible: false} = t, now), do: %{t | segment_start: now}

  defp credit(%__MODULE__{} = t, now) do
    until = min(now, t.last_activity + t.idle_ms)
    ms = max(until - t.segment_start, 0)

    pending =
      if ms > 0, do: Map.update(t.pending_ms, t.page, ms, &(&1 + ms)), else: t.pending_ms

    %{t | pending_ms: pending, segment_start: now}
  end
end
