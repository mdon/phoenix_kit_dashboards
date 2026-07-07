defmodule PhoenixKitDashboards.Widgets do
  @moduledoc """
  The built-in widget catalog shipped with this module.

  These give a dashboard immediate value even on a host with zero widget
  providers installed. Each entry follows the same plain-map contract that
  external providers use (see `PhoenixKitDashboards.Widget`), so the built-ins
  are also a worked reference for module authors.
  """

  alias PhoenixKitDashboards.Widgets.ClockWidget
  alias PhoenixKitDashboards.Widgets.ModuleStatsWidget
  alias PhoenixKitDashboards.Widgets.NoteWidget

  @doc "List of built-in widget definitions (plain maps)."
  @spec builtin() :: [map()]
  def builtin do
    [
      %{
        key: "core.note",
        name: "Note",
        description: "A free-text note for reminders, links, or context.",
        icon: "hero-pencil-square",
        component: NoteWidget,
        default_size: %{w: 4, h: 2},
        min_size: %{w: 2, h: 1},
        category: "Built-in",
        settings_schema: [
          %{key: "title", type: :string, label: "Title", default: "Note"},
          %{key: "body", type: :text, label: "Body", default: ""}
        ]
      },
      %{
        key: "core.clock",
        name: "Clock",
        description: "Current time — normal, digital or analog, with a per-clock timezone.",
        icon: "hero-clock",
        component: ClockWidget,
        default_size: %{w: 3, h: 2},
        min_size: %{w: 2, h: 1},
        # Ticks live — the host re-renders it every second.
        refresh_interval: 1000,
        # Each view carries its own minimum: the analog face needs a squarer
        # box than a line of digits (the per-view min_size API demo).
        views: [
          %{key: "normal", name: "Normal", min_size: %{w: 2, h: 1}},
          %{key: "digital", name: "Digital", min_size: %{w: 3, h: 1}},
          %{key: "analog", name: "Analog", min_size: %{w: 2, h: 2}}
        ],
        category: "Built-in",
        settings_schema: [
          %{key: "label", type: :string, label: "Label", default: ""},
          %{
            key: "timezone",
            type: :select,
            label: "Timezone",
            options: ClockWidget.timezone_options(),
            default: "UTC"
          },
          %{key: "show_timezone", type: :boolean, label: "Show timezone", default: true},
          %{
            key: "format",
            type: :select,
            label: "Time format",
            options: ["24h", "12h"],
            default: "24h"
          }
        ]
      },
      %{
        key: "core.module_stats",
        name: "Module stats",
        description: "Show the config/stats map any PhoenixKit module exposes via get_config/0.",
        icon: "hero-chart-bar",
        component: ModuleStatsWidget,
        default_size: %{w: 4, h: 2},
        min_size: %{w: 2, h: 1},
        # Two render variants — the widget also collapses to the compact layout
        # automatically when the instance is sized too small for the table.
        views: [
          %{key: "detailed", name: "Detailed (table)"},
          %{key: "compact", name: "Compact (counts)"}
        ],
        category: "Built-in",
        settings_schema: [
          %{key: "module_key", type: :string, label: "Module key", default: ""}
        ]
      }
    ]
  end
end
