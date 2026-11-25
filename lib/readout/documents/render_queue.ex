defmodule Readout.Documents.RenderQueue do
  @moduledoc """
  Bounds expensive renders that strangers can trigger (watermarked page
  images and PDFs):

    * at most `:max` renders run at once (`:watermark_concurrency`, the
      number of schedulers by default); the rest wait their turn, up to
      `:wait` milliseconds, then give up with `{:error, :busy}`;
    * one render per key at a time: a request for a key that is being
      rendered waits for it, and when its turn comes its function finds the
      result cached (functions re-check their cache first).

  A caller that dies or gives up frees its slot.
  """
  use GenServer

  @default_wait 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` when a slot is free and nobody else is rendering `key`.
  Options: `:server`, `:wait` (milliseconds).
  """
  def run(key, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    ref = make_ref()

    case acquire(server, key, ref, Keyword.get(opts, :wait, @default_wait)) do
      :ok ->
        try do
          fun.()
        after
          GenServer.cast(server, {:release, ref})
        end

      :busy ->
        {:error, :busy}
    end
  end

  defp acquire(server, key, ref, wait) do
    GenServer.call(server, {:acquire, key, ref}, wait)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(server, {:cancel, ref})
      :busy
  end

  ## Server

  @impl true
  def init(opts) do
    max =
      Keyword.get_lazy(opts, :max, fn ->
        Application.get_env(:readout, :watermark_concurrency) || System.schedulers_online()
      end)

    {:ok, %{max: max, running: %{}, keys: %{}, queue: []}}
  end

  @impl true
  def handle_call({:acquire, key, ref}, {pid, _} = from, state) do
    if startable?(state, key) do
      {:reply, :ok, start(state, ref, key, pid)}
    else
      {:noreply, %{state | queue: state.queue ++ [{from, key, ref, pid}]}}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, state |> finish(ref) |> dispatch()}

  def handle_cast({:cancel, ref}, state) do
    queue = Enum.reject(state.queue, fn {_, _, r, _} -> r == ref end)
    {:noreply, %{state | queue: queue} |> finish(ref) |> dispatch()}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    ref = Enum.find_value(state.running, fn {ref, {_key, mon}} -> mon == monitor && ref end)
    queue = Enum.reject(state.queue, fn {_, _, _, p} -> p == pid end)
    {:noreply, %{state | queue: queue} |> finish(ref) |> dispatch()}
  end

  defp startable?(state, key),
    do: map_size(state.running) < state.max and not Map.has_key?(state.keys, key)

  defp start(state, ref, key, pid) do
    monitor = Process.monitor(pid)

    %{
      state
      | running: Map.put(state.running, ref, {key, monitor}),
        keys: Map.put(state.keys, key, ref)
    }
  end

  defp finish(state, ref) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        state

      {{key, monitor}, running} ->
        Process.demonitor(monitor, [:flush])
        %{state | running: running, keys: Map.delete(state.keys, key)}
    end
  end

  # Start whoever can start now, in arrival order.
  defp dispatch(state) do
    {state, waiting} =
      Enum.reduce(state.queue, {%{state | queue: []}, []}, fn {from, key, ref, pid} = entry,
                                                              {state, waiting} ->
        if startable?(state, key) do
          GenServer.reply(from, :ok)
          {start(state, ref, key, pid), waiting}
        else
          {state, [entry | waiting]}
        end
      end)

    %{state | queue: Enum.reverse(waiting)}
  end
end
