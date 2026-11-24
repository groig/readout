defmodule Readout.InfraTest do
  @moduledoc "Client IPs behind a proxy, rate limiting, background email."
  use Readout.DataCase, async: true
  use Oban.Testing, repo: Readout.Repo

  alias Readout.RateLimit
  alias ReadoutWeb.ClientIP

  describe "ClientIP.resolve/2" do
    test "ignores X-Forwarded-For from untrusted peers" do
      assert ClientIP.resolve({203, 0, 113, 9}, ["1.1.1.1"]) == {203, 0, 113, 9}
    end

    test "takes the closest untrusted address behind a trusted proxy" do
      # Client spoofs 6.6.6.6; Caddy appends the real 198.51.100.7.
      assert ClientIP.resolve({127, 0, 0, 1}, ["6.6.6.6, 198.51.100.7"]) == {198, 51, 100, 7}
      assert ClientIP.resolve({127, 0, 0, 1}, []) == {127, 0, 0, 1}

      assert ClientIP.resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["2001:db8::5"]) ==
               {8193, 3512, 0, 0, 0, 0, 0, 5}
    end

    test "parses CIDRs" do
      assert ClientIP.parse_cidr("10.0.0.0/8") == {{10, 0, 0, 0}, 8}
      assert ClientIP.parse_cidr("::1/128") == {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
      assert ClientIP.parse_cidr("garbage") == nil
    end
  end

  test "rate limit counts per key within a window" do
    key = {:test, System.unique_integer()}
    assert :ok = RateLimit.hit(key, 2, 60_000)
    assert :ok = RateLimit.hit(key, 2, 60_000)
    assert {:error, :rate_limited} = RateLimit.hit(key, 2, 60_000)
    RateLimit.reset(key)
    assert :ok = RateLimit.hit(key, 2, 60_000)
  end

  describe "background email" do
    test "jobs carry the email encrypted and deliver it" do
      email =
        ReadoutWeb.Emails.login("ana@client.com", "en", %{
          url: "https://x/secret-token",
          name: "Ana"
        })

      {:ok, _} = Readout.Mailer.deliver_later(email)

      [job] = all_enqueued(worker: Readout.Mailer.DeliverJob)
      refute inspect(job.args) =~ "secret-token"
      refute inspect(job.args) =~ "ana@client.com"

      assert :ok = perform_job(Readout.Mailer.DeliverJob, job.args)
      Swoosh.TestAssertions.assert_email_sent(subject: "Your Readout sign-in link")
    end

    test "emails are translated and escape what they interpolate" do
      email =
        ReadoutWeb.Emails.verification_code("a@b.com", "es", %{
          code: "123456",
          document: "<script>alert(1)</script>",
          workspace: "Readout",
          minutes: 10
        })

      assert email.subject =~ "123456"
      assert email.html_body =~ "&lt;script&gt;"
      refute email.html_body =~ "<script>"
      assert email.text_body =~ "Introduce" or email.text_body =~ "código"
    end
  end
end
