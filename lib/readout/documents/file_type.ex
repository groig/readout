defmodule Readout.Documents.FileType do
  @moduledoc """
  Detects an upload's format from its contents (magic bytes), never from its
  name or the browser's content type.

    * PDF: `%PDF-` within the first 1024 bytes (as the spec allows).
    * DOCX / PPTX: a ZIP containing `word/document.xml` / `ppt/presentation.xml`.
    * ODT / ODP / ODS: a ZIP whose `mimetype` entry names the OpenDocument type.
    * XLSX: a ZIP containing `xl/workbook.xml`.
    * CSV has no signature: a `.csv`/`.tsv` file is accepted when its start is
      text (valid UTF-8 or Latin-1, no NUL bytes).

  Only the ZIP's central directory and the tiny `mimetype` entry are read, so
  archive bombs are not expanded.
  """

  @pdf_magic "%PDF-"
  @zip_magic <<"PK", 3, 4>>

  @type format :: :pdf | :docx | :pptx | :odt | :odp | :xlsx | :ods | :csv

  @spec detect(Path.t(), String.t() | nil) :: {:ok, format()} | {:error, :unsupported}
  def detect(path, filename \\ nil) do
    case read_head(path, 1024) do
      {:ok, <<@zip_magic, _::binary>>} ->
        detect_zip(path)

      {:ok, head} ->
        detect_plain(head, filename)

      _ ->
        unsupported()
    end
  end

  defp detect_plain(head, filename) do
    cond do
      :binary.match(head, @pdf_magic) != :nomatch -> {:ok, :pdf}
      csv_name?(filename) and text?(head) -> {:ok, :csv}
      true -> unsupported()
    end
  end

  defp csv_name?(nil), do: false

  defp csv_name?(name),
    do: name |> Path.extname() |> String.downcase() |> Kernel.in([".csv", ".tsv"])

  # Text files have no NUL bytes (UTF-8 and Latin-1 are both fine).
  defp text?(head), do: not String.contains?(head, <<0>>)

  defp read_head(path, bytes) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, bytes) do
          data when is_binary(data) -> {:ok, data}
          _ -> {:error, :empty}
        end
      after
        File.close(io)
      end
    end
  end

  defp detect_zip(path) do
    charpath = String.to_charlist(path)

    with {:ok, entries} <- :zip.list_dir(charpath) do
      names =
        for {:zip_file, name, _info, _comment, _offset, _size} <- entries,
            into: MapSet.new(),
            do: to_string(name)

      cond do
        MapSet.member?(names, "word/document.xml") -> {:ok, :docx}
        MapSet.member?(names, "ppt/presentation.xml") -> {:ok, :pptx}
        MapSet.member?(names, "xl/workbook.xml") -> {:ok, :xlsx}
        MapSet.member?(names, "mimetype") -> detect_odf(charpath)
        true -> unsupported()
      end
    else
      _ -> unsupported()
    end
  end

  defp detect_odf(charpath) do
    case :zip.extract(charpath, [{:file_list, [~c"mimetype"]}, :memory]) do
      {:ok, [{_, "application/vnd.oasis.opendocument.text" <> _}]} -> {:ok, :odt}
      {:ok, [{_, "application/vnd.oasis.opendocument.presentation" <> _}]} -> {:ok, :odp}
      {:ok, [{_, "application/vnd.oasis.opendocument.spreadsheet" <> _}]} -> {:ok, :ods}
      _ -> unsupported()
    end
  end

  defp unsupported, do: {:error, :unsupported}

  @doc "The file extension for a format."
  def extension(format), do: "." <> Atom.to_string(format)

  @doc "Accepted extensions, for the upload picker (a hint only; contents decide)."
  def accept, do: ~w(.pdf .docx .pptx .odt .odp .xlsx .ods .csv)
end
