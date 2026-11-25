defmodule ReadoutWeb.Plugs.Health do
  @moduledoc """
  `GET /healthz` for container health checks: 200 when the database answers
  and the storage directory is writable, 503 otherwise. Runs before sessions,
  logging and the router, and reveals nothing else.

  It does real work (a query, a file write), so only the container's own
  check may call it: a loopback peer with no `X-Forwarded-For` (a proxy
  always adds one), or a peer in `HEALTH_NETWORKS` (`:health_networks`) for
  an outside orchestrator. Everyone else gets a plain 404, before any work.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    if allowed?(conn), do: report(conn), else: conn |> send_resp(404, "Not found") |> halt()
  end

  def call(conn, _opts), do: conn

  defp allowed?(conn) do
    direct? = get_req_header(conn, "x-forwarded-for") == []

    loopback? =
      match?({127, _, _, _}, conn.remote_ip) or conn.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}

    (direct? and loopback?) or
      Enum.any?(
        Application.get_env(:readout, :health_networks, []),
        &ReadoutWeb.ClientIP.in_cidr?(conn.remote_ip, &1)
      )
  end

  defp report(conn) do
    checks = %{database: database?(), storage: storage?()}
    status = if Enum.all?(Map.values(checks)), do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(
      status,
      Jason.encode!(Map.put(checks, :status, if(status == 200, do: "ok", else: "error")))
    )
    |> halt()
  end

  defp database? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Readout.Repo, "SELECT 1", [], timeout: 2_000))
  rescue
    _ -> false
  end

  defp storage? do
    root = Application.fetch_env!(:readout, Readout.Storage)[:root]
    probe = Path.join(root, ".healthz")
    File.mkdir_p(root) == :ok and File.write(probe, "ok") == :ok
  end
end
