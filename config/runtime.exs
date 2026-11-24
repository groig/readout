import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/readout start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :readout, ReadoutWeb.Endpoint, server: true
end

config :readout, ReadoutWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :readout, ReadoutWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/readout_web/router\.ex$"E,
        ~r"lib/readout_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :readout, Readout.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :readout, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :readout, ReadoutWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # TLS terminates at Caddy; the app speaks plain HTTP on the private network.

  ## Readout settings (all from the environment)

  config :readout, Readout.Storage,
    root:
      System.get_env("STORAGE_PATH") ||
        raise("environment variable STORAGE_PATH is missing (where uploaded files live)")

  config :readout, Readout.Documents,
    max_upload_bytes: String.to_integer(System.get_env("MAX_UPLOAD_MB") || "100") * 1024 * 1024,
    tool_timeout: String.to_integer(System.get_env("TOOL_TIMEOUT") || "180")

  # Reverse proxies allowed to set X-Forwarded-For (CIDRs, comma-separated).
  # Defaults cover loopback and the private ranges Docker networks use.
  config :readout,
         :trusted_proxies,
         (System.get_env("TRUSTED_PROXIES") ||
            "127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  ## Email (optional). Without SMTP_HOST, invitations are copyable links and
  ## links can't require email verification.

  config :readout,
         :mail_from,
         {System.get_env("MAIL_FROM_NAME") || "Readout",
          System.get_env("MAIL_FROM") || "readout@#{host}"}

  if smtp_host = System.get_env("SMTP_HOST") do
    config :readout, Readout.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      auth: :always,
      # Port 587 with STARTTLS (Office 365); the certificate is verified.
      ssl: false,
      tls: :always,
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(smtp_host),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      retries: 2,
      no_mx_lookups: true

    config :readout, :mail_enabled, true
  else
    config :readout, :mail_enabled, false
  end

  config :readout, :rocketchat_webhook_url, System.get_env("ROCKETCHAT_WEBHOOK_URL")
end
