defmodule ReadoutWeb.DocumentFileControllerTest do
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Storage}
  alias Readout.Documents.Version

  setup :register_and_log_in_user

  setup %{scope: scope} do
    doc = document_fixture(scope)
    version = fake_ready!(doc, 2)
    :ok = Storage.put_file(Version.page_key(version, 1, 480), file_path("sample.pdf"))
    %{doc: doc, version: version}
  end

  test "serves page images privately and immutably", %{conn: conn, doc: doc, version: version} do
    conn = get(conn, ~p"/documents/#{doc.id}/v/#{version.id}/pages/1/480")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
  end

  test "404s on unknown pages, widths and versions", %{conn: conn, doc: doc, version: version} do
    assert response(get(conn, ~p"/documents/#{doc.id}/v/#{version.id}/pages/9/480"), 404)
    assert response(get(conn, ~p"/documents/#{doc.id}/v/#{version.id}/pages/1/777"), 404)

    assert response(
             get(conn, ~p"/documents/#{doc.id}/v/#{Ecto.UUID.generate()}/pages/1/480"),
             404
           )
  end

  test "downloads the PDF and audits it", %{conn: conn, doc: doc, version: version} do
    conn = get(conn, ~p"/documents/#{doc.id}/v/#{version.id}/download/pdf")
    assert response(conn, 200) =~ "%PDF"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert Readout.Repo.get_by(Readout.Audit.Event, action: "document.downloaded")
  end

  test "hides restricted documents from others", %{doc: doc, version: version, scope: scope} do
    {:ok, _} =
      Documents.update_visibility(scope, Documents.get_document(scope, doc.id), :restricted)

    other = log_in_user(build_conn(), user_fixture())

    assert response(get(other, ~p"/documents/#{doc.id}/v/#{version.id}/pages/1/480"), 404)
    assert response(get(other, ~p"/documents/#{doc.id}/v/#{version.id}/download/pdf"), 404)
  end

  test "requires signing in", %{doc: doc, version: version} do
    conn = get(build_conn(), ~p"/documents/#{doc.id}/v/#{version.id}/pages/1/480")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "content_disposition keeps non-ASCII names" do
    header = ReadoutWeb.DocumentFileController.content_disposition("Informe Q3 – España.pdf")
    assert header =~ ~s(filename="Informe Q3  Espana.pdf")
    assert header =~ "filename*=UTF-8''Informe%20Q3%20%E2%80%93%20Espa%C3%B1a.pdf"
    _ = Scope
  end
end
