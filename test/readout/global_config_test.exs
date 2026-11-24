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

  test "admin routes check the HTTP peer and the live connection" do
    alias ReadoutWeb.AdminNetwork
    put_env(:admin_networks, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
    outside = {203, 0, 113, 9}
    inside = {100, 64, 0, 2}

    for path <- ~w(/setup /settings/workspace /settings/audit /settings/members /dev/dashboard) do
      conn = Plug.Test.conn(:get, path)
      assert AdminNetwork.call(%{conn | remote_ip: outside}, []).status == 404
      refute AdminNetwork.call(%{conn | remote_ip: inside}, []).halted
    end

    for path <- ~w(/users/log-in /settings/profile /v/public /invitations/token) do
      refute AdminNetwork.call(%{Plug.Test.conn(:get, path) | remote_ip: outside}, []).halted
    end

    for {peer, expected} <- [{outside, :halt}, {inside, :cont}] do
      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        private: %{connect_info: %{peer_data: %{address: peer}}}
      }

      assert {^expected, _} = AdminNetwork.on_mount(:default, %{}, %{}, socket)
    end
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
end
