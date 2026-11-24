defmodule ReadoutWeb.DocumentFileController do
  @moduledoc """
  Files of a document for signed-in team members: page images and downloads.

  Every request checks `:view_document`. Page images are immutable per
  version, so they are cached privately by the browser; nothing here is
  cacheable by shared proxies.
  """
  use ReadoutWeb, :controller

  alias Readout.{Audit, Documents, Storage}
  alias Readout.Documents.{FileType, Pdf, Version}

  def page(conn, %{"id" => id, "version_id" => version_id, "number" => number, "width" => width}) do
    with {:ok, _doc, version} <- fetch(conn, id, version_id),
         {n, ""} <- Integer.parse(number),
         {w, ""} <- Integer.parse(width),
         true <- w in Pdf.widths() and n >= 1 and n <= (version.page_count || 0),
         {:path, path} <- Storage.serve(Version.page_key(version, n, w)) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  def download(conn, %{"id" => id, "version_id" => version_id, "kind" => kind}) do
    with {:ok, doc, version} <- fetch(conn, id, version_id),
         {:ok, key, filename, type} <- file_for(doc, version, kind),
         {:path, path} <- Storage.serve(key) do
      Audit.log(conn.assigns.current_scope, "document.downloaded", doc, %{
        kind: kind,
        version: version.number,
        via: "app"
      })

      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", content_disposition(filename))
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  defp fetch(conn, id, version_id) do
    with %{} = doc <- Documents.get_document(conn.assigns.current_scope, id),
         %Version{} = version <- Documents.get_version(doc, version_id) do
      {:ok, doc, version}
    else
      _ -> :error
    end
  end

  defp file_for(doc, %Version{pdf_key: key, status: :ready}, "pdf") when is_binary(key),
    do: {:ok, key, doc.title <> ".pdf", "application/pdf"}

  defp file_for(doc, %Version{} = version, "original") do
    ext = FileType.extension(version.format)
    {:ok, version.original_key, doc.title <> ext, MIME.from_path("x" <> ext)}
  end

  defp file_for(_doc, _version, _kind), do: :error

  @doc false
  # RFC 6266: an ASCII fallback plus the UTF-8 name.
  def content_disposition(filename) do
    ascii = filename |> String.normalize(:nfd) |> String.replace(~r/[^\x20-\x7E]|["\\]/u, "")

    "attachment; filename=\"#{ascii}\"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}"
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
  end
end
