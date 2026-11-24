defmodule ReadoutWeb.ViewerFileControllerTest do
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Links, Storage}
  alias Readout.Documents.Version
  alias ReadoutWeb.ViewerAccess

  setup do
    scope = Scope.for_user(user_fixture())
    {doc, link} = shared_fixture(scope, %{"allow_download" => "true"})
    version = doc.current_version
    :ok = Storage.put_file(Version.page_key(version, 1, 1600), file_path("sample.pdf"))
    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit(link, %{email: "ana@client.com"})
    %{scope: scope, doc: doc, link: link, token: ViewerAccess.sign_visit(visit.id)}
  end

  test "serves pages with a visit token", %{conn: conn, link: link, token: token} do
    assert response(get(conn, ~p"/v/#{link.slug}/p/#{token}/1/1600"), 200)
    assert response(get(conn, ~p"/v/#{link.slug}/p/bad-token/1/1600"), 404)
    assert response(get(conn, ~p"/v/#{link.slug}/p/#{token}/99/1600"), 404)
  end

  test "a token is bound to its link", %{conn: conn, scope: scope, token: token} do
    {_doc, other} = shared_fixture(scope)
    assert response(get(conn, ~p"/v/#{other.slug}/p/#{token}/1/1600"), 404)
  end

  test "disabling the link cuts off images at once", %{
    conn: conn,
    scope: scope,
    doc: doc,
    link: link,
    token: token
  } do
    {:ok, _} = Links.set_enabled(scope, doc, link, false)
    assert response(get(conn, ~p"/v/#{link.slug}/p/#{token}/1/1600"), 404)
  end

  test "downloads only when allowed, and audits them", %{
    conn: conn,
    scope: scope,
    doc: doc,
    link: link,
    token: token
  } do
    conn1 = get(conn, ~p"/v/#{link.slug}/download/#{token}/pdf")
    assert response(conn1, 200) =~ "%PDF"
    event = Readout.Repo.get_by!(Readout.Audit.Event, action: "document.downloaded")
    assert event.metadata["email"] == "ana@client.com"
    assert event.metadata["via"] == "link"

    assert response(get(conn, ~p"/v/#{link.slug}/download/#{token}/original"), 404)

    {:ok, _} = Links.update_link(scope, doc, link, %{"allow_download" => "false"})
    assert response(get(conn, ~p"/v/#{link.slug}/download/#{token}/pdf"), 404)
  end
end
