defmodule PhoenixKitDashboards.Breakpoints do
  @moduledoc """
  The responsive **grid** breakpoint tiers, with a per-device column count.

  A grid dashboard stores a placement (`x/y/w/h/hidden`) per breakpoint; smaller
  tiers have fewer columns, so a layout designed for a big screen reflows down.
  Tiers are ordered **largest → smallest**; the widths are the minimum viewport
  width that selects each tier (checked top-down, so `phone` is the `< 768`
  catch-all with `min_width: 0`).

  Pixel dashboards do not use breakpoints (a single scaled canvas).
  """

  @breakpoints [
    # max_rows = the tier's designable surface (fully rendered + scrollable in
    # the builder): a TV never scrolls, so it gets barely more than one screen;
    # a phone feed runs long. Derived tiers may still overflow it (packing
    # denser content into fewer columns) — that renders fine, the cap only
    # bounds MANUAL placement and the scroll surface.
    #
    # There is NO per-tier design width: a tier is just its column count. The
    # canvas width derives from it (`design_width/1`) at a CONSTANT cell size,
    # so widget contents always render at the density the widget contract was
    # designed for and the fit-scaler shrinks everything uniformly.
    %{key: "tv", label: "TV", min_width: 1920, cols: 16, max_rows: 8},
    %{key: "desktop", label: "Desktop", min_width: 1280, cols: 12, max_rows: 15},
    %{key: "ipad", label: "iPad", min_width: 768, cols: 8, max_rows: 24},
    %{key: "phone", label: "Phone", min_width: 0, cols: 4, max_rows: 36}
  ]

  # The design-space cell: every grid lays out at this cell width regardless of
  # column count (12 cols -> the classic 1200px desktop canvas). The gap must
  # match the builder grid's gap-3 (0.75rem = 12px); row height is the grid's
  # auto-rows 8rem. Widgets are designed against THIS density — more columns
  # widen the canvas and the fit hook scales the whole thing down, shrinking
  # widget contents uniformly so they always keep fitting.
  @design_cell_w 89
  @design_gap 12

  # Hard upper bound for per-dashboard column overrides (and widget spans).
  @max_grid_cols 24

  @default_key "desktop"

  @type t :: %{
          key: String.t(),
          label: String.t(),
          min_width: non_neg_integer(),
          cols: pos_integer(),
          max_rows: pos_integer()
        }

  @doc "All breakpoint tiers, ordered largest → smallest."
  @spec all() :: [t()]
  def all, do: @breakpoints

  @doc "The breakpoint keys, ordered largest → smallest."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@breakpoints, & &1.key)

  @doc "The default (seed + last-resort derivation-fallback) breakpoint."
  @spec default() :: String.t()
  def default, do: @default_key

  @doc "The tier for a key, or nil."
  @spec get(String.t()) :: t() | nil
  def get(key), do: Enum.find(@breakpoints, &(&1.key == key))

  @doc """
  The tier that best fits a viewport `width` in CSS px — the largest whose
  `min_width` it clears (phone is the catch-all). The server-side twin of the
  DashboardBreakpoint hook's matching, for hosts that pass the viewport in the
  LiveSocket connect params.
  """
  @spec for_width(number()) :: String.t()
  def for_width(width) when is_number(width) do
    Enum.find(@breakpoints, List.last(@breakpoints), &(width >= &1.min_width)).key
  end

  @doc "The tier's designable rows (the builder renders + scrolls all of them)."
  @spec max_rows(String.t()) :: pos_integer()
  def max_rows(key) do
    case get(key) do
      %{max_rows: rows} -> rows
      _ -> 15
    end
  end

  @doc "The column count for a breakpoint key (12 if unknown)."
  @spec cols(String.t()) :: pos_integer()
  def cols(key) do
    case get(key) do
      %{cols: cols} -> cols
      _ -> 12
    end
  end

  @doc """
  The design-space canvas width for a column count — constant cell size, so the
  widget contract's density never changes; the fit-scaler handles the screen.
  """
  @spec design_width(pos_integer()) :: pos_integer()
  def design_width(cols) when is_integer(cols) and cols > 0 do
    cols * (@design_cell_w + @design_gap) - @design_gap
  end

  @doc "Hard upper bound for per-dashboard column counts and widget spans."
  @spec max_grid_cols() :: pos_integer()
  def max_grid_cols, do: @max_grid_cols

  @doc "Whether a string is a known breakpoint key."
  @spec valid?(term()) :: boolean()
  def valid?(key), do: is_binary(key) and key in keys()

  @doc """
  The keys strictly LARGER than `key`, **nearest-first** — the auto-derive source
  chain (a fresh tier inherits from the closest larger customized tier). Keys are
  ordered largest→smallest, so the slice before `key` is farthest-first; reverse it.
  """
  @spec larger_than(String.t()) :: [String.t()]
  def larger_than(key) do
    keys() |> Enum.take_while(&(&1 != key)) |> Enum.reverse()
  end

  @doc "The keys strictly SMALLER than `key`, nearest-first (the fallback chain)."
  @spec smaller_than(String.t()) :: [String.t()]
  def smaller_than(key) do
    keys() |> Enum.drop_while(&(&1 != key)) |> Enum.drop(1)
  end
end
