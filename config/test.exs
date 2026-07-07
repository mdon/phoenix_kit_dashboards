import Config

config :phoenix_kit_dashboards, ecto_repos: [PhoenixKitDashboards.Test.Repo]

config :phoenix_kit_dashboards, PhoenixKitDashboards.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_dashboards_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire PhoenixKit's RepoHelper to the test repo. Without this, every DB call
# through PhoenixKit.RepoHelper crashes with "No repository configured".
config :phoenix_kit, repo: PhoenixKitDashboards.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_dashboards` has no endpoint of
# its own in production — the host app provides one — so this endpoint only
# exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_dashboards, PhoenixKitDashboards.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "dashboards-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitDashboards.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
