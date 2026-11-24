defmodule Readout.GlobalConfigTest do
  # These tests change application config, so they must never run alongside
  # async tests (ExUnit runs sync modules on their own).
  use Readout.DataCase, async: false

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Links}

  defp put_env(key, value) do
    previous = Application.get_env(:readout, key)
    Application.put_env(:readout, key, value)
    on_exit(fn -> Application.put_env(:readout, key, previous) end)
  end

  test "uploads above the size limit are refused" do
    put_env(
      Readout.Documents,
      Keyword.put(Application.get_env(:readout, Readout.Documents), :max_upload_bytes, 100)
    )

    scope = Scope.for_user(user_fixture())
    assert {:error, :too_large} = Documents.create_document(scope, upload("sample.pdf"))
  end

  test "links can't require verification without SMTP" do
    put_env(:mail_enabled, false)
    scope = Scope.for_user(user_fixture())
    {doc, _link} = shared_fixture(scope)

    assert {:error, cs} =
             Links.create_link(scope, doc, %{"name" => "x", "require_verification" => "true"})

    assert %{require_verification: [_]} = errors_on(cs)
  end

  test "invitations are emailed only when SMTP is configured" do
    import Swoosh.TestAssertions
    owner = Scope.for_user(owner_fixture())
    url = &"https://share.example/invitations/#{&1}"

    put_env(:mail_enabled, false)

    {:ok, _} =
      Readout.Accounts.create_invitation(owner, %{"email" => "a@x.com", "role" => "member"}, url)

    assert [] = Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Mailer.DeliverJob)

    put_env(:mail_enabled, true)

    {:ok, _} =
      Readout.Accounts.create_invitation(owner, %{"email" => "b@x.com", "role" => "member"}, url)

    [job] = Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Mailer.DeliverJob)
    :ok = Oban.Testing.perform_job(Readout.Mailer.DeliverJob, job.args, repo: Readout.Repo)
    assert_email_sent(to: "b@x.com")
  end

  describe "Rocket.Chat notifications" do
    setup do
      put_env(:rocketchat_webhook_url, "https://chat.example/hooks/abc")
      owner = owner_fixture(chat_username: "alex")
      scope = Scope.for_user(owner)
      {doc, link} = shared_fixture(scope)
      %{scope: scope, doc: doc, link: link}
    end

    test "opening a link posts to the webhook", %{link: link} do
      parent = self()

      Req.Test.stub(Readout.Notifications, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posted, Jason.decode!(body)})
        Req.Test.json(conn, %{success: true})
      end)

      {:ok, link} = Links.fetch_public_link(link.slug)
      _visit = Links.start_visit(link, %{email: "ana@client.com"})

      [job] = Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Notifications.RocketChatJob)

      assert :ok =
               Oban.Testing.perform_job(Readout.Notifications.RocketChatJob, job.args,
                 repo: Readout.Repo
               )

      assert_received {:posted, %{"text" => text, "alias" => "Readout"}}
      assert text =~ "ana@client.com opened"
      assert text =~ "@alex"
    end

    test "Rocket.Chat errors are retried", %{link: link} do
      Req.Test.stub(Readout.Notifications, &Plug.Conn.send_resp(&1, 500, "down"))
      {:ok, link} = Links.fetch_public_link(link.slug)
      _ = Links.start_visit(link, %{})
      [job] = Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Notifications.RocketChatJob)

      assert {:error, {:http_status, 500}} =
               Oban.Testing.perform_job(Readout.Notifications.RocketChatJob, job.args,
                 repo: Readout.Repo
               )
    end

    test "documents nobody follows stay quiet", %{scope: scope, doc: doc, link: link} do
      {:ok, _} = Readout.Notifications.set_subscription(scope, doc, false)
      {:ok, link} = Links.fetch_public_link(link.slug)
      _ = Links.start_visit(link, %{})
      [job] = Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Notifications.RocketChatJob)
      # No stub: posting would fail the test.
      assert :ok =
               Oban.Testing.perform_job(Readout.Notifications.RocketChatJob, job.args,
                 repo: Readout.Repo
               )
    end
  end

  test "without a webhook, nothing is queued" do
    put_env(:rocketchat_webhook_url, nil)
    scope = Scope.for_user(user_fixture())
    {_doc, link} = shared_fixture(scope)
    {:ok, link} = Links.fetch_public_link(link.slug)
    _ = Links.start_visit(link, %{})

    assert [] =
             Oban.Testing.all_enqueued(Readout.Repo, worker: Readout.Notifications.RocketChatJob)
  end
end
