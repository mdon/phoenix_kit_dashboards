import Config

# Wire PhoenixKit's RepoHelper to the test repo. Without this, every DB call
# through PhoenixKit.RepoHelper crashes with "No repository configured".
config :phoenix_kit, repo: PhoenixKitDashboards.Test.Repo

config :phoenix_kit_dashboards, PhoenixKitDashboards.Test.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "phoenix_kit_dashboards_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :phoenix_kit_dashboards,
  ecto_repos: [PhoenixKitDashboards.Test.Repo]

config :logger, level: :warning
