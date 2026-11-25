defmodule Readout.Documents.RenderQueueTest do
  use ExUnit.Case, async: true

  alias Readout.Documents.RenderQueue

  setup do
    name = :"render_queue_#{System.unique_integer([:positive])}"
    start_supervised!({RenderQueue, name: name, max: 2})
    counter = :counters.new(2, [])
    %{server: name, counter: counter}
  end

  # A render that takes a while, counting renders (1) and the peak of
  # renders running at once (2).
  defp render(counter, running) do
    now = :atomics.add_get(running, 1, 1)
    if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
    :counters.add(counter, 1, 1)
    Process.sleep(50)
    :atomics.sub(running, 1, 1)
    :rendered
  end

  test "one render per key: the others wait and find it cached", %{
    server: server,
    counter: counter
  } do
    cache = :atomics.new(1, [])
    running = :atomics.new(1, [])

    results =
      for _ <- 1..8 do
        Task.async(fn ->
          RenderQueue.run(
            "same-key",
            fn ->
              if :atomics.get(cache, 1) == 1 do
                :cached
              else
                result = render(counter, running)
                :atomics.put(cache, 1, 1)
                result
              end
            end,
            server: server
          )
        end)
      end
      |> Task.await_many()

    assert :counters.get(counter, 1) == 1
    assert Enum.frequencies(results) == %{rendered: 1, cached: 7}
  end

  test "at most :max renders at once", %{server: server, counter: counter} do
    running = :atomics.new(1, [])

    for n <- 1..6 do
      Task.async(fn -> RenderQueue.run(n, fn -> render(counter, running) end, server: server) end)
    end
    |> Task.await_many()

    assert :counters.get(counter, 1) == 6
    assert :counters.get(counter, 2) == 2
  end

  test "gives up after waiting, and frees slots of callers that crash", %{server: server} do
    test = self()

    holder =
      spawn(fn ->
        RenderQueue.run(:a, fn -> send(test, :holding) && Process.sleep(:infinity) end,
          server: server
        )
      end)

    assert_receive :holding
    assert RenderQueue.run(:a, fn -> :never end, server: server, wait: 50) == {:error, :busy}

    Process.exit(holder, :kill)
    assert RenderQueue.run(:a, fn -> :ok end, server: server, wait: 1_000) == :ok
  end
end
