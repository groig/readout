defmodule Readout.GeoIPFixture do
  @moduledoc """
  Writes tiny MaxMind DB files for tests (24-bit records). Enough of the
  format to exercise `Readout.GeoIP`: a search tree and a data section with
  maps, strings and numbers.
  """
  import Bitwise

  @doc """
  Builds an MMDB binary from `[{"81.0.0.0/8", %{...}}]`.
  `ip_version` 4 stores IPv4 directly; 6 nests IPv4 under ::/96.
  """
  def build(entries, ip_version \\ 6) do
    prefixes =
      for {cidr, record} <- entries do
        [addr, len] = String.split(cidr, "/")
        {:ok, ip} = :inet.parse_address(String.to_charlist(addr))
        {bits, width} = bits(ip)
        len = String.to_integer(len)

        {bits, width, len} =
          if width == 32 and ip_version == 6, do: {bits, 128, len + 96}, else: {bits, width, len}

        {for(i <- 0..(len - 1), do: bits >>> (width - 1 - i) &&& 1), record}
      end

    trie = Enum.reduce(prefixes, %{}, fn {path, record}, trie -> insert(trie, path, record) end)
    {nodes, data} = flatten(trie)
    node_count = length(nodes)

    {data_bin, offsets} =
      Enum.reduce(data, {<<>>, []}, fn record, {bin, offs} ->
        {bin <> encode(record), [byte_size(bin) | offs]}
      end)

    offsets = Enum.reverse(offsets)

    resolve = fn
      :empty -> node_count
      {:node, i} -> i
      {:data, i} -> node_count + 16 + Enum.at(offsets, i)
    end

    tree = for {l, r} <- nodes, into: <<>>, do: <<resolve.(l)::24, resolve.(r)::24>>

    meta = %{
      "node_count" => {:uint32, node_count},
      "record_size" => {:uint16, 24},
      "ip_version" => {:uint16, ip_version},
      "database_type" => "Test-City",
      "description" => %{"en" => "Readout test database"}
    }

    tree <>
      :binary.copy(<<0>>, 16) <> data_bin <> <<0xAB, 0xCD, 0xEF, "MaxMind.com">> <> encode(meta)
  end

  defp bits({a, b, c, d}), do: {(a <<< 24) + (b <<< 16) + (c <<< 8) + d, 32}
  defp bits(ip), do: {ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< 16) + &1)), 128}

  # Trie as nested maps: %{0 => subtree | {:leaf, record}, 1 => ...}
  defp insert(_trie, [], record), do: {:leaf, record}

  defp insert(trie, [bit | rest], record) do
    trie = if is_map(trie), do: trie, else: %{}
    Map.put(trie, bit, insert(Map.get(trie, bit, %{}), rest, record))
  end

  # Breadth-first numbering; leaves become data references.
  defp flatten(root) do
    do_flatten([root], 1, [], [])
  end

  defp do_flatten([], _next, nodes, data), do: {Enum.reverse(nodes), Enum.reverse(data)}

  defp do_flatten([node | queue], next, nodes, data) do
    {left, next, queue, data} = child(Map.get(node, 0), next, queue, data)
    {right, next, queue, data} = child(Map.get(node, 1), next, queue, data)
    do_flatten(queue, next, [{left, right} | nodes], data)
  end

  defp child(nil, next, queue, data), do: {:empty, next, queue, data}
  defp child(%{} = m, next, queue, data) when map_size(m) == 0, do: {:empty, next, queue, data}

  defp child({:leaf, record}, next, queue, data),
    do: {{:data, length(data)}, next, queue, [record | data]}

  defp child(%{} = sub, next, queue, data), do: {{:node, next}, next + 1, queue ++ [sub], data}

  ## Encoding

  defp encode(s) when is_binary(s), do: control(2, byte_size(s)) <> s
  defp encode({:uint16, n}), do: control(5, 2) <> <<n::16>>
  defp encode({:uint32, n}), do: control(6, 4) <> <<n::32>>
  defp encode(n) when is_integer(n), do: control(6, 4) <> <<n::32>>

  defp encode(%{} = map) do
    Enum.reduce(map, control(7, map_size(map)), fn {k, v}, acc ->
      acc <> encode(k) <> encode(v)
    end)
  end

  defp control(type, size) when size < 29, do: <<type <<< 5 ||| size>>
end
