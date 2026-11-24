defmodule ReadoutWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a strict Content-Security-Policy with a per-request nonce.

  Scripts only load from our origin, plus the one inline script in the root
  layout (theme before first paint), which carries the nonce. Inline `style`
  attributes are allowed because LiveView's JS commands and our charts set
  them. Nothing is loaded from third parties.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self'",
        "connect-src 'self' #{websocket_origins()}",
        "media-src 'self'",
        "object-src 'none'",
        "frame-src #{frame_src()}",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "manifest-src 'self'",
        "worker-src 'self' blob:"
      ],
      "; "
    )
  end

  # Dev only: the live-reload iframe is same-origin.
  defp frame_src, do: Application.get_env(:readout, :csp_frame_src, "'none'")

  # Browsers disagree on whether 'self' covers ws(s): of the same host.
  defp websocket_origins do
    url = ReadoutWeb.Endpoint.url()
    String.replace(url, ~r/^http/, "ws")
  end
end
