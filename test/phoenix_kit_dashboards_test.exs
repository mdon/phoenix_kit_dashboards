defmodule PhoenixKitDashboardsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Widget

  describe "PhoenixKit.Module behaviour" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitDashboards.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "is marked for auto-discovery" do
      attrs = PhoenixKitDashboards.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end

    test "core identity callbacks" do
      assert PhoenixKitDashboards.module_key() == "dashboards"
      assert PhoenixKitDashboards.module_name() == "Dashboards"
      assert PhoenixKitDashboards.version() == "0.1.0"
    end

    test "permission metadata key matches module key" do
      assert %{key: "dashboards"} = PhoenixKitDashboards.permission_metadata()
    end

    test "admin tabs are well-formed" do
      tabs = PhoenixKitDashboards.admin_tabs()
      assert Enum.any?(tabs, &(&1.id == :admin_dashboards))
      assert Enum.all?(tabs, &(&1.permission == "dashboards"))
    end

    test "css sources" do
      assert PhoenixKitDashboards.css_sources() == [:phoenix_kit_dashboards]
    end
  end

  describe "widget registry" do
    test "built-in widgets are discoverable" do
      keys = Enum.map(Registry.list(), & &1.key)
      assert "core.note" in keys
      assert "core.clock" in keys
      assert "core.module_stats" in keys
    end

    test "lookup by key returns a Widget struct" do
      assert %Widget{key: "core.note", component: _} = Registry.get("core.note")
    end

    test "built-in widgets have no module gate, so survive scope filtering" do
      built_in = Enum.filter(Registry.list(), &(&1.source == :builtin))
      assert built_in != []
      visible = Registry.list_for_scope(:some_scope)
      assert Enum.all?(built_in, fn w -> w.key in Enum.map(visible, & &1.key) end)
    end
  end

  describe "Widget.from_map/2" do
    defmodule DummyComponent do
      use Phoenix.LiveComponent
      def render(assigns), do: ~H""
    end

    test "normalizes a valid provider map" do
      assert {:ok, %Widget{key: "x.y", source: :prov}} =
               Widget.from_map(
                 %{key: "x.y", name: "Y", component: DummyComponent},
                 :prov
               )
    end

    test "rejects a map missing required fields" do
      assert {:error, {:missing_field, :component}} =
               Widget.from_map(%{key: "x.y", name: "Y"}, :prov)
    end

    test "default_settings derives from schema" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x.y",
            name: "Y",
            component: DummyComponent,
            settings_schema: [%{key: "a", type: :string, default: "z"}]
          },
          :prov
        )

      assert Widget.default_settings(widget) == %{"a" => "z"}
    end
  end
end
