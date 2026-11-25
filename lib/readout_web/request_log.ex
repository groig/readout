defmodule ReadoutWeb.RequestLog do
  @moduledoc """
  The request log: one line per request with the method, the matched route
  *template*, the status and the duration, e.g.

      GET /v/:slug/p/:token/:number/:width 200 in 3ms

  Paths in Readout carry bearer credentials (share slugs, viewer tokens,
  sign-in, reset, invitation and email-change tokens), so the real path is
  never logged. Phoenix's own request log is turned off in the endpoint
  (`Plug.Telemetry, log: false`) and this handler replaces it. Parameters
  logged elsewhere at debug level are filtered by `:filter_parameters`.
  """
  require Logger

  @handler "readout-request-log"

  @doc "Attaches the handler (once, at application start)."
  def attach do
    :telemetry.attach(@handler, [:phoenix, :endpoint, :stop], &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    Logger.info(fn ->
      [conn.method, ?\s, route(conn), ?\s, status(conn.status), " in ", format(duration)]
    end)
  end

  @doc "The route template for a request, or a placeholder when nothing matches."
  def route(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(ReadoutWeb.Router, conn.method, conn.path_info, conn.host) do
      %{route: route} -> route
      _ -> "(unmatched)"
    end
  end

  defp status(nil), do: "-"
  defp status(status), do: Integer.to_string(status)

  defp format(duration) do
    us = System.convert_time_unit(duration, :native, :microsecond)

    if us > 1000,
      do: [Integer.to_string(div(us, 1000)), "ms"],
      else: [Integer.to_string(us), "µs"]
  end
end
