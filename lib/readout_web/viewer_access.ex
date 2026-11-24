defmodule ReadoutWeb.ViewerAccess do
  @moduledoc """
  How a viewer's access to a link is remembered and how page URLs are signed.

    * **Grants** live in the session (`"viewer_grants"`, by link id) once the
      gate is passed. A grant older than the link's last change is ignored, so
      changing a password or the allow list sends everyone back to the gate.
    * **Verified emails** are remembered on the device for 30 days in a signed
      cookie per link (`rv_<slug>`), so returning viewers skip the code.
    * **Devices**: a random id per browser and link (`rd_<slug>`), to count
      anonymous viewers by device rather than by IP.
    * **Page and download URLs** carry a `Phoenix.Token` bound to the visit,
      valid for two hours.
  """
  import Plug.Conn

  alias Readout.Links.Link

  @grant_salt "viewer grant"
  @page_salt "viewer page"
  @verified_max_age 30 * 24 * 3600
  @page_max_age 2 * 3600

  ## Plug: copy the verified-email cookie for /v/:slug into the session

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["v", slug | _]} = conn, _opts) do
    conn = fetch_cookies(conn, signed: [cookie_name(slug)])

    conn =
      case conn.cookies[cookie_name(slug)] do
        email when is_binary(email) -> put_session(conn, "verified:" <> slug, email)
        _ -> conn
      end

    ensure_device(conn, slug)
  end

  def call(conn, _opts), do: conn

  def cookie_name(slug), do: "rv_" <> slug

  # A random id per browser and link (first-party, HTTP-only, a year), so
  # anonymous readers count as distinct viewers even behind one IP. It holds
  # nothing but randomness and is scoped to the link's path.
  defp ensure_device(conn, slug) do
    name = "rd_" <> slug

    case conn.cookies[name] do
      id when is_binary(id) and byte_size(id) in 16..32 ->
        put_session(conn, "device:" <> slug, id)

      _ ->
        id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        conn
        |> put_resp_cookie(name, id,
          max_age: 365 * 24 * 3600,
          same_site: "Lax",
          http_only: true,
          path: "/v/" <> slug
        )
        |> put_session("device:" <> slug, id)
    end
  end

  def remember_verified(conn, slug, email) do
    put_resp_cookie(conn, cookie_name(slug), email,
      sign: true,
      max_age: @verified_max_age,
      same_site: "Lax",
      http_only: true,
      path: "/v/" <> slug
    )
  end

  ## Grants

  @doc "A short-lived token the gate LiveView hands to the access controller."
  def sign_grant(%Link{} = link, email, verified?) do
    Phoenix.Token.sign(ReadoutWeb.Endpoint, @grant_salt, %{
      "link_id" => link.id,
      "email" => email,
      "verified" => verified?
    })
  end

  def verify_grant(token),
    do: Phoenix.Token.verify(ReadoutWeb.Endpoint, @grant_salt, token, max_age: 120)

  @doc "The session grant for a link, if still valid."
  def grant(session, %Link{} = link) do
    with %{} = grants <- session["viewer_grants"],
         %{"at" => at} = grant <- grants[link.id],
         true <- at >= DateTime.to_unix(link.updated_at) do
      grant
    else
      _ -> nil
    end
  end

  def put_grant(conn, link_id, email, verified?) do
    grants =
      (get_session(conn, "viewer_grants") || %{})
      |> Map.put(link_id, %{
        "email" => email,
        "verified" => verified?,
        "at" => System.os_time(:second)
      })
      # Keep the session cookie small.
      |> Enum.sort_by(fn {_id, g} -> g["at"] end, :desc)
      |> Enum.take(20)
      |> Map.new()

    put_session(conn, "viewer_grants", grants)
  end

  ## Page URLs

  def sign_visit(visit_id), do: Phoenix.Token.sign(ReadoutWeb.Endpoint, @page_salt, visit_id)

  def verify_visit(token),
    do: Phoenix.Token.verify(ReadoutWeb.Endpoint, @page_salt, token, max_age: @page_max_age)
end
