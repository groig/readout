defmodule ReadoutWeb.LocaleAndFormatTest do
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures

  alias Readout.Accounts.{Scope, User}
  alias ReadoutWeb.{Format, Locale}

  describe "Locale.from_header/1" do
    test "picks the best supported language by quality" do
      assert Locale.from_header("es-ES,es;q=0.9,en;q=0.8") == "es"
      assert Locale.from_header("fr-FR,fr;q=0.9,es;q=0.5,en;q=0.7") == "en"
      assert Locale.from_header("de, fr") == nil
      assert Locale.from_header("es;q=0, en") == "en"
      assert Locale.from_header("") == nil
      assert Locale.from_header(nil) == nil
    end
  end

  describe "Locale.resolve/2" do
    test "profile first, unless automatic; then browser; then English" do
      assert Locale.resolve(%User{locale: "es"}, "en") == "es"
      assert Locale.resolve(%User{locale: "auto"}, "es") == "es"
      assert Locale.resolve(%User{locale: "auto"}, nil) == "en"
      assert Locale.resolve(nil, "es") == "es"
      assert Locale.resolve(nil, "xx") == "en"
    end
  end

  describe "locale in requests" do
    setup do
      user_fixture()
      :ok
    end

    test "the browser's language sets <html lang> and the UI", %{conn: conn} do
      conn = conn |> put_req_header("accept-language", "es-ES,es;q=0.9") |> get(~p"/users/log-in")
      html = html_response(conn, 200)
      assert html =~ ~s(lang="es")
      assert html =~ "Iniciar sesión"
    end

    test "the profile overrides the browser", %{conn: conn} do
      user = user_fixture(locale: "es")

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept-language", "en")
        |> get(~p"/documents")

      assert html_response(conn, 200) =~ ~s(lang="es")
    end

    test "English by default", %{conn: conn} do
      assert html_response(get(conn, ~p"/users/log-in"), 200) =~ ~s(lang="en")
    end
  end

  describe "Format" do
    setup do
      Gettext.put_locale(ReadoutWeb.Gettext, "en")
      :ok
    end

    test "numbers follow the locale" do
      assert Format.number(1_234_567) == "1,234,567"
      assert Format.number(12.5) == "12.5"
      Gettext.put_locale(ReadoutWeb.Gettext, "es")
      assert Format.number(1_234_567) == "1.234.567"
      assert Format.number(1234) == "1234"
      assert Format.number(12.5) == "12,5"
    end

    test "durations" do
      assert Format.duration(42) == "42s"
      assert Format.duration(125) == "2m 05s"
      assert Format.duration(3720) == "1h 02m"
    end

    test "dates are shifted into the scope's time zone" do
      scope = %Scope{timezone: "Europe/Madrid"}
      # 23:30 UTC on 31 Dec is already 1 Jan in Madrid.
      dt = ~U[2026-12-31 23:30:00Z]
      assert Format.datetime(dt, scope) == "1 Jan 2027, 00:30"
      Gettext.put_locale(ReadoutWeb.Gettext, "es")
      assert Format.date(dt, scope) == "1 ene 2027"
    end

    test "relative times" do
      now = ~U[2026-06-01 12:00:00Z]
      scope = %Scope{}
      assert Format.relative(DateTime.add(now, -10), scope, now) == "just now"
      assert Format.relative(DateTime.add(now, -180), scope, now) == "3 min ago"
      assert Format.relative(DateTime.add(now, -7200), scope, now) == "2 h ago"
      assert Format.relative(DateTime.add(now, -100_000), scope, now) == "yesterday"
      assert Format.relative(DateTime.add(now, -3 * 86_400), scope, now) == "3 days ago"
      assert Format.relative(nil, scope, now) == "never"
      Gettext.put_locale(ReadoutWeb.Gettext, "es")
      assert Format.relative(DateTime.add(now, -180), scope, now) == "hace 3 min"
    end
  end
end
