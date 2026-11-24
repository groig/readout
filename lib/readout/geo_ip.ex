defmodule Readout.GeoIP do
  @moduledoc """
  IP → approximate location (country, city) for "anonymous viewer from
  Madrid, Spain" in analytics.

  Reads a MaxMind DB (`.mmdb`) file such as DB-IP Lite (CC BY 4.0,
  <https://db-ip.com>) or GeoLite2, given by `GEOIP_DB_PATH`. Lookups happen in
  memory; nothing is sent anywhere. Without a database, `lookup/1` returns nil
  and the UI shows the IP only.

  This is a small, self-contained reader of the documented MMDB format
  (<https://maxmind.github.io/MaxMind-DB/>): the binary search tree, then the
  data section (maps, strings, numbers, pointers).
  """
  import Bitwise
  require Logger

  @metadata_marker <<0xAB, 0xCD, 0xEF, "MaxMind.com">>

  @type location :: %{country_code: String.t() | nil, country: map(), city: map()}

  @doc "Looks up an IP (tuple or string). Returns a location or nil."
  @spec lookup(:inet.ip_address() | String.t() | nil) :: location() | nil
  def lookup(nil), do: nil

  def lookup(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> lookup(tuple)
      _ -> nil
    end
  end

  def lookup(ip) when is_tuple(ip) do
    with %{} = db <- database(),
         {:ok, record} <- find(db, ip) do
      to_location(record)
    else
      _ -> nil
    end
  end

  defp to_location(%{} = record) do
    country = record["country"] || record["registered_country"] || %{}
    city = record["city"] || %{}

    %{
      country_code: country["iso_code"],
      country: country["names"] || %{},
      city: city["names"] || %{}
    }
  end

  defp to_location(_), do: nil

  @doc "A short label in the given locale: \"Madrid, Spain\", or the country alone."
  def label(nil, _locale), do: nil

  def label(%{} = loc, locale) do
    name = fn names -> names[locale] || names["en"] end

    [name.(loc[:city] || loc["city"] || %{}), name.(loc[:country] || loc["country"] || %{})]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  ## Database loading (once, cached)

  @doc false
  def database do
    case :persistent_term.get({__MODULE__, :db}, :unloaded) do
      :unloaded -> load()
      db -> db
    end
  end

  @doc "Reloads the database (e.g. after updating the file)."
  def reload do
    :persistent_term.erase({__MODULE__, :db})
    load()
  end

  defp load do
    db =
      with path when is_binary(path) and path != "" <-
             Application.get_env(:readout, :geoip_db_path),
           {:ok, binary} <- File.read(path),
           {:ok, db} <- open(binary) do
        Logger.info("GeoIP database loaded: #{db.description}")
        db
      else
        {:error, reason} ->
          Logger.warning("GeoIP database not loaded: #{inspect(reason)}")
          nil

        _ ->
          nil
      end

    :persistent_term.put({__MODULE__, :db}, db)
    db
  end

  @doc false
  # Parses an MMDB binary into the structure `find/2` needs.
  def open(binary) do
    case :binary.matches(binary, @metadata_marker) do
      [] ->
        {:error, :not_an_mmdb}

      matches ->
        {pos, len} = List.last(matches)
        meta_start = pos + len
        {meta, _} = decode(binary, meta_start, meta_start)

        node_count = meta["node_count"]
        record_size = meta["record_size"]
        tree_size = div(record_size * 2, 8) * node_count
        data_start = tree_size + 16

        {:ok,
         %{
           binary: binary,
           node_count: node_count,
           record_size: record_size,
           ip_version: meta["ip_version"],
           data_start: data_start,
           ipv4_start:
             if(meta["ip_version"] == 6, do: ipv4_start(binary, node_count, record_size), else: 0),
           description: get_in(meta, ["description", "en"]) || meta["database_type"]
         }}
    end
  rescue
    _ -> {:error, :invalid_mmdb}
  end

  # In IPv6 trees, IPv4 addresses live under ::/96; find that node once.
  defp ipv4_start(binary, node_count, record_size) do
    Enum.reduce_while(1..96, 0, fn _, node ->
      if node >= node_count,
        do: {:halt, node},
        else: {:cont, read_record(binary, node, 0, record_size)}
    end)
  end

  ## Lookup

  @doc false
  def find(db, ip) do
    {bits, bit_count} = ip_bits(ip)

    start =
      cond do
        tuple_size(ip) == 4 and db.ip_version == 6 -> db.ipv4_start
        tuple_size(ip) == 8 and db.ip_version == 4 -> :mismatch
        true -> 0
      end

    if start == :mismatch, do: :not_found, else: walk(db, bits, bit_count, 0, start)
  end

  defp walk(db, bits, bit_count, depth, node) do
    cond do
      node == db.node_count ->
        :not_found

      node > db.node_count ->
        offset = node - db.node_count - 16
        {value, _} = decode(db.binary, db.data_start + offset, db.data_start)
        {:ok, value}

      depth >= bit_count ->
        :not_found

      true ->
        bit = bits >>> (bit_count - 1 - depth) &&& 1
        walk(db, bits, bit_count, depth + 1, read_record(db.binary, node, bit, db.record_size))
    end
  end

  defp ip_bits({a, b, c, d}), do: {(a <<< 24) + (b <<< 16) + (c <<< 8) + d, 32}

  defp ip_bits(ip) when tuple_size(ip) == 8,
    do: {ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< 16) + &1)), 128}

  defp read_record(binary, node, side, 24) do
    <<left::24, right::24>> = binary_part(binary, node * 6, 6)
    if side == 0, do: left, else: right
  end

  defp read_record(binary, node, side, 28) do
    <<l1::24, l_hi::4, r_hi::4, r1::24>> = binary_part(binary, node * 7, 7)
    if side == 0, do: (l_hi <<< 24) + l1, else: (r_hi <<< 24) + r1
  end

  defp read_record(binary, node, side, 32) do
    <<left::32, right::32>> = binary_part(binary, node * 8, 8)
    if side == 0, do: left, else: right
  end

  ## Data section decoder

  @doc false
  # Decodes the value at `offset`. Pointers are relative to `base` (the data
  # section start). Returns {value, next_offset}.
  def decode(binary, offset, base) do
    <<control>> = binary_part(binary, offset, 1)
    type = control >>> 5
    offset = offset + 1

    {type, offset} =
      if type == 0 do
        <<ext>> = binary_part(binary, offset, 1)
        {ext + 7, offset + 1}
      else
        {type, offset}
      end

    if type == 1 do
      decode_pointer(binary, control, offset, base)
    else
      {size, offset} = decode_size(binary, control &&& 0x1F, offset)
      decode_value(binary, type, size, offset, base)
    end
  end

  defp decode_pointer(binary, control, offset, base) do
    ss = control >>> 3 &&& 0x3
    vvv = control &&& 0x7

    {pointer, next} =
      case ss do
        0 ->
          <<b>> = binary_part(binary, offset, 1)
          {(vvv <<< 8) + b, offset + 1}

        1 ->
          <<b::16>> = binary_part(binary, offset, 2)
          {(vvv <<< 16) + b + 2048, offset + 2}

        2 ->
          <<b::24>> = binary_part(binary, offset, 3)
          {(vvv <<< 24) + b + 526_336, offset + 3}

        3 ->
          <<b::32>> = binary_part(binary, offset, 4)
          {b, offset + 4}
      end

    {value, _} = decode(binary, base + pointer, base)
    {value, next}
  end

  defp decode_size(_binary, size, offset) when size < 29, do: {size, offset}

  defp decode_size(binary, 29, offset) do
    <<b>> = binary_part(binary, offset, 1)
    {29 + b, offset + 1}
  end

  defp decode_size(binary, 30, offset) do
    <<b::16>> = binary_part(binary, offset, 2)
    {285 + b, offset + 2}
  end

  defp decode_size(binary, 31, offset) do
    <<b::24>> = binary_part(binary, offset, 3)
    {65_821 + b, offset + 3}
  end

  # 2 utf8, 3 double, 4 bytes, 5 uint16, 6 uint32, 7 map, 8 int32, 9 uint64,
  # 10 uint128, 11 array, 14 boolean, 15 float
  defp decode_value(binary, 2, size, offset, _base),
    do: {binary_part(binary, offset, size), offset + size}

  defp decode_value(binary, 3, 8, offset, _base) do
    <<f::float-64>> = binary_part(binary, offset, 8)
    {f, offset + 8}
  end

  defp decode_value(binary, 4, size, offset, _base),
    do: {binary_part(binary, offset, size), offset + size}

  defp decode_value(binary, type, size, offset, _base) when type in [5, 6, 9, 10] do
    bits = size * 8
    <<n::unsigned-size(bits)>> = binary_part(binary, offset, size)
    {n, offset + size}
  end

  defp decode_value(binary, 8, size, offset, _base) do
    bits = size * 8
    <<n::signed-size(bits)>> = binary_part(binary, offset, size)
    {n, offset + size}
  end

  defp decode_value(binary, 7, size, offset, base) do
    Enum.reduce(1..size//1, {%{}, offset}, fn _, {acc, off} ->
      {key, off} = decode(binary, off, base)
      {value, off} = decode(binary, off, base)
      {Map.put(acc, key, value), off}
    end)
  end

  defp decode_value(binary, 11, size, offset, base) do
    {items, off} =
      Enum.reduce(1..size//1, {[], offset}, fn _, {acc, off} ->
        {value, off} = decode(binary, off, base)
        {[value | acc], off}
      end)

    {Enum.reverse(items), off}
  end

  defp decode_value(_binary, 14, size, offset, _base), do: {size == 1, offset}

  defp decode_value(binary, 15, 4, offset, _base) do
    <<f::float-32>> = binary_part(binary, offset, 4)
    {f, offset + 4}
  end

  defp decode_value(_binary, _type, size, offset, _base), do: {nil, offset + size}
end
