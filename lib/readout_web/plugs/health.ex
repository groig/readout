defmodule ReadoutWeb.Plugs.Health do
  @moduledoc """
  `GET /healthz` for container health checks: 200 when the database answers
  and the storage directory is writable, 503 otherwise. Runs before sessions,
  logging and the router, and reveals nothing else.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
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

  def call(conn, _opts), do: conn

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
