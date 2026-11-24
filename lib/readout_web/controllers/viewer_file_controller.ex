defmodule ReadoutWeb.ViewerFileController do
  @moduledoc """
  Page images and downloads for the public viewer. Every request needs a
  visit-bound token (two hours) and re-checks the link: disabling or expiring
  a link cuts off images immediately.
  """
  use ReadoutWeb, :controller

  alias Readout.{Audit, Links, Repo, Storage}
  alias Readout.Documents.{FileType, Pdf, Version}
  alias ReadoutWeb.ViewerAccess

  def page(conn, %{"slug" => slug, "token" => token, "number" => number, "width" => width}) do
    with {:ok, _link, _visit, version} <- authorize(slug, token),
         {n, ""} <- Integer.parse(number),
         {w, ""} <- Integer.parse(width),
         true <- w in Pdf.widths() and n >= 1 and n <= version.page_count,
         {:path, path} <- Storage.serve(Version.page_key(version, n, w)) do
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
         {:ok, key, ext, type} <- file_for(link, version, kind),
         {:path, path} <- Storage.serve(key) do
      document = Repo.get!(Readout.Documents.Document, visit.document_id)

      Audit.log(nil, "document.downloaded", document, %{
        kind: kind,
        via: "link",
        link: link.name,
        email: visit.email,
        visit_id: visit.id
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

  defp file_for(_link, %Version{pdf_key: key}, "pdf") when is_binary(key),
    do: {:ok, key, ".pdf", "application/pdf"}

  defp file_for(%{allow_original_download: true}, %Version{format: format} = v, "original")
       when format != :pdf do
    ext = FileType.extension(format)
    {:ok, v.original_key, ext, MIME.from_path("x" <> ext)}
  end

  defp file_for(_, _, _), do: :error

  defp not_found(conn) do
    conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")
  end
end
