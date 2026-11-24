defmodule Readout.Documents.Sheets do
  @moduledoc """
  Spreadsheets (CSV, XLSX, ODS) shown as tables and charts.

  XLSX and ODS are exported sheet by sheet to CSV with LibreOffice (formula
  results, not formulas); CSV files are read directly. Each sheet becomes a
  "page" of the version: its text is indexed for search, its rows are stored
  as JSON (`sheets/<n>.json`) for the viewer, and its time is tracked like a
  page's.

  Limits keep the viewer fast: #{20_000} rows and #{200} columns per sheet,
  #{1_000} characters per cell. Truncation is recorded and shown.
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
    with {:ok, binary} <- File.read(input) do
      case parse_csv(binary) do
        [] -> {:error, :no_pages}
        rows -> {:ok, [build_sheet("Sheet 1", rows)]}
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
          rows = path |> String.trim() |> File.read!() |> parse_csv()
          build_sheet(name, rows)
        end
        |> Enum.reject(&(&1.header == [] and &1.rows == []))

      if sheets == [], do: {:error, :no_pages}, else: {:ok, sheets}
    end
  end

  defp build_sheet(name, rows) do
    rows = Enum.map(rows, &Enum.map(&1, fn cell -> String.slice(cell, 0, @max_cell) end))

    {rows, truncated?} =
      if length(rows) > @max_rows + 1,
        do: {Enum.take(rows, @max_rows + 1), true},
        else: {rows, false}

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

  @doc "Parses CSV text into rows of strings. Handles quotes, escaped quotes and newlines in quotes."
  def parse_csv(binary) do
    text = binary |> to_utf8() |> String.trim_leading("﻿")
    delimiter = sniff_delimiter(text)
    do_parse(text, delimiter, [], [], [], false)
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

  # A small state machine over the binary. State: {delimiter, field (reversed
  # chunks), row (reversed cells), rows (reversed), row count, in quotes?}.
  defp do_parse(text, d, field, row, rows, quoted?),
    do: parse(text, {d, field, row, rows, 0, quoted?})

  defp parse("", {_d, field, row, rows, _n, _q}), do: finish(field, row, rows)

  defp parse(<<?", ?", rest::binary>>, {d, f, r, rs, n, true}),
    do: parse(rest, {d, [?" | f], r, rs, n, true})

  defp parse(<<?", rest::binary>>, {d, f, r, rs, n, true}),
    do: parse(rest, {d, f, r, rs, n, false})

  defp parse(<<?", rest::binary>>, {d, [], r, rs, n, false}),
    do: parse(rest, {d, [], r, rs, n, true})

  defp parse(<<c::utf8, rest::binary>>, {d, f, r, rs, n, true}),
    do: parse(rest, {d, [<<c::utf8>> | f], r, rs, n, true})

  defp parse(<<"\r\n", rest::binary>>, {_d, _f, _r, _rs, _n, false} = st), do: next_row(rest, st)
  defp parse(<<"\n", rest::binary>>, {_d, _f, _r, _rs, _n, false} = st), do: next_row(rest, st)

  defp parse(<<c::utf8, rest::binary>> = bin, {d, f, r, rs, n, false}) do
    if String.starts_with?(bin, d) do
      skip = byte_size(d)
      parse(binary_part(bin, skip, byte_size(bin) - skip), {d, [], [cell(f) | r], rs, n, false})
    else
      parse(rest, {d, [<<c::utf8>> | f], r, rs, n, false})
    end
  end

  # Invalid bytes (shouldn't happen after to_utf8/1): skip them.
  defp parse(<<_byte, rest::binary>>, st), do: parse(rest, st)

  defp next_row(rest, {d, f, r, rs, n, false}) do
    rows = [Enum.reverse([cell(f) | r]) | rs]
    # Stop reading far beyond what the viewer keeps.
    if n + 1 > @max_rows + 1,
      do: Enum.reverse(rows),
      else: parse(rest, {d, [], [], rows, n + 1, false})
  end

  defp finish([], [], rows), do: Enum.reverse(rows)
  defp finish(field, row, rows), do: Enum.reverse([Enum.reverse([cell(field) | row]) | rows])

  defp cell(field), do: field |> Enum.reverse() |> IO.iodata_to_binary()

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
