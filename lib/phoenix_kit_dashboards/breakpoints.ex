defmodule PhoenixKitDashboards.Breakpoints do
  @moduledoc """
  Design-space constants + the LEGACY device-tier table.

  Grid dashboards are composed of **user-defined layouts** (see
  `PhoenixKitDashboards.Dashboards.layouts/1`) — the old fixed device tiers
  (TV/Desktop/iPad/Phone) are gone. This module keeps:

    * the **design-space constants**: a constant SQUARE cell (89×89px + 12px
      gap) every layout is designed at, and the canvas width derived from a
      column count (`design_width/1`). Widgets are designed against this
      density; the builder's fit hook rescales the whole canvas to the pane,
      so widget contents shrink/grow uniformly and always keep fitting.
    * the **legacy tier table**, used ONLY to adapt pre-layouts dashboards:
      a designed tier becomes a named layout whose id IS the old tier key
      (`"desktop"`, `"phone"`, …), so per-widget geometry needs no rewriting.
  """

  # Legacy device tiers (migration only — see moduledoc).
  @breakpoints [
    %{key: "tv", label: "TV", cols: 16, max_rows: 8},
    %{key: "desktop", label: "Desktop", cols: 12, max_rows: 15},
    %{key: "ipad", label: "iPad", cols: 8, max_rows: 24},
    %{key: "phone", label: "Phone", cols: 4, max_rows: 36}
  ]

  # The design-space cell: every grid lays out at this cell size regardless of
  # column count (12 cols -> the classic 1200px-wide canvas). Cells are SQUARE
  # (89x89; the builder grid's auto-rows matches this width) with 12px gaps
  # (gap-3).
  @design_cell_w 89
  @design_gap 12

  # Hard upper bound for per-layout column counts (and widget spans).
  @max_grid_cols 24

  @type t :: %{
          key: String.t(),
          label: String.t(),
          cols: pos_integer(),
          max_rows: pos_integer()
        }

  @doc "The legacy tiers, largest → smallest (migration only)."
  @spec all() :: [t()]
  def all, do: @breakpoints

  @doc "A legacy tier by key, or nil (migration only)."
  @spec get(String.t()) :: t() | nil
  def get(key), do: Enum.find(@breakpoints, &(&1.key == key))

  @doc """
  The design-space canvas width for a column count — constant cell size, so the
  widget contract's density never changes; the fit-scaler handles the screen.
  """
  @spec design_width(pos_integer()) :: pos_integer()
  def design_width(cols) when is_integer(cols) and cols > 0 do
    cols * (@design_cell_w + @design_gap) - @design_gap
  end

  @doc "Hard upper bound for per-layout column counts and widget spans."
  @spec max_grid_cols() :: pos_integer()
  def max_grid_cols, do: @max_grid_cols
end
