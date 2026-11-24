# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :readout, :scopes,
  user: [
    default: true,
    module: Readout.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Readout.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :readout,
  ecto_repos: [Readout.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :readout, ReadoutWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ReadoutWeb.ErrorHTML, json: ReadoutWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Readout.PubSub,
  live_view: [signing_salt: "/6M1CzBS"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Background jobs (Postgres-backed). Documents are processed one or two at a
# time: LibreOffice and rasterizing are CPU-heavy.
config :readout, Oban,
  engine: Oban.Engines.Basic,
  repo: Readout.Repo,
  queues: [documents: 2, mailers: 5, default: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Files live on local disk under STORAGE_PATH (see runtime.exs), behind the
# Readout.Storage behaviour so S3-compatible storage can be added later.
config :readout, Readout.Storage,
  adapter: Readout.Storage.Local,
  root: Path.expand("../tmp/storage", __DIR__)

config :readout, Readout.Documents,
  # Uploads larger than this are rejected (MAX_UPLOAD_MB in production).
  max_upload_bytes: 100 * 1024 * 1024,
  # Seconds before an external tool (LibreOffice, pdftoppm...) is killed.
  tool_timeout: 180

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :readout, Readout.Mailer, adapter: Swoosh.Adapters.Local
# Dev uses the local mailbox (/dev/mailbox). Prod turns this on when SMTP_HOST is set.
config :readout, :mail_enabled, true
config :readout, :mail_from, {"Readout", "readout@localhost"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  readout: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  readout: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# IANA time zones (DST-correct local times for users)
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Gettext: English is the source language, Spanish ships complete.
config :readout, ReadoutWeb.Gettext, default_locale: "en", locales: ~w(en es)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
