defmodule Readout.LinksTest do
  use Readout.DataCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Links}
  alias Readout.Links.Link

  setup do
    scope = Scope.for_user(user_fixture())
    {doc, link} = shared_fixture(scope)
    %{scope: scope, doc: doc, link: link}
  end

  describe "managing links" do
    test "creates links with an unguessable slug and audits it", %{link: link} do
      assert byte_size(link.slug) == 22
      assert link.enabled
      assert Readout.Repo.get_by(Readout.Audit.Event, action: "link.created")
    end

    test "hashes passwords, parses lists and keeps rules consistent", %{scope: scope, doc: doc} do
      {:ok, link} =
        Links.create_link(scope, doc, %{
          "name" => "Investors",
          "password" => "s3cret",
          "require_verification" => "true",
          "allow_list_text" => "Client.com\n@partner.com, ana@other.com",
          "deny_list_text" => "",
          "allow_download" => "false",
          "allow_original_download" => "true"
        })

      assert Link.password?(link)
      refute link.password_hash == "s3cret"
      assert Link.valid_password?(link, "s3cret")
      assert link.require_email, "verification implies an email gate"
      refute link.allow_original_download, "original downloads need downloads"
      assert link.allow_list == ["client.com", "partner.com", "ana@other.com"]
    end

    test "rejects bad list entries and past expiries", %{scope: scope, doc: doc} do
      assert {:error, cs} =
               Links.create_link(scope, doc, %{
                 "name" => "x",
                 "allow_list_text" => "not an email!",
                 "expires_at" => DateTime.add(DateTime.utc_now(), -60)
               })

      assert %{allow_list_text: [_], expires_at: [_]} = errors_on(cs)
    end

    test "only people who can edit the document manage its links", %{doc: doc, link: link} do
      other = Scope.for_user(user_fixture())
      doc = Documents.get_document(other, doc.id)
      assert {:error, :unauthorized} = Links.create_link(other, doc, %{"name" => "x"})
      assert {:error, :unauthorized} = Links.set_enabled(other, doc, link, false)
      assert [_] = Links.list_links(other, doc)
    end

    test "disabling and enabling are audited", %{scope: scope, doc: doc, link: link} do
      assert {:ok, %{enabled: false}} = Links.set_enabled(scope, doc, link, false)
      assert Readout.Repo.get_by(Readout.Audit.Event, action: "link.disabled")
    end
  end

  describe "public resolution" do
    test "explains why a link can't be viewed", %{scope: scope, doc: doc, link: link} do
      assert {:ok, %Link{}} = Links.fetch_public_link(link.slug)
      assert {:error, :not_found} = Links.fetch_public_link("nope")

      {:ok, link} = Links.set_enabled(scope, doc, link, false)
      assert {:error, :disabled} = Links.fetch_public_link(link.slug)

      {:ok, link} = Links.update_link(scope, doc, link, %{"enabled" => "true"})

      Readout.Repo.update_all(Link,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      assert {:error, :expired} = Links.fetch_public_link(link.slug)

      Readout.Repo.update_all(Link, set: [expires_at: nil])
      {:ok, _} = Documents.delete_document(scope, doc)
      assert {:error, :not_found} = Links.fetch_public_link(link.slug)
    end

    test "a document without a ready version isn't viewable yet", %{scope: scope} do
      doc = Documents.get_document(scope, document_fixture(scope).id)
      {:ok, link} = Links.create_link(scope, doc, %{"name" => "Early"})
      assert {:error, :not_ready} = Links.fetch_public_link(link.slug)
    end
  end

  describe "the gate" do
    test "checks the password and email lists", %{scope: scope, doc: doc} do
      {:ok, link} =
        Links.create_link(scope, doc, %{
          "name" => "Gated",
          "password" => "letmein",
          "require_email" => "true",
          "allow_list_text" => "client.com",
          "deny_list_text" => "boss@client.com"
        })

      assert {:error, :wrong_password} =
               Links.check_gate(link, %{"password" => "no", "email" => "a@client.com"}, "ip1")

      assert {:error, :invalid_email} =
               Links.check_gate(link, %{"password" => "letmein", "email" => "nope"}, "ip1")

      assert {:error, :email_not_allowed} =
               Links.check_gate(link, %{"password" => "letmein", "email" => "a@other.com"}, "ip1")

      assert {:error, :email_not_allowed} =
               Links.check_gate(
                 link,
                 %{"password" => "letmein", "email" => "Boss@Client.com"},
                 "ip1"
               )

      assert {:ok, "ana@client.com"} =
               Links.check_gate(
                 link,
                 %{"password" => "letmein", "email" => " Ana@Client.com "},
                 "ip1"
               )
    end

    test "is rate limited per client", %{link: link} do
      key = "ip-#{System.unique_integer()}"
      for _ <- 1..10, do: assert({:ok, nil} = Links.check_gate(link, %{}, key))
      assert {:error, :rate_limited} = Links.check_gate(link, %{}, key)
    end
  end

  describe "verification codes" do
    setup %{scope: scope, doc: doc} do
      {:ok, link} =
        Links.create_link(scope, doc, %{"name" => "Verified", "require_verification" => "true"})

      %{link: Readout.Repo.preload(link, :document)}
    end

    defp sent_code do
      [job] = all_enqueued(worker: Readout.Mailer.DeliverJob)
      :ok = perform_job(Readout.Mailer.DeliverJob, job.args)

      Swoosh.TestAssertions.assert_email_sent(fn email ->
        [_, code] = Regex.run(~r/(\d{6})/, email.text_body)
        send(self(), {:code, code})
        true
      end)

      assert_received {:code, code}
      code
    end

    test "emails a code that works once", %{link: link} do
      assert :ok = Links.send_verification(link, "ana@client.com", "es", "ip")
      code = sent_code()

      assert {:error, :wrong_code} =
               Links.verify_code(
                 link,
                 "ana@client.com",
                 "000000" |> then(&if(&1 == code, do: "111111", else: &1))
               )

      assert {:error, :expired} = Links.verify_code(link, "other@client.com", code)
      assert :ok = Links.verify_code(link, "ana@client.com", code)
      assert {:error, :expired} = Links.verify_code(link, "ana@client.com", code)
    end

    test "allows only a few attempts per code", %{link: link} do
      :ok = Links.send_verification(link, "ana@client.com", "en", "ip")
      code = sent_code()
      wrong = if code == "123456", do: "654321", else: "123456"

      for _ <- 1..5,
          do: assert({:error, :wrong_code} = Links.verify_code(link, "ana@client.com", wrong))

      assert {:error, :too_many_attempts} = Links.verify_code(link, "ana@client.com", code)
    end

    test "limits how many codes are sent", %{link: link} do
      email = "spam#{System.unique_integer([:positive])}@client.com"
      for _ <- 1..3, do: assert(:ok = Links.send_verification(link, email, "en", "ip"))
      assert {:error, :rate_limited} = Links.send_verification(link, email, "en", "ip")
    end

    test "codes are stored hashed, never in clear", %{link: link} do
      :ok = Links.send_verification(link, "ana@client.com", "en", "ip")
      code = sent_code()
      [v] = Readout.Repo.all(Readout.Links.Verification)
      refute v.code_hash == code
      refute inspect(v) =~ code
    end
  end

  describe "visits" do
    test "start with the current version and end once", %{link: link} do
      {:ok, link} = Links.fetch_public_link(link.slug)

      visit =
        Links.start_visit!(link, %{
          email: "a@b.com",
          email_verified: true,
          ip: "1.2.3.4",
          user_agent: "UA"
        })

      assert visit.version_id == link.document.current_version_id
      assert :ok = Links.end_visit(visit)
      assert Links.get_visit(visit.id).ended_at

      assert [%{link_count: 1, views_7d: 1}] =
               Documents.list_documents(Scope.for_user(admin_fixture()))
    end
  end
end
