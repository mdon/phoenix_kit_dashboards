defmodule PhoenixKitDashboards.Widgets do
  @moduledoc """
  The built-in widget catalog shipped with this module.

  These give a dashboard immediate value even on a host with zero widget
  providers installed. Each entry follows the same plain-map contract that
  external providers use (see `PhoenixKitDashboards.Widget`), so the built-ins
  are also a worked reference for module authors.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitDashboards.Widgets.ClockWidget
  alias PhoenixKitDashboards.Widgets.ModuleStatsWidget
  alias PhoenixKitDashboards.Widgets.NoteWidget

  # Catalog strings are DATA (the provider contract passes plain maps), so they
  # are translated dynamically at render (`Web.Helpers.translate_catalog/1`).
  # The extractor only sees literals — this anchor keeps the built-ins' strings
  # in the POT files. (Provider modules own their catalog strings the same way.)
  @doc false
  def __catalog_strings__ do
    [
      gettext_noop("Note"),
      gettext_noop("A free-text note for reminders, links, or context — Markdown supported."),
      gettext_noop("Title"),
      gettext_noop("Body"),
      gettext_noop("Clock"),
      gettext_noop("Current time — normal, digital or analog, with a per-clock timezone."),
      gettext_noop("Normal"),
      gettext_noop("Digital"),
      gettext_noop("Analog"),
      gettext_noop("Label"),
      gettext_noop("Timezone"),
      gettext_noop("Show timezone"),
      gettext_noop("Time format"),
      gettext_noop("Module stats"),
      gettext_noop("Show the config/stats map any PhoenixKit module exposes via get_config/0."),
      gettext_noop("Detailed (table)"),
      gettext_noop("Compact (counts)"),
      gettext_noop("Module"),
      gettext_noop("Items")
    ]
  end

  @doc "List of built-in widget definitions (plain maps)."
  @spec builtin() :: [map()]
  def builtin do
    [
      %{
        key: "core.note",
        name: "Note",
        description: "A free-text note for reminders, links, or context — Markdown supported.",
        icon: "hero-pencil-square",
        component: NoteWidget,
        default_size: %{w: 16, h: 8},
        min_size: %{w: 8, h: 4},
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
        default_size: %{w: 12, h: 8},
        min_size: %{w: 8, h: 4},
        # Ticks live — the host re-renders it every second.
        refresh_interval: 1000,
        # Each view carries its own minimum: the analog face needs a squarer
        # box than a line of digits (the per-view min_size API demo).
        views: [
          %{key: "normal", name: "Normal", min_size: %{w: 8, h: 4}},
          %{key: "digital", name: "Digital", min_size: %{w: 12, h: 4}},
          %{key: "analog", name: "Analog", min_size: %{w: 8, h: 8}}
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
        default_size: %{w: 16, h: 8},
        min_size: %{w: 8, h: 4},
        # No refresh_interval by design: a module's get_config/0 stats change
        # slowly (installed-module counts, config), so this widget is static —
        # reopen the dashboard to re-read. Only the clock declares a refresh.
        # Two render variants — the widget also collapses to the compact layout
        # automatically when the instance is sized too small for the table.
        views: [
          %{key: "detailed", name: "Detailed (table)"},
          %{key: "compact", name: "Compact (counts)"}
        ],
        category: "Built-in",
        settings_schema: [
          %{
            key: "module_key",
            type: :select,
            label: "Module",
            options: ModuleStatsWidget.module_options(),
            default: ""
          },
          # The N-slot row budget for the detailed view: the box divides into
          # this many rows; type scales to the slot. Nothing ever scrolls.
          %{key: "items", type: :number, label: "Items", default: 6}
        ]
      }
    ]
  end
end
