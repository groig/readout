defmodule Readout.Documents.Pdf do
  @moduledoc """
  PDF work with poppler: metadata (`pdfinfo`), page images (`pdftoppm` to PNG,
  then `cwebp`) and per-page text (`pdftotext`).
  """

  alias Readout.Documents.Tools

  @doc "Image widths rendered for every page: thumbnails and full view."
  def widths, do: [thumb_width(), view_width()]
  def thumb_width, do: 480
  def view_width, do: 1600

  @doc """
  Reads page count, per-page sizes (points) and document metadata.
  """
  def info(pdf) do
    with {:ok, out} <- Tools.run("pdfinfo", [pdf]),
         {:ok, pages} <- parse_pages(out),
         {:ok, sizes_out} <-
           Tools.run("pdfinfo", ["-f", "1", "-l", Integer.to_string(pages), pdf]) do
      # Password-protected PDFs make pdfinfo exit with an error before this.
      metadata =
        out
        |> parse_fields()
        |> Map.take(["Title", "Author", "Creator", "Producer", "Page size"])
        |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

      {:ok, %{page_count: pages, sizes: parse_sizes(sizes_out, pages), metadata: metadata}}
    end
  end

  defp parse_fields(out) do
    for line <- String.split(out, "\n"),
        [k, v] <- [String.split(line, ":", parts: 2)],
        into: %{},
        do: {String.trim(k), String.trim(v)}
  end

  defp parse_pages(out) do
    case Regex.run(~r/^Pages:\s+(\d+)/m, out) do
      [_, n] when n != "0" -> {:ok, String.to_integer(n)}
      _ -> {:error, :no_pages}
    end
  end

  defp parse_sizes(out, pages) do
    sizes =
      for [_, n, w, h] <- Regex.scan(~r/^Page\s+(\d+) size:\s+([\d.]+) x ([\d.]+)/m, out),
          into: %{},
          do: {String.to_integer(n), {parse_float(w), parse_float(h)}}

    default = Map.get(sizes, 1, {595.0, 842.0})
    for n <- 1..pages, do: Map.get(sizes, n, default)
  end

  defp parse_float(s) do
    {f, _} = Float.parse(s)
    f
  end

  @doc """
  Renders every page at `width` pixels to WebP files in `out_dir`. Returns
  `%{page_number => path}`.
  """
  def render(pdf, width, out_dir) do
    prefix = Path.join(out_dir, "p#{width}")

    args = ["-png", "-scale-to-x", Integer.to_string(width), "-scale-to-y", "-1", pdf, prefix]

    with {:ok, _} <- Tools.run("pdftoppm", args) do
      pngs =
        out_dir
        |> Path.join("p#{width}-*.png")
        |> Path.wildcard()
        |> Map.new(fn png ->
          [_, n] = Regex.run(~r/-(\d+)\.png$/, png)
          {String.to_integer(n), png}
        end)

      quality = if width <= thumb_width(), do: "72", else: "82"

      pngs
      |> Task.async_stream(
        fn {n, png} ->
          webp = String.replace_suffix(png, ".png", ".webp")

          case Tools.run("cwebp", ["-quiet", "-q", quality, "-m", "4", png, "-o", webp]) do
            {:ok, _} -> {n, webp}
            error -> error
          end
        end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {n, webp}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, n, webp)}}
        {:ok, error}, _ -> {:halt, error}
      end)
    end
  end

  @doc "Extracts the text of every page, in order."
  def text(pdf, page_count) do
    with {:ok, out} <- Tools.run("pdftotext", ["-enc", "UTF-8", "-layout", pdf, "-"]) do
      pages =
        out
        |> String.split("\f")
        |> Enum.map(&clean_text/1)

      {:ok, for(n <- 0..(page_count - 1), do: Enum.at(pages, n, ""))}
    end
  end

  # Postgres text can't hold NUL bytes; also drop invalid UTF-8 and trailing space.
  defp clean_text(text) do
    text
    |> String.replace(<<0>>, "")
    |> String.replace_invalid("")
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.trim()
  end
end
