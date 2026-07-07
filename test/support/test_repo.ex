defmodule PhoenixKitDashboards.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for integration tests.

  Configured in `config/test.exs` and started by `test_helper.exs`. Uses the SQL
  Sandbox for transaction-based test isolation. The schema is built by running
  core's versioned migrations via `PhoenixKit.Migration.ensure_current/2` — this
  module owns no DDL of its own (`phoenix_kit_dashboards` ships as core V133).
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_dashboards,
    adapter: Ecto.Adapters.Postgres
end
