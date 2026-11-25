import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :readout, Readout.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "readout_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :readout, ReadoutWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Dl5tzeyLqay/dnyxa9lgGCsDhNO1mYAKePA0rpC/Ts+r73fVpgt6Y2p3SnsDc6Gr",
  server: false

# In test we don't send emails
config :readout, Readout.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Keep /dev routes (style guide, mailbox) in tests so they stay covered.
config :readout, dev_routes: true

# Jobs run only when a test asks for them (Oban.Testing).
config :readout, Oban, testing: :manual

config :readout, Readout.Storage,
  root:
    Path.join(System.tmp_dir!(), "readout-test-storage-#{System.get_env("MIX_TEST_PARTITION")}")

# Tests use generated databases (Readout.GeoIPFixture), never the dev one.
config :readout, :geoip_db_path, nil

# Every test request comes from 127.0.0.1: only the per-account login limit
# applies (the client limit is tested in GlobalConfigTest).
config :readout, :login_limits, client: 1_000_000, account: 10
