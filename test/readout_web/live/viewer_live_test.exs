defmodule ReadoutWeb.ViewerLiveTest do
  use ReadoutWeb.ConnCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Links
  alias Readout.Links.Visit

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  test "an open link shows the document and starts a visit", %{conn: conn, scope: scope} do
    {_doc, link} = shared_fixture(scope)

    {:ok, lv, _html} = live(conn, ~p"/v/#{link.slug}")
    assert has_element?(lv, "#viewer")
    assert has_element?(lv, "#page-3")
    assert has_element?(lv, "#page-1 img[src*='/v/#{link.slug}/p/']")
    refute has_element?(lv, "#download-pdf")

    assert [%Visit{email: nil, link_id: link_id}] = Readout.Repo.all(Visit)
    assert link_id == link.id
  end

  test "is in the browser's language and never indexed", %{conn: conn, scope: scope} do
    {_doc, link} = shared_fixture(scope, %{"password" => "pw12"})
    conn = conn |> put_req_header("accept-language", "es") |> get(~p"/v/#{link.slug}")
    html = html_response(conn, 200)
    assert html =~ ~s(lang="es")
    assert html =~ "Contraseña"
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "unknown, disabled and expired links explain themselves", %{conn: conn, scope: scope} do
    {doc, link} = shared_fixture(scope)
    {:ok, lv, _} = live(conn, ~p"/v/nope")
    assert has_element?(lv, "#link-unavailable")

    {:ok, _} = Links.set_enabled(scope, doc, link, false)
    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    assert has_element?(lv, "#link-unavailable")
    assert Readout.Repo.all(Visit) == []
  end

  test "password gate, then a session grant", %{conn: conn, scope: scope} do
    {_doc, link} = shared_fixture(scope, %{"password" => "letmein"})

    {:ok, lv, _html} = live(conn, ~p"/v/#{link.slug}")
    refute has_element?(lv, "#viewer")

    lv |> form("#gate-form", gate: %{password: "wrong"}) |> render_submit()
    assert has_element?(lv, "#gate-error")

    lv |> form("#gate-form", gate: %{password: "letmein"}) |> render_submit()
    assert has_element?(lv, "#access-form")
    conn = follow_trigger_action(form(lv, "#access-form"), conn)
    assert redirected_to(conn) == ~p"/v/#{link.slug}"

    # The session now holds the grant: straight to the document.
    {:ok, lv, _html} = live(recycle(conn), ~p"/v/#{link.slug}")
    assert has_element?(lv, "#viewer")
  end

  test "a grant from before the link changed doesn't count", %{conn: conn, scope: scope} do
    {doc, link} = shared_fixture(scope, %{"password" => "letmein"})
    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    lv |> form("#gate-form", gate: %{password: "letmein"}) |> render_submit()
    conn = follow_trigger_action(form(lv, "#access-form"), conn)

    Readout.Repo.update_all(Readout.Links.Link,
      set: [updated_at: DateTime.add(DateTime.utc_now(:second), 60)]
    )

    _ = doc
    {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
    assert has_element?(lv, "#gate-form")
  end

  test "email gate respects the lists and records the email", %{conn: conn, scope: scope} do
    {_doc, link} =
      shared_fixture(scope, %{"require_email" => "true", "deny_list_text" => "rival.com"})

    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    lv |> form("#gate-form", gate: %{email: "spy@rival.com"}) |> render_submit()
    assert render(lv) =~ "can&#39;t open this document"

    lv |> form("#gate-form", gate: %{email: "ana@client.com"}) |> render_submit()
    conn = follow_trigger_action(form(lv, "#access-form"), conn)
    {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
    assert has_element?(lv, "#viewer")
    assert Readout.Repo.get_by!(Visit, email: "ana@client.com").email_verified == false
  end

  test "verification: emailed code, verified visit, remembered on the device", %{
    conn: conn,
    scope: scope
  } do
    {_doc, link} = shared_fixture(scope, %{"require_verification" => "true"})

    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    lv |> form("#gate-form", gate: %{email: "ana@client.com"}) |> render_submit()
    assert has_element?(lv, "#code-form")

    [job] = all_enqueued(worker: Readout.Mailer.DeliverJob)
    :ok = perform_job(Readout.Mailer.DeliverJob, job.args)

    code =
      receive do
        {:email, %Swoosh.Email{text_body: body}} ->
          body |> then(&Regex.run(~r/\d{6}/, &1)) |> hd()
      after
        1000 -> flunk("no email")
      end

    lv |> form("#code-form", %{code: "000000"}) |> render_submit()
    assert has_element?(lv, "#gate-error")

    lv |> form("#code-form", %{code: code}) |> render_submit()
    conn = follow_trigger_action(form(lv, "#access-form"), conn)
    assert conn.resp_cookies["rv_" <> link.slug]

    {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")
    assert has_element?(lv, "#viewer")
    assert Readout.Repo.get_by!(Visit, email: "ana@client.com").email_verified

    # A new session on the same device skips the code thanks to the cookie.
    device =
      build_conn()
      |> put_req_cookie("rv_" <> link.slug, conn.resp_cookies["rv_" <> link.slug].value)

    {:ok, lv, _} = live(device, ~p"/v/#{link.slug}")
    assert has_element?(lv, "#gate-form input[readonly][value='ana@client.com']")
    lv |> form("#gate-form") |> render_submit()
    refute has_element?(lv, "#code-form")
    assert has_element?(lv, "#access-form")
  end

  test "watermark and download follow the link settings", %{conn: conn, scope: scope} do
    {_doc, link} =
      shared_fixture(scope, %{
        "require_email" => "true",
        "watermark" => "true",
        "allow_download" => "true"
      })

    {:ok, lv, _} = live(conn, ~p"/v/#{link.slug}")
    lv |> form("#gate-form", gate: %{email: "ana@client.com"}) |> render_submit()
    conn = follow_trigger_action(form(lv, "#access-form"), conn)
    {:ok, lv, _} = live(recycle(conn), ~p"/v/#{link.slug}")

    assert render(element(lv, "#page-1")) =~ "ana@client.com"
    assert has_element?(lv, "#download-pdf")
  end
end
