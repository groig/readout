defmodule Readout.Documents.ProcessVersion do
  @moduledoc """
  Background job that makes an uploaded version viewable:

    1. Office files → PDF (`Readout.Documents.Converter`); the original is kept.
    2. Page count, page sizes and metadata (`pdfinfo`).
    3. Every page rendered to WebP at two widths (thumbnails and viewing).
    4. The text of every page (search now, AI later).

  Work happens in a throwaway temporary directory. Transient failures are
  retried; after the last attempt the version is marked failed with a reason
  people can read.
  """
  use Oban.Worker,
    queue: :documents,
    max_attempts: 3,
    unique: [period: 300, keys: [:version_id], states: [:available, :scheduled, :executing]]

  require Logger

  alias Readout.{Documents, Repo, Storage}
  alias Readout.Documents.{Converter, FileType, Pdf, Version}

  def new_job(%Version{id: id}), do: new(%{version_id: id})

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(20)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"version_id" => id}, attempt: attempt, max_attempts: max}) do
    case Repo.get(Version, id) do
      nil ->
        {:cancel, :version_not_found}

      %Version{status: :ready} ->
        :ok

      version ->
        version = Documents.mark_processing(version)

        case process(version) do
          {:ok, _version} ->
            :ok

          {:error, reason} ->
            Logger.warning("Processing version #{id} failed: #{inspect(reason)}")

            if attempt >= max or permanent?(reason) do
              Documents.fail_version(version, describe(reason))
              {:cancel, reason}
            else
              {:error, reason}
            end
        end
    end
  end

  defp process(version) do
    workdir =
      Path.join(System.tmp_dir!(), "readout-#{version.id}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)

    try do
      input = Path.join(workdir, "original" <> FileType.extension(version.format))

      with :ok <- Storage.fetch_file(version.original_key, input),
           {:ok, pdf} <- Converter.to_pdf(input, version.format, workdir),
           {:ok, info} <- Pdf.info(pdf),
           {:ok, pdf_key} <- store_pdf(version, pdf),
           :ok <- render_pages(version, pdf, workdir),
           {:ok, texts} <- Pdf.text(pdf, info.page_count) do
        pages =
          info.sizes
          |> Enum.zip(texts)
          |> Enum.map(fn {{w, h}, text} -> %{width: w, height: h, text: text} end)

        Documents.complete_version(
          version,
          %{pdf_key: pdf_key, page_count: info.page_count, metadata: info.metadata},
          pages
        )
      end
    after
      File.rm_rf(workdir)
    end
  end

  # PDFs are stored once: for uploaded PDFs the original is the PDF.
  defp store_pdf(%Version{format: :pdf} = version, _pdf), do: {:ok, version.original_key}

  defp store_pdf(version, pdf) do
    key = "#{Version.prefix(version)}/document.pdf"

    case Storage.put_file(key, pdf) do
      :ok -> {:ok, key}
      error -> error
    end
  end

  defp render_pages(version, pdf, workdir) do
    Enum.reduce_while(Pdf.widths(), :ok, fn width, :ok ->
      out = Path.join(workdir, "w#{width}")
      File.mkdir_p!(out)

      with {:ok, images} <- Pdf.render(pdf, width, out),
           :ok <- store_images(version, images, width) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp store_images(version, images, width) do
    Enum.reduce_while(images, :ok, fn {n, path}, :ok ->
      case Storage.put_file(Version.page_key(version, n, width), path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Errors that retrying won't fix.
  defp permanent?({:missing_tool, _}), do: false
  defp permanent?({:unsupported_format, _}), do: true
  defp permanent?({:conversion_failed, _}), do: true
  defp permanent?(:no_pages), do: true
  defp permanent?({:exit, _code, output}), do: output =~ ~r/password|Incorrect|Syntax Error/i
  defp permanent?(_), do: false

  @doc false
  # A stable error code stored on the version; the UI translates it
  # (ReadoutWeb.DocumentLabels.error_message/1).
  def describe(:timeout), do: "timeout"
  def describe(:no_pages), do: "no_pages"
  def describe({:missing_tool, tool}), do: "missing_tool:#{tool}"
  def describe({:unsupported_format, _}), do: "unsupported"
  def describe({:conversion_failed, _}), do: "conversion_failed"

  def describe({:exit, _code, output}) do
    if output =~ ~r/password|Incorrect/i, do: "password", else: "unreadable"
  end

  def describe(_other), do: "unexpected"
end
