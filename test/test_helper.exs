# Two levels: unit tests always run; integration tests (`:integration` tag, via
# DataCase/LiveCase) require PostgreSQL and are auto-excluded when the DB is
# unavailable.
#   mix test.setup   # createdb
#   mix test         # schema built by PhoenixKit.Migration.ensure_current/2 below
#
# Elixir 1.19 no longer auto-loads test/support modules — require them explicitly.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "fixtures.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

db_name =
  Application.get_env(:phoenix_kit_dashboards, PhoenixKitDashboards.Test.Repo)[:database] ||
    "phoenix_kit_dashboards_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitDashboards.Test.Repo.start_link()

      # Build the schema by running core's versioned migrations directly
      # (phoenix_kit_dashboards ships as core V133 — no module-owned DDL).
      PhoenixKit.Migration.ensure_current(PhoenixKitDashboards.Test.Repo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitDashboards.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_dashboards, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so runtime deps (PubSub topics, ModuleRegistry
# — which Registry.provider_modules/0 queries) resolve.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache so `Paths.index()` etc. produce paths that
# match the test router (no settings table to read the prefix from).
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint (server: false) only when the DB is available.
if repo_available do
  {:ok, _} = PhoenixKitDashboards.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
