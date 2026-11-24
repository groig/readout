defmodule ReadoutWeb.Locale do
  @moduledoc """
  Resolves the UI locale and time zone, as a plug (plain requests) and as a
  LiveView `on_mount` hook.

  Locale, in order:

    1. the user's profile setting, unless it is "auto";
    2. otherwise the browser's `Accept-Language`;
    3. otherwise English.

  The public viewer passes `from: :browser` to skip step 1.

  Time zone: the browser's zone (LiveView connect params, or the `tz` cookie
  set by app.js), unless the profile overrides it. Everything is stored in UTC.
  """

  import Plug.Conn

  alias Readout.Accounts.{Scope, User}

  @supported ~w(en es)
  @default "en"

  def supported, do: @supported

  ## Plug

  def init(opts), do: Keyword.get(opts, :from, :user)

  def call(conn, from) do
    conn = fetch_cookies(conn)
    browser_locale = conn |> get_req_header("accept-language") |> List.first() |> from_header()
    user = if from == :user, do: current_user(conn.assigns[:current_scope])
    locale = resolve(user, browser_locale)
    timezone = conn.cookies["tz"]

    Gettext.put_locale(ReadoutWeb.Gettext, locale)

    scope =
      conn.assigns[:current_scope]
      |> Scope.put_locale(locale)
      |> Scope.put_browser_timezone(timezone)

    conn
    |> assign(:locale, locale)
    |> assign(:current_scope, scope)
    |> put_session(:browser_locale, browser_locale)
    |> put_session(:browser_timezone, timezone)
  end

  ## LiveView

  def on_mount(from, _params, session, socket) when from in [:default, :user, :browser] do
    user = if from != :browser, do: current_user(socket.assigns[:current_scope])
    locale = resolve(user, session["browser_locale"])

    timezone =
      (Phoenix.LiveView.connected?(socket) &&
         Phoenix.LiveView.get_connect_params(socket)["timezone"]) || session["browser_timezone"]

    Gettext.put_locale(ReadoutWeb.Gettext, locale)

    socket =
      socket
      |> Phoenix.Component.assign(:locale, locale)
      |> Phoenix.Component.assign(
        :current_scope,
        socket.assigns[:current_scope]
        |> Scope.put_locale(locale)
        |> Scope.put_browser_timezone(timezone)
      )

    {:cont, socket}
  end

  defp current_user(%Scope{user: %User{} = user}), do: user
  defp current_user(_), do: nil

  ## Resolution

  @doc "Picks the locale from a user preference and a browser locale."
  def resolve(%User{locale: locale}, _browser) when locale in @supported, do: locale
  def resolve(_user, browser) when browser in @supported, do: browser
  def resolve(_user, _browser), do: @default

  @doc """
  Returns the best supported locale from an `Accept-Language` header, or nil.

      iex> ReadoutWeb.Locale.from_header("es-ES,es;q=0.9,en;q=0.8")
      "es"
  """
  def from_header(nil), do: nil

  def from_header(header) when is_binary(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.map(&parse_language_range/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_lang, q} -> q end, :desc)
    |> Enum.find_value(fn {lang, _q} -> if lang in @supported, do: lang end)
  end

  defp parse_language_range(range) do
    [tag | params] = range |> String.trim() |> String.split(";")
    lang = tag |> String.split("-") |> hd() |> String.downcase()

    q =
      Enum.find_value(params, 1.0, fn param ->
        case String.split(String.trim(param), "=") do
          ["q", value] -> parse_q(value)
          _ -> nil
        end
      end)

    if lang != "" and q > 0, do: {lang, q}
  end

  defp parse_q(value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end
end
