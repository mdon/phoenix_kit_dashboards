defmodule PhoenixKitDashboards.Widgets.BuiltinWidgetsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitDashboards.Widgets.ModuleStatsWidget
  alias PhoenixKitDashboards.Widgets.NoteWidget

  describe "note widget" do
    defp render_note(settings, size \\ %{w: 4, h: 2}) do
      render_component(NoteWidget, id: "n1", settings: settings, size: size, scope: nil)
    end

    test "renders the body as sanitized Markdown" do
      html = render_note(%{"title" => "Links", "body" => "**bold** and [a link](https://x.dev)"})
      assert html =~ "<strong>"
      assert html =~ ~s(href="https://x.dev")

      # XSS-sanitized: a script tag never survives.
      dirty = render_note(%{"body" => "<script>alert(1)</script>hello"})
      refute dirty =~ "<script>"
      assert dirty =~ "hello"
    end

    test "empty body shows the hint instead of rendering markdown" do
      html = render_note(%{"body" => ""})
      assert html =~ "Empty note"
    end
  end

  describe "module stats widget" do
    test "module_options offers installed modules as {label, key} with a prompt first" do
      assert [{_prompt, ""} | options] = ModuleStatsWidget.module_options()
      assert {"Dashboards", "dashboards"} in options
      # Sorted by display name.
      names = Enum.map(options, fn {name, _} -> name end)
      assert names == Enum.sort(names)
    end

    test "the card title shows the module's display name, not the raw key" do
      html =
        render_component(ModuleStatsWidget,
          id: "s1",
          settings: %{"module_key" => "dashboards"},
          size: %{w: 4, h: 2},
          scope: nil
        )

      assert html =~ "Dashboards"

      unknown =
        render_component(ModuleStatsWidget,
          id: "s2",
          settings: %{"module_key" => "nope"},
          size: %{w: 4, h: 2},
          scope: nil
        )

      # Unknown module falls back to the raw key + the pick-a-module hint.
      assert unknown =~ "nope"
      assert unknown =~ "pick a module"
    end
  end
end
