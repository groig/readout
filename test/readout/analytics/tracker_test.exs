defmodule Readout.Analytics.TrackerTest do
  use ExUnit.Case, async: true

  alias Readout.Analytics.Tracker

  defp flush(t, now) do
    {_t, ms, views} = Tracker.flush(t, now)
    {ms, views}
  end

  test "time accrues to the page in view, measured by the server clock" do
    t = Tracker.new(5, 0) |> Tracker.page(1, 0) |> Tracker.page(2, 4_000)
    assert flush(t, 10_000) == {%{1 => 4_000, 2 => 6_000}, %{1 => 1, 2 => 1}}
  end

  test "nothing accrues before a page is reported or for out-of-range pages" do
    t = Tracker.new(3, 0)
    assert flush(t, 5_000) == {%{}, %{}}

    t = t |> Tracker.page(9, 5_000) |> Tracker.page(0, 5_000)
    assert flush(t, 9_000) == {%{}, %{}}
  end

  test "a hidden tab doesn't count" do
    t =
      Tracker.new(3, 0)
      |> Tracker.page(1, 0)
      |> Tracker.visibility(false, 3_000)
      |> Tracker.visibility(true, 60_000)

    assert {%{1 => 8_000}, _} = flush(t, 65_000)
  end

  test "an idle reader stops accruing after the idle limit" do
    t = Tracker.new(3, 0, idle_ms: 10_000) |> Tracker.page(1, 0)
    assert {%{1 => 10_000}, _} = flush(t, 100_000)
  end

  test "activity keeps the clock running, and a return from idle starts fresh" do
    t =
      Tracker.new(3, 0, idle_ms: 10_000)
      |> Tracker.page(1, 0)
      |> Tracker.activity(8_000)

    assert {%{1 => 16_000}, _} = flush(t, 16_000)

    # Gone from 8 s to 60 s: counts until 18 s, then restarts at 60 s.
    t = Tracker.activity(t, 60_000)
    assert {%{1 => 23_000}, _} = flush(t, 65_000)
  end

  test "flushing takes what's pending and keeps measuring" do
    t = Tracker.new(3, 0) |> Tracker.page(1, 0)
    {t, %{1 => 1_000}, %{1 => 1}} = Tracker.flush(t, 1_000)
    {_t, %{1 => 2_000}, views} = Tracker.flush(t, 3_000)
    assert views == %{}
  end

  test "repeated visits to a page count as views" do
    t =
      Tracker.new(3, 0)
      |> Tracker.page(1, 0)
      |> Tracker.page(2, 1)
      |> Tracker.page(1, 2)
      |> Tracker.page(1, 3)

    assert {_ms, %{1 => 2, 2 => 1}} = flush(t, 4)
  end

  test "the visit ends after a long inactivity" do
    t = Tracker.new(3, 0, end_after_ms: 1_000)
    refute Tracker.ended?(t, 999)
    assert Tracker.ended?(t, 1_000)
  end
end
