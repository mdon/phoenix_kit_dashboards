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
      assert PhoenixKitDashboards.version() == Mix.Project.config()[:version]
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

    test "js_sources declares the hook bundle, and the file actually ships" do
      assert [%{app: :phoenix_kit_dashboards, file: file, global: "PhoenixKitDashboardsHooks"}] =
               PhoenixKitDashboards.js_sources()

      # A rename of the asset would silently break every host bundle otherwise.
      path = Application.app_dir(:phoenix_kit_dashboards, "priv/#{file}")
      assert File.exists?(path), "js_sources points at a missing file: #{path}"
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
      # The built-ins are provided by this module itself, through the same
      # phoenix_kit_widgets/0 contract every provider uses.
      built_in = Enum.filter(Registry.list(), &(&1.source == PhoenixKitDashboards))
      assert built_in != []
      assert Enum.all?(built_in, &is_nil(&1.module_key))
      visible = Registry.list_for_scope(:some_scope)
      assert Enum.all?(built_in, fn w -> w.key in Enum.map(visible, & &1.key) end)
    end
  end

  describe "Registry.visible_for_scope?/2 (the placed-widget render gate)" do
    defmodule GateComponent do
      use Phoenix.LiveComponent
      def render(assigns), do: ~H""
    end

    defp gate_widget(module_key) do
      {:ok, widget} =
        Widget.from_map(
          %{key: "g.#{module_key || "none"}", name: "G", component: GateComponent}
          |> Map.merge(if module_key, do: %{module_key: module_key}, else: %{}),
          :prov
        )

      widget
    end

    test "a widget with no module_key is visible to any scope" do
      assert Registry.visible_for_scope?(gate_widget(nil), :any_scope)
      assert Registry.visible_for_scope?(gate_widget(nil), nil)
    end

    test "a widget whose module is disabled is NOT visible — even to a nil scope" do
      # "dashboards" resolves to this module via ModuleRegistry; enabled?/0 is
      # false in the test env (no enabling setting — the settings query errors
      # outside a sandbox checkout and enabled?/0 rescues to false; capture that
      # expected error log), so the gate must close for a placed widget exactly
      # like it hides the catalog entry.
      ExUnit.CaptureLog.capture_log(fn ->
        refute Registry.visible_for_scope?(gate_widget("dashboards"), nil)
        refute Registry.visible_for_scope?(gate_widget("dashboards"), :any_scope)
      end)
    end

    test "an unknown module_key passes enablement; a nil scope skips the permission half" do
      assert Registry.visible_for_scope?(gate_widget("no_such_module"), nil)
      # A non-Scope term fails the permission check closed.
      refute Registry.visible_for_scope?(gate_widget("no_such_module"), :not_a_scope)
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

    test "normalizes view variants and drops malformed ones" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x.y",
            name: "Y",
            component: DummyComponent,
            views: [%{key: "detailed", name: "Detailed"}, %{key: "simple"}, %{name: "no key"}]
          },
          :prov
        )

      assert widget.views == [
               %{key: "detailed", name: "Detailed"},
               %{key: "simple", name: "simple"}
             ]

      assert Widget.default_view(widget) == "detailed"
    end

    test "default_view is nil when the widget declares no views" do
      {:ok, widget} = Widget.from_map(%{key: "x.y", name: "Y", component: DummyComponent}, :prov)
      assert widget.views == []
      assert Widget.default_view(widget) == nil
    end

    test "a view may declare its own min_size, clamped into the widget's max" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x.y",
            name: "Y",
            component: DummyComponent,
            min_size: %{w: 2, h: 1},
            max_size: %{w: 8, h: 4},
            views: [
              %{key: "text", name: "Text"},
              %{key: "big", name: "Big", min_size: %{w: 4, h: 3}},
              %{key: "huge", name: "Huge", min_size: %{w: 99, h: 99}},
              %{key: "junk", name: "Junk", min_size: "nope"}
            ]
          },
          :prov
        )

      # Per-view min honoured; oversize clamps to the lattice bound (declared
      # max_size is ignored on the screenful lattice); junk dropped.
      assert Widget.min_size_for(widget, "big") == %{w: 4, h: 3}
      assert Widget.min_size_for(widget, "huge") == %{w: 99, h: 99}
      # Views without (or with malformed) min fall back to the widget's min.
      assert Widget.min_size_for(widget, "text") == %{w: 2, h: 1}
      assert Widget.min_size_for(widget, "junk") == %{w: 2, h: 1}
      # An unknown view and nil (→ default view "text") fall back too.
      assert Widget.min_size_for(widget, "ghost") == %{w: 2, h: 1}
      assert Widget.min_size_for(widget, nil) == %{w: 2, h: 1}
    end

    test "min_size_for(nil) resolves through the default view's own min" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x.y",
            name: "Y",
            component: DummyComponent,
            min_size: %{w: 2, h: 1},
            views: [%{key: "first", name: "First", min_size: %{w: 5, h: 2}}]
          },
          :prov
        )

      # An instance created before views existed (view nil) uses the default
      # view's floor, and a widget with no views at all uses its own min.
      assert Widget.min_size_for(widget, nil) == %{w: 5, h: 2}
      {:ok, plain} = Widget.from_map(%{key: "p", name: "P", component: DummyComponent}, :prov)
      assert Widget.min_size_for(plain, nil) == plain.min_size
    end

    test "drops a non-map provider entry rather than crashing discovery" do
      assert {:error, :not_a_map} = Widget.from_map("oops", :prov)
      assert {:error, :not_a_map} = Widget.from_map(nil, :prov)
    end

    test "rejects a non-atom or non-LiveComponent component" do
      assert {:error, {:invalid_component, _}} =
               Widget.from_map(%{key: "x", name: "Y", component: "NotAModule"}, :prov)

      # Enum is loaded but is not a Phoenix.LiveComponent.
      assert {:error, {:not_a_live_component, Enum}} =
               Widget.from_map(%{key: "x", name: "Y", component: Enum}, :prov)
    end

    test "select options may be {label, value} tuples (kept through normalization)" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x",
            name: "Y",
            component: DummyComponent,
            settings_schema: [
              %{key: "m", type: :select, options: [{"Pretty", "ugly_key"}], default: ""}
            ]
          },
          :prov
        )

      assert [%{options: [{"Pretty", "ugly_key"}]}] = widget.settings_schema
    end

    test "normalizes settings_schema and drops malformed fields" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x",
            name: "Y",
            component: DummyComponent,
            settings_schema: [
              %{key: "a", type: :select, options: ["1", "2"], default: "1"},
              %{type: :string},
              "junk"
            ]
          },
          :prov
        )

      assert [%{key: "a", type: :select, options: ["1", "2"], default: "1"}] =
               widget.settings_schema
    end

    test "sanitizes incoherent size bounds (min <= default <= max, within the lattice cap)" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x",
            name: "Y",
            component: DummyComponent,
            min_size: %{w: 170, h: 0},
            max_size: %{w: 300, h: 12},
            default_size: %{w: 1, h: 999}
          },
          :prov
        )

      # min_w clamped into [1, max_dim]; the max is ALWAYS the lattice bound
      # (declared max_size ignored); default clamped into [min, max].
      cap = PhoenixKitDashboards.Lattice.max_dim()
      assert widget.min_size == %{w: cap, h: 1}
      assert widget.max_size == %{w: cap, h: cap}
      assert widget.default_size == %{w: cap, h: cap}
    end

    test "every widget can span the full lattice — declared max_size is ignored" do
      assert PhoenixKitDashboards.Lattice.max_dim() == 160

      # Providers still shipping old-unit declarations (max 6x2 meant half a
      # 12-col screen) must not cap lattice resizes at nonsense.
      {:ok, widget} =
        Widget.from_map(
          %{key: "x", name: "Y", component: DummyComponent, max_size: %{w: 6, h: 2}},
          :prov
        )

      assert widget.max_size == %{w: 160, h: 160}

      {:ok, unbounded} = Widget.from_map(%{key: "x", name: "Y", component: DummyComponent}, :prov)
      assert unbounded.max_size.w == 160
    end

    test "design dims derive from the lattice's 25px square cell" do
      assert PhoenixKitDashboards.Lattice.cell() == 25
      assert PhoenixKitDashboards.Lattice.design_width(64) == 1600
      assert PhoenixKitDashboards.Lattice.design_height(36) == 900
      assert PhoenixKitDashboards.Lattice.design_width(160) == 4000
    end
  end

  describe "built-in module_stats widget" do
    test "declares detailed + compact views" do
      widget = Registry.get("core.module_stats")
      assert Enum.map(widget.views, & &1.key) == ["detailed", "compact"]
    end
  end

  describe "live refresh contract" do
    test "clock declares a refresh interval; note is static" do
      assert Registry.get("core.clock").refresh_interval == 1000
      assert Registry.get("core.note").refresh_interval == nil
    end

    test "from_map clamps a too-small interval to the 1s floor" do
      {:ok, widget} =
        Widget.from_map(
          %{
            key: "x",
            name: "X",
            component: PhoenixKitDashboards.Widgets.NoteWidget,
            refresh_interval: 50
          },
          :prov
        )

      assert widget.refresh_interval == 1000
    end
  end
end
