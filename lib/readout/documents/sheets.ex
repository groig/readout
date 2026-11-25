defmodule Readout.Documents.Sheets do
  @moduledoc """
  Spreadsheets (CSV, XLSX, ODS) shown as tables and charts.

  XLSX and ODS are exported sheet by sheet to CSV with LibreOffice (formula
  results, not formulas); CSV files are read directly. Each sheet becomes a
  "page" of the version: its text is indexed for search, its rows are stored
  as JSON (`sheets/<n>.json`) for the viewer, and its time is tracked like a
  page's.

  Limits keep the viewer fast and the server safe: #{20_000} rows and
  #{200} columns per sheet, #{1_000} characters per cell, and at most
  `:sheet_max_mb` (32 MB) of CSV read per sheet. They apply while reading,
  before anything is kept. Truncation is recorded and shown.
  """

  alias Readout.Documents.{Tools, Version}
  alias Readout.Storage

  @max_rows 20_000
  @max_cols 200
  @max_cell 1_000

  @type sheet :: %{
          name: String.t(),
          header: [String.t()],
          rows: [[String.t()]],
          numeric: [boolean()],
          truncated: boolean()
        }

  @doc "Reads every sheet of a spreadsheet file."
  @spec extract(Path.t(), atom(), Path.t()) :: {:ok, [sheet()]} | {:error, term()}
  def extract(input, :csv, _workdir) do
    with {:ok, binary, cut?} <- read_capped(input) do
      case parse_csv(binary) do
        [] -> {:error, :no_pages}
        rows -> {:ok, [build_sheet("Sheet 1", rows, cut?)]}
      end
    end
  end

  def extract(input, format, workdir) when format in [:xlsx, :ods] do
    out = Path.join(workdir, "sheets")
    File.mkdir_p!(out)
    profile = Path.join(workdir, "lo-profile")
    Readout.Documents.Converters.LibreOffice.write_profile!(profile)

    filter = "csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,-1"

    args = [
      "-env:UserInstallation=file://#{profile}",
      "--headless",
      "--norestore",
      "--nolockcheck",
      "--convert-to",
      filter,
      "--outdir",
      out,
      input
    ]

    with {:ok, output} <- Tools.run("soffice", args, env: [{"HOME", profile}]) do
      # "Writing sheet <name> -> <path>", in workbook order.
      sheets =
        for [_, name, path] <- Regex.scan(~r/Writing sheet (.+?) -> (.+\.csv)/, output),
            File.regular?(String.trim(path)) do
          {:ok, binary, cut?} = path |> String.trim() |> read_capped()
          build_sheet(name, parse_csv(binary), cut?)
        end
        |> Enum.reject(&(&1.header == [] and &1.rows == []))

      if sheets == [], do: {:error, :no_pages}, else: {:ok, sheets}
    end
  end

  # Reads at most `:sheet_max_mb` of a CSV file, cut at the last line break.
  defp read_capped(path) do
    max = (Application.get_env(:readout, Readout.Documents)[:sheet_max_mb] || 32) * 1024 * 1024

    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, max + 1) do
          data when is_binary(data) and byte_size(data) > max ->
            data = binary_part(data, 0, max)

            case :binary.matches(data, "\n") do
              [] -> {:ok, data, true}
              matches -> {:ok, binary_part(data, 0, elem(List.last(matches), 0)), true}
            end

          data when is_binary(data) ->
            {:ok, data, false}

          _ ->
            {:ok, "", false}
        end
      after
        File.close(io)
      end
    end
  end

  defp build_sheet(name, rows, cut?) do
    {rows, truncated?} =
      if length(rows) > @max_rows + 1,
        do: {Enum.take(rows, @max_rows + 1), true},
        else: {rows, cut?}

    width = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end) |> min(@max_cols)
    rows = Enum.map(rows, fn row -> row |> Enum.take(width) |> pad(width) end)
    rows = trim_empty_tail(rows)

    {header, body} =
      case rows do
        [] -> {[], []}
        [header | body] -> {header, body}
      end

    %{
      name: name,
      header: header,
      rows: body,
      numeric: numeric_columns(body, width),
      truncated: truncated?
    }
  end

  defp pad(row, width) when length(row) < width,
    do: row ++ List.duplicate("", width - length(row))

  defp pad(row, _width), do: row

  defp trim_empty_tail(rows) do
    rows
    |> Enum.reverse()
    |> Enum.drop_while(&Enum.all?(&1, fn c -> String.trim(c) == "" end))
    |> Enum.reverse()
  end

  # A column is numeric when at least 80% of its non-empty cells are numbers.
  defp numeric_columns(rows, width) do
    for col <- 0..(width - 1)//1 do
      values = for row <- rows, cell = Enum.at(row, col), String.trim(cell) != "", do: cell
      values != [] and Enum.count(values, &(parse_number(&1) != nil)) >= length(values) * 0.8
    end
  end

  @doc """
  Parses a number as people write it: `1,234.5`, `1.234,5`, `12%`, `€ 30`,
  `(45)`. Returns a float or nil.
  """
  def parse_number(text) when is_binary(text) do
    cleaned = text |> String.trim() |> String.replace(~r/[\s€$£%]/u, "")
    negative? = String.starts_with?(cleaned, "(") and String.ends_with?(cleaned, ")")

    cleaned =
      if negative?,
        do: cleaned |> String.trim_leading("(") |> String.trim_trailing(")"),
        else: cleaned

    normalized =
      cond do
        cleaned =~ ~r/^-?\d{1,3}(\.\d{3})+(,\d+)?$/ ->
          cleaned |> String.replace(".", "") |> String.replace(",", ".")

        cleaned =~ ~r/^-?\d{1,3}(,\d{3})+(\.\d+)?$/ ->
          String.replace(cleaned, ",", "")

        cleaned =~ ~r/^-?\d+,\d+$/ ->
          String.replace(cleaned, ",", ".")

        true ->
          cleaned
      end

    case Float.parse(normalized) do
      {n, ""} -> if negative?, do: -n, else: n
      _ -> nil
    end
  end

  ## CSV (RFC 4180, with a sniffed delimiter)

  @doc """
  Parses CSV text into rows of strings. Handles quotes, escaped quotes and
  newlines in quotes. Fields are sliced out of the input (never built a
  character at a time), and the limits apply while parsing: at most
  #{@max_rows + 1} rows, #{@max_cols} cells per row, #{@max_cell} characters
  per cell.
  """
  def parse_csv(binary) do
    text = binary |> to_utf8() |> String.trim_leading("\uFEFF")
    field(text, sniff_delimiter(text), [], 0, [], 0)
  end

  defp to_utf8(binary) do
    if String.valid?(binary), do: binary, else: :unicode.characters_to_binary(binary, :latin1)
  end

  # The most frequent of , ; and tab on the first line (outside quotes).
  defp sniff_delimiter(text) do
    first =
      text |> String.split(["\r\n", "\n"], parts: 2) |> hd() |> String.replace(~r/"[^"]*"/, "")

    [",", ";", "\t"]
    |> Enum.max_by(&(first |> String.split(&1) |> length()))
  end

  # At the start of a field. `cells` is the current row (reversed), `nc` its
  # cell count; `rows` the finished rows (reversed), `n` their count.
  defp field("", _d, [], _nc, rows, _n), do: Enum.reverse(rows)

  defp field(<<?", rest::binary>>, d, cells, nc, rows, n),
    do: quoted(rest, d, [], cells, nc, rows, n)

  defp field(bin, d, cells, nc, rows, n) do
    case :binary.match(bin, [d, "\r\n", "\n"]) do
      :nomatch ->
        end_field("", :end, bin, d, cells, nc, rows, n)

      {pos, len} ->
        rest = binary_part(bin, pos + len, byte_size(bin) - pos - len)

        end_field(
          rest,
          binary_part(bin, pos, len),
          binary_part(bin, 0, pos),
          d,
          cells,
          nc,
          rows,
          n
        )
    end
  end

  # Inside quotes: up to the next quote; "" is an escaped quote. Text between
  # the closing quote and the separator is kept (leniently).
  defp quoted(bin, d, acc, cells, nc, rows, n) do
    case :binary.match(bin, "\"") do
      :nomatch ->
        end_field("", :end, [acc, bin], d, cells, nc, rows, n)

      {pos, 1} ->
        chunk = binary_part(bin, 0, pos)

        case binary_part(bin, pos + 1, byte_size(bin) - pos - 1) do
          <<?", more::binary>> ->
            quoted(more, d, [acc, chunk, ?"], cells, nc, rows, n)

          rest ->
            case :binary.match(rest, [d, "\r\n", "\n"]) do
              :nomatch ->
                end_field("", :end, [acc, chunk, rest], d, cells, nc, rows, n)

              {p, l} ->
                after_sep = binary_part(rest, p + l, byte_size(rest) - p - l)
                value = [acc, chunk, binary_part(rest, 0, p)]
                end_field(after_sep, binary_part(rest, p, l), value, d, cells, nc, rows, n)
            end
        end
    end
  end

  defp end_field(rest, sep, value, d, cells, nc, rows, n) do
    cells = if nc < @max_cols, do: [cell(value) | cells], else: cells

    cond do
      sep == d ->
        # A delimiter at the very end leaves one empty last cell.
        if rest == "",
          do: Enum.reverse([Enum.reverse(["" | cells]) | rows]),
          else: field(rest, d, cells, nc + 1, rows, n)

      sep == :end ->
        Enum.reverse([Enum.reverse(cells) | rows])

      # One row past what the viewer keeps is enough to know it's truncated.
      n + 1 > @max_rows + 1 ->
        Enum.reverse([Enum.reverse(cells) | rows])

      true ->
        field(rest, d, [], 0, [Enum.reverse(cells) | rows], n + 1)
    end
  end

  # At most @max_cell characters, copied out of the input.
  defp cell(value) do
    value
    |> IO.iodata_to_binary()
    |> String.slice(0, @max_cell)
    |> :binary.copy()
  end

  ## Storage

  @doc "Stores each sheet as JSON next to the version's other files."
  def store(%Version{} = version, sheets) do
    sheets
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {sheet, n}, :ok ->
      tmp =
        Path.join(System.tmp_dir!(), "readout-sheet-#{System.unique_integer([:positive])}.json")

      File.write!(tmp, Jason.encode!(sheet))

      result = Storage.put_file(sheet_key(version, n), tmp)
      File.rm(tmp)
      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  def sheet_key(%Version{} = version, n), do: "#{Version.prefix(version)}/sheets/#{n}.json"

  @doc "Loads one stored sheet (string keys, as decoded)."
  def load(%Version{} = version, n) do
    with {:path, path} <- Storage.serve(sheet_key(version, n)),
         {:ok, json} <- File.read(path),
         {:ok, sheet} <- Jason.decode(json) do
      {:ok, sheet}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The sheet's text for search: header and rows, tab-separated."
  def text(sheet) do
    [sheet.header | sheet.rows]
    |> Enum.map_join("\n", &Enum.join(&1, "\t"))
    |> String.replace(<<0>>, "")
    |> String.slice(0, 500_000)
  end
end
