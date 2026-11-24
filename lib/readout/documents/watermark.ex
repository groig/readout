defmodule Readout.Documents.Watermark do
  @moduledoc """
  Watermarks burned into the pixels of page images, for links with
  `watermark` on.

  The text is the reader's email (or "anonymous"), the visit's start time and
  a short visit id, tiled diagonally (ImageMagick). Each image is rendered the
  first time a visit asks for it and cached on local disk; a daily job removes
  old cache entries. PDF downloads of watermarked links are rebuilt from the
  watermarked pages (`Readout.Documents.PdfWriter`), so they carry it too.

  This survives screenshots of the images and leaked files, and traces a leak
  back to one visit. It doesn't stop someone from retyping the content.
  """

  alias Readout.Documents.{Pdf, PdfWriter, Tools, Version}
  alias Readout.Links.Visit
  alias Readout.{Documents, Storage}

  @doc "The text stamped on every page of a visit."
  def text(%Visit{} = visit) do
    who = visit.email || "anonymous"
    stamp = Calendar.strftime(visit.started_at, "%Y-%m-%d %H:%M UTC")
    short = visit.id |> String.replace("-", "") |> String.slice(0, 8)
    "#{who} · #{stamp} · ##{short}"
  end

  @doc "A watermarked page image for a visit (cached). Returns a local path."
  def page_image(%Visit{} = visit, %Version{} = version, number, width) do
    dest = cache_path(visit, "p#{number}-#{width}.webp")

    if File.regular?(dest) do
      {:ok, dest}
    else
      with {:path, source} <- Storage.serve(Version.page_key(version, number, width)),
           :ok <- render(source, text(visit), dest, width) do
        {:ok, dest}
      else
        {:error, _} = error -> error
        _ -> {:error, :not_found}
      end
    end
  end

  @doc """
  A watermarked PDF of the whole version for a visit (cached): every page at
  full width, as JPEG, at the original page size.
  """
  def pdf(%Visit{} = visit, %Version{} = version) do
    dest = cache_path(visit, "document.pdf")

    if File.regular?(dest) do
      {:ok, dest}
    else
      width = Pdf.view_width()
      pages = Documents.list_pages(version)

      jpegs =
        Enum.reduce_while(pages, {:ok, []}, fn page, {:ok, acc} ->
          jpeg = cache_path(visit, "p#{page.number}-#{width}.jpg")

          with {:path, source} <- Storage.serve(Version.page_key(version, page.number, width)),
               :ok <- (File.regular?(jpeg) && :ok) || render(source, text(visit), jpeg, width) do
            {:cont, {:ok, [{jpeg, page.width, page.height} | acc]}}
          else
            error -> {:halt, error}
          end
        end)

      with {:ok, list} <- jpegs,
           :ok <- PdfWriter.write(Enum.reverse(list), dest) do
        {:ok, dest}
      end
    end
  end

  @doc false
  def render(source, text, dest, width) do
    File.mkdir_p!(Path.dirname(dest))
    # Scale the type and the tile with the image so thumbnails look the same.
    point = max(9, round(width * 0.015))
    tile_w = round(width * 0.4)
    tile_h = round(width * 0.225)
    quality = if String.ends_with?(dest, ".jpg"), do: "85", else: "82"

    args =
      [
        source,
        "(",
        "-size",
        "#{tile_w}x#{tile_h}",
        "xc:none",
        "-pointsize",
        Integer.to_string(point),
        "-fill",
        "rgba(20,20,40,0.16)",
        "-gravity",
        "center",
        "-annotate",
        "-28x-28+0+0",
        text,
        "-write",
        "mpr:tile",
        "+delete",
        ")",
        "(",
        "+clone",
        "-tile",
        "mpr:tile",
        "-draw",
        "color 0,0 reset",
        ")",
        "-composite",
        "-quality",
        quality,
        # The format is explicit: the temporary ".part" name says nothing.
        if(String.ends_with?(dest, ".jpg"), do: "jpg:", else: "webp:") <> dest <> ".part"
      ]
      |> with_font()

    case Tools.run(magick(), args) do
      {:ok, _} -> File.rename(dest <> ".part", dest)
      error -> error
    end
  end

  # ImageMagick 7 is `magick`; 6 is `convert`.
  defp magick, do: if(System.find_executable("magick"), do: "magick", else: "convert")

  # A font file (names don't always resolve); found once with fontconfig.
  defp with_font([source | rest]) do
    case font() do
      nil -> [source | rest]
      path -> [source, "-font", path | rest]
    end
  end

  def font do
    case :persistent_term.get({__MODULE__, :font}, :unknown) do
      :unknown ->
        path =
          case System.cmd("fc-match", ["-f", "%{file}", "DejaVu Sans:style=Book"],
                 stderr_to_stdout: true
               ) do
            {path, 0} -> if File.regular?(path), do: path
            _ -> nil
          end

        :persistent_term.put({__MODULE__, :font}, path)
        path

      value ->
        value
    end
  rescue
    ErlangError -> nil
  end

  ## Cache

  def cache_dir,
    do: Application.get_env(:readout, :cache_dir) || Path.join(System.tmp_dir!(), "readout-cache")

  defp cache_path(%Visit{id: id}, name), do: Path.join([cache_dir(), "watermarks", id, name])

  @doc "Removes cached watermarks older than `max_age_seconds`."
  def prune(max_age_seconds \\ 2 * 24 * 3600) do
    root = Path.join(cache_dir(), "watermarks")
    cutoff = System.os_time(:second) - max_age_seconds

    for dir <- Path.wildcard(Path.join(root, "*")),
        {:ok, %File.Stat{mtime: mtime}} <- [File.stat(dir, time: :posix)],
        mtime < cutoff do
      File.rm_rf(dir)
    end

    :ok
  end
end
