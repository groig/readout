defmodule Readout.GlobalConfigTest do
  # These tests change application config, so they must never run alongside
  # async tests (ExUnit runs sync modules on their own).
  use Readout.DataCase, async: false

  @endpoint ReadoutWeb.Endpoint

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

  describe "first-run setup in production" do
    import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
    import Phoenix.LiveViewTest

    @owner %{
      "name" => "Alex",
      "email" => "owner@example.com",
      "password" => "a long password 1",
      "remember_me" => "true"
    }

    test "is locked without a setup token or admin networks" do
      put_env(:setup, require_authorization: true, token: nil)
      put_env(:admin_networks, nil)

      {:ok, lv, _} = live(build_conn(), "/setup")
      assert has_element?(lv, "#setup-locked")
      refute has_element?(lv, "#setup-form")
      assert render_hook(lv, "save", %{"user" => @owner}) =~ "Setup is locked"
      refute Readout.Accounts.any_users?()
    end

    test "asks for the setup token" do
      put_env(:setup, require_authorization: true, token: "0123456789abcdef0123")

      {:ok, lv, _} = live(build_conn(), "/setup")
      assert has_element?(lv, "#setup-code")

      lv |> form("#setup-form", user: @owner, setup_code: "wrong") |> render_submit()
      refute Readout.Accounts.any_users?()

      lv
      |> form("#setup-form", user: @owner, setup_code: "0123456789abcdef0123")
      |> render_submit()

      assert Readout.Accounts.get_user_by_email("owner@example.com").role == :owner
    end

    test "with admin networks, the network check protects it" do
      put_env(:setup, require_authorization: true, token: nil)
      put_env(:admin_networks, ["100.64.0.0/10"])

      conn = %{build_conn() | remote_ip: {203, 0, 113, 9}}
      assert get(conn, "/setup").status == 404
    end
  end

  describe "request logs" do
    import ExUnit.CaptureLog
    import Phoenix.ConnTest, only: [build_conn: 0, get: 2, post: 3]

    test "never contain the credentials that travel in paths" do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      requests = [
        {:get, "/users/log-in/SYNTHmagic000000000001"},
        {:get, "/users/reset-password/SYNTHreset00000000002"},
        {:get, "/invitations/SYNTHinvite0000000003"},
        {:get, "/settings/account/confirm-email/SYNTHconfirm00000004"},
        {:get, "/v/SYNTHslug0000000005"},
        {:get, "/v/SYNTHslug0000000005/d/SYNTHdoc000000006"},
        {:get, "/v/SYNTHslug0000000005/p/SYNTHtoken00000007/1/1600"},
        {:get, "/v/SYNTHslug0000000005/download/SYNTHtoken00000008/pdf"},
        {:post, "/v/SYNTHslug0000000005/access"},
        {:get, "/SYNTHunknown00000009"}
      ]

      log =
        capture_log([level: :info], fn ->
          for {method, path} <- requests do
            case method do
              :get -> get(build_conn(), path)
              :post -> post(build_conn(), path, %{"grant" => "SYNTHgrant0000000010"})
            end
          end
        end)

      assert log =~ "GET /v/:slug/p/:token/:number/:width 404"
      assert log =~ "GET /users/log-in/:token 302"
      assert log =~ "GET (unmatched) 404"
      refute log =~ "SYNTH"
    end
  end

  test "document tools refuse to run without isolation when it's required" do
    alias Readout.Documents.Tools
    previous = :persistent_term.get({Tools, :isolation}, :unknown)
    :persistent_term.put({Tools, :isolation}, false)
    on_exit(fn -> :persistent_term.put({Tools, :isolation}, previous) end)

    put_env(
      Readout.Documents,
      Keyword.put(Application.get_env(:readout, Readout.Documents), :isolation, :required)
    )

    assert Tools.run("true", []) == {:error, :isolation_unavailable}

    put_env(
      Readout.Documents,
      Keyword.put(Application.get_env(:readout, Readout.Documents), :isolation, :preferred)
    )

    assert {:ok, _} = Tools.run("true", [])
  end

  test "password sign-in is throttled per client address" do
    import Phoenix.ConnTest, only: [build_conn: 0, post: 3]
    put_env(:login_limits, client: 3, account: 100)

    conn = %{
      build_conn()
      | remote_ip: {198, 51, 100, System.unique_integer([:positive]) |> rem(250)}
    }

    flashes =
      for n <- 1..4 do
        params = %{"user" => %{"email" => "someone#{n}@example.com", "password" => "bad"}}
        conn |> post("/users/log-in", params) |> Map.fetch!(:assigns) |> Map.fetch!(:flash)
      end

    assert Enum.map(flashes, & &1["error"]) |> List.last() =~ "Too many attempts"

    assert Enum.map(flashes, & &1["error"]) |> Enum.take(3) |> Enum.uniq() == [
             "Invalid email or password"
           ]
  end

  test "CSV reading stops at the configured size, marking the sheet truncated" do
    put_env(
      Readout.Documents,
      Keyword.put(Application.get_env(:readout, Readout.Documents), :sheet_max_mb, 1)
    )

    path = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)
    # Fewer rows than the row limit, but more bytes than allowed.
    value = String.duplicate("9", 90)
    File.write!(path, ["name,value\n" | List.duplicate("someone,#{value}\n", 15_000)])
    assert File.stat!(path).size > 1024 * 1024

    {:ok, [sheet]} = Readout.Documents.Sheets.extract(path, :csv, System.tmp_dir!())
    assert sheet.truncated
    assert length(sheet.rows) < 14_999
    assert List.last(sheet.rows) == ["someone", value]
  end
end
