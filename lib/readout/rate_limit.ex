defmodule Readout.RateLimit do
  @moduledoc """
  A small fixed-window rate limiter in ETS (single node), for gate attempts,
  verification codes and sign-in emails.

      :ok = RateLimit.hit({:gate, link_id, ip}, 10, :timer.minutes(10))
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Counts a hit for `key`. Returns `:ok` while under `limit` hits in the current
  `window_ms`, otherwise `{:error, :rate_limited}`.
  """
  def hit(key, limit, window_ms) do
    window = div(System.system_time(:millisecond), window_ms)
    bucket = {key, window}
    expires_at = (window + 1) * window_ms

    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0, expires_at})
    if count <= limit, do: :ok, else: {:error, :rate_limited}
  end

  @doc "Forgets a key (e.g. after a successful sign-in)."
  def reset(key), do: :ets.match_delete(@table, {{key, :_}, :_, :_})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, nil}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, :timer.minutes(1))
end
