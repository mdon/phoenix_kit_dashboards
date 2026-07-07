defmodule PhoenixKitDashboards.Layout do
  @moduledoc """
  Read/write a widget instance's geometry in the **embedded** item shape:

      %{
        "id" => "…", "widget_key" => "…", "settings" => %{…}, "view" => "…",
        "pixel" => %{"fx" => .., "fy" => .., "fw" => .., "fh" => ..},   # pixel canvas
        "bp"    => %{"desktop" => %{"w" => .., "h" => .., "hidden" => ..}}  # grid, per breakpoint
      }

  Pixel dashboards use `pixel`; grid dashboards use `bp[<breakpoint>]` (flow order
  = list position). Keeping geometry *embedded per widget* means add/remove is
  atomic — no separate placement map to keep in sync.

  Accessors default missing values and fall back to the **legacy flat shape**
  (`"fx"/"w"/"h"…` directly on the item) so pre-refactor local dashboards keep
  rendering; a `put_*` write upgrades that widget to the nested shape.
  """

  @pixel_defaults %{"fx" => 0, "fy" => 0, "fw" => 480, "fh" => 280}
  @grid_defaults %{"w" => 4, "h" => 2, "hidden" => false}

  @doc "The widget's pixel-canvas geometry (`fx/fy/fw/fh`), defaulted."
  @spec pixel(map()) :: %{optional(String.t()) => term()}
  def pixel(item) when is_map(item) do
    stored = Map.get(item, "pixel") || take(item, ~w(fx fy fw fh))
    Map.merge(@pixel_defaults, stored)
  end

  @doc "Set pixel geometry (string-keyed attrs), upgrading the item to nested shape."
  @spec put_pixel(map(), map()) :: map()
  def put_pixel(item, attrs) when is_map(attrs) do
    Map.put(item, "pixel", Map.merge(pixel(item), stringify(attrs)))
  end

  @doc "The widget's grid placement (`w/h/hidden`) for a breakpoint, defaulted."
  @spec placement(map(), String.t()) :: %{optional(String.t()) => term()}
  def placement(item, bp) when is_map(item) and is_binary(bp) do
    stored = get_in(item, ["bp", bp]) || take(item, ~w(w h hidden))
    Map.merge(@grid_defaults, stored)
  end

  @doc "Set a breakpoint's grid placement, upgrading the item to nested shape."
  @spec put_placement(map(), String.t(), map()) :: map()
  def put_placement(item, bp, attrs) when is_binary(bp) and is_map(attrs) do
    bpmap = Map.get(item, "bp", %{})
    Map.put(item, "bp", Map.put(bpmap, bp, Map.merge(placement(item, bp), stringify(attrs))))
  end

  @doc "Whether the widget is hidden on a breakpoint."
  @spec hidden?(map(), String.t()) :: boolean()
  def hidden?(item, bp), do: placement(item, bp)["hidden"] == true

  # Pick the given string keys that exist with a value, as a string-keyed map.
  defp take(item, keys) do
    for k <- keys, v = Map.get(item, k), into: %{}, do: {k, v}
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
