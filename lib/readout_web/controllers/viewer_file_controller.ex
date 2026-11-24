defmodule ReadoutWeb.ViewerFileController do
  @moduledoc """
  Page images and downloads for the public viewer. Every request needs a
  visit-bound token (two hours) and re-checks the link: disabling or expiring
  a link cuts off images immediately.

  For links with a watermark, images and the PDF download are watermarked
  per visit (`Readout.Documents.Watermark`), and originals (Word, Excel...)
  are never offered, since they can't carry it.
  """
  use ReadoutWeb, :controller

  alias Readout.{Audit, Links, Repo, Storage}
  alias Readout.Documents.{FileType, Pdf, Version, Watermark}
  alias ReadoutWeb.ViewerAccess

  def page(conn, %{"slug" => slug, "token" => token, "number" => number, "width" => width}) do
    with {:ok, link, visit, version} <- authorize(slug, token),
         {n, ""} <- Integer.parse(number),
         {w, ""} <- Integer.parse(width),
         true <- w in Pdf.widths() and n >= 1 and n <= version.page_count,
         {:ok, path} <- page_path(link, visit, version, n, w) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  def download(conn, %{"slug" => slug, "token" => token, "kind" => kind}) do
    with {:ok, link, visit, version} <- authorize(slug, token),
         true <- link.allow_download,
         {:ok, path, ext, type} <- file_for(link, visit, version, kind) do
      document = Repo.get!(Readout.Documents.Document, visit.document_id)

      Audit.log(nil, "document.downloaded", document, %{
        kind: kind,
        via: "link",
        link: link.name,
        email: visit.email,
        visit_id: visit.id,
        watermark: link.watermark
      })

      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header(
        "content-disposition",
        ReadoutWeb.DocumentFileController.content_disposition(document.title <> ext)
      )
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  defp authorize(slug, token) do
    with {:ok, visit_id} <- ViewerAccess.verify_visit(token),
         {:ok, link} <- Links.fetch_public_link(slug),
         %{} = visit <- Links.get_visit(visit_id),
         true <- visit.link_id == link.id,
         %Version{status: :ready} = version <- Repo.get(Version, visit.version_id) do
      {:ok, link, visit, version}
    else
      _ -> :error
    end
  end

  defp page_path(%{watermark: true}, visit, version, n, w),
    do: Watermark.page_image(visit, version, n, w)

  defp page_path(_link, _visit, version, n, w) do
    case Storage.serve(Version.page_key(version, n, w)) do
      {:path, path} -> {:ok, path}
      _ -> :error
    end
  end

  defp file_for(%{watermark: true}, visit, %Version{pdf_key: key} = version, "pdf")
       when is_binary(key) do
    with {:ok, path} <- Watermark.pdf(visit, version), do: {:ok, path, ".pdf", "application/pdf"}
  end

  defp file_for(_link, _visit, %Version{pdf_key: key}, "pdf") when is_binary(key) do
    case Storage.serve(key) do
      {:path, path} -> {:ok, path, ".pdf", "application/pdf"}
      _ -> :error
    end
  end

  # Originals: Office files when the link allows it; spreadsheets whenever
  # downloads are allowed (they have no PDF). Never for watermarked links.
  defp file_for(%{watermark: false} = link, _visit, %Version{format: format} = v, "original")
       when format != :pdf and (link.allow_original_download or format in [:xlsx, :ods, :csv]) do
    ext = FileType.extension(format)

    case Storage.serve(v.original_key) do
      {:path, path} -> {:ok, path, ext, MIME.from_path("x" <> ext)}
      _ -> :error
    end
  end

  defp file_for(_, _, _, _), do: :error

  defp not_found(conn) do
    conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")
  end
end
