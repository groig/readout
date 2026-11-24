defmodule Readout.CSV do
  @moduledoc """
  Writes CSV (RFC 4180, CRLF line ends, UTF-8 with a BOM so Excel reads
  accents). Cells that a spreadsheet would run as a formula (starting with
  `= + - @`, tab or carriage return) are prefixed with an apostrophe:
  visitor-typed values such as emails end up in these files.
  """

  @doc "Encodes rows (lists of values) as iodata."
  def encode(rows) do
    ["\uFEFF" | Enum.map(rows, &[Enum.map_intersperse(&1, ",", fn v -> cell(v) end), "\r\n"])]
  end

  defp cell(nil), do: ""
  defp cell(v) when is_integer(v), do: Integer.to_string(v)
  defp cell(v) when is_float(v), do: :erlang.float_to_binary(v, [:compact, decimals: 2])
  defp cell(true), do: "true"
  defp cell(false), do: "false"

  defp cell(v) when is_binary(v) do
    v = if v =~ ~r/\A[=+\-@\t\r]/, do: "'" <> v, else: v

    if v =~ ~r/[",\r\n]/,
      do: [?", String.replace(v, "\"", "\"\""), ?"],
      else: v
  end

  defp cell(v), do: cell(to_string(v))
end
