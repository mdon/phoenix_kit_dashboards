defmodule PhoenixKitDashboards.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox connection.

  Tests using this case are tagged `:integration` automatically and get excluded
  when the test DB isn't available.

  ## Example

      defmodule PhoenixKitDashboards.Web.DashboardsLiveTest do
        use PhoenixKitDashboards.LiveCase

        test "renders", %{conn: conn} do
          conn = put_test_scope(conn, fake_scope())
          {:ok, _view, html} = live(conn, "/en/admin/dashboards")
          assert html =~ "Dashboards"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitDashboards.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitDashboards.ActivityLogAssertions
      import PhoenixKitDashboards.Fixtures
      import PhoenixKitDashboards.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDashboards.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Dashboards LVs read `socket.assigns[:phoenix_kit_current_user].uuid` for
  ownership checks and pass `:phoenix_kit_current_scope` into
  `Registry.list_for_scope/1` and the grid. They do not call `Scope.admin?/1` or
  `has_module_access?/2`, so the role/permission fields are present but unused.
  Per workspace AGENTS.md, `cached_roles` must be a list of role-name strings if
  `admin?/1` is ever called — dashboards doesn't, but we follow the convention.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — list of module-key strings; defaults to `["dashboards"]`
    * `:authenticated?` — defaults to `true`
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, ["dashboards"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the `:assign_scope`
  `on_mount` hook can put it on socket assigns at mount time. Pair with
  `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  @doc "Creates a personal Dashboard fixture owned by `user_uuid`."
  def fixture_dashboard(user_uuid, attrs \\ %{}) do
    {:ok, dashboard} =
      PhoenixKitDashboards.Dashboards.create(
        Map.merge(
          %{
            title: "Dashboard #{System.unique_integer([:positive])}",
            scope: "personal",
            owner_user_uuid: user_uuid
          },
          attrs
        )
      )

    dashboard
  end
end
