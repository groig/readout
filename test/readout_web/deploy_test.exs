defmodule ReadoutWeb.DeployTest do
  @moduledoc "Health check, proxy awareness and internal tools."
  use ReadoutWeb.ConnCase, async: true

  import Readout.AccountsFixtures

  test "GET /healthz reports the database and storage", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert json_response(conn, 200) == %{"status" => "ok", "database" => true, "storage" => true}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /healthz answers only the container itself" do
    proxied = build_conn() |> put_req_header("x-forwarded-for", "198.51.100.7") |> get("/healthz")
    assert response(proxied, 404) == "Not found"

    outside = %{build_conn() | remote_ip: {172, 18, 0, 5}} |> get("/healthz")
    assert response(outside, 404)
  end

  test "HTTPS from a trusted proxy marks the request secure" do
    conn =
      build_conn(:get, "/healthz")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-for", "198.51.100.7")
      |> ReadoutWeb.ClientIP.call([])

    assert conn.scheme == :https
    assert conn.remote_ip == {198, 51, 100, 7}

    spoofed =
      build_conn(:get, "/healthz")
      |> Map.put(:remote_ip, {203, 0, 113, 1})
      |> put_req_header("x-forwarded-proto", "https")
      |> ReadoutWeb.ClientIP.call([])

    assert spoofed.scheme == :http
  end

  test "LiveDashboard is for owners and admins only", %{conn: conn} do
    member = log_in_user(conn, user_fixture())
    assert response(get(member, "/dev/dashboard"), 404)

    admin = log_in_user(build_conn(), admin_fixture())
    assert get(admin, "/dev/dashboard").status in [200, 302]
  end
end
