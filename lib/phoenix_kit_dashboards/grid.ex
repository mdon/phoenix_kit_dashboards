defmodule PhoenixKitDashboards.Grid do
  @moduledoc """
  Pure cell-placement math for **grid** dashboards.

  A grid widget occupies an explicit rectangle of cells — `x` (column, 0-based),
  `y` (row, 0-based), spanning `w`×`h` — on a breakpoint's column grid. Widgets
  can sit anywhere (gaps are allowed, that's the point of the grid type) but
  never overlap; these helpers are the single source of truth for what fits
  where, shared by every placement mutation and by the render-time resolution
  of layouts that predate explicit coordinates:

    * `collides?/5` — would a rectangle overlap any placed widget?
    * `first_free/4` — the first free rectangle in reading order (row-major).
    * `compact/2` — pack a list of spans into explicit cells in list order
      (legacy/derived layouts: "reflow + compact").
    * `fit_size/7` — clamp a requested resize so it grows until blocked by a
      neighbour or the grid edge, never onto another widget.

  Everything is integer cell math on plain string-keyed placement maps
  (`%{"x" => _, "y" => _, "w" => _, "h" => _}`) — no DOM, no DB.
  """

  # The HARD row bound: placement scans and derived-tier packing never go past
  # it, and hostile coordinates clamp to it. The per-TIER designable surface
  # (what the builder renders and lets you place on manually) is smaller —
  # `Breakpoints.max_rows/1` (TV 8 … phone 36); derived packing may overflow a
  # tier's surface into this headroom when denser content reflows into fewer
  # columns.
  @max_rows 50

  @doc "The maximum row index + span extent a placement may reach."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc """
  Whether a `w`×`h` rectangle at `(x, y)` overlaps any of the `others` (their
  placement maps; entries without both `x` and `y` are ignored — they have no
  cells yet).
  """
  @spec collides?(integer(), integer(), pos_integer(), pos_integer(), [map()]) :: boolean()
  def collides?(x, y, w, h, others) do
    Enum.any?(others, fn p ->
      case {p["x"], p["y"]} do
        {ox, oy} when is_integer(ox) and is_integer(oy) ->
          ow = p["w"] || 1
          oh = p["h"] || 1
          x < ox + ow and ox < x + w and y < oy + oh and oy < y + h

        _ ->
          false
      end
    end)
  end

  @doc """
  The first `{x, y}` (reading order: row by row, left to right) where a `w`×`h`
  rectangle fits without overlapping `others`. Spans wider than the grid are
  handled by the caller (clamp first); `nil` only if the grid is packed solid
  through `max_rows/0` (practically unreachable).
  """
  @spec first_free([map()], pos_integer(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def first_free(others, w, h, cols) do
    w = min(w, cols)
    Enum.find_value(0..(@max_rows - h), &free_x_in_row(&1, others, w, h, cols))
  end

  defp free_x_in_row(y, others, w, h, cols) do
    Enum.find_value(0..(cols - w), fn x ->
      if collides?(x, y, w, h, others), do: nil, else: {x, y}
    end)
  end

  @doc """
  The first row below every placed widget — the non-overlapping fallback spot
  when a packing scan comes up empty (a grid solid through `max_rows/0`).
  """
  @spec below_all([map()]) :: non_neg_integer()
  def below_all(others) do
    others
    |> Enum.map(fn p ->
      case p["y"] do
        y when is_integer(y) -> y + (p["h"] || 1)
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Pack `placements` (their `w`/`h` spans, in list order) into explicit cells on
  a `cols`-wide grid: each gets the first free rectangle in reading order, spans
  clamped to the column count. Returns the placements with `"x"`/`"y"` set.

  This is the "reflow + compact" primitive: it materializes legacy order-only
  layouts and derives un-customized breakpoints from a designed tier (sorted to
  reading order first by the caller).
  """
  @spec compact([map()], pos_integer()) :: [map()]
  def compact(placements, cols) do
    {packed, _occupied} =
      Enum.map_reduce(placements, [], fn p, occupied ->
        w = min(max(p["w"] || 1, 1), cols)
        h = max(p["h"] || 1, 1)

        {x, y} = first_free(occupied, w, h, cols) || {0, below_all(occupied)}
        placed = p |> Map.put("x", x) |> Map.put("y", y) |> Map.put("w", w)
        {placed, [placed | occupied]}
      end)

    packed
  end

  @doc """
  Clamp a requested `req_w`×`req_h` resize of the widget anchored at `(x, y)` so
  it stays within the grid and **grows until blocked** — the nearest neighbour
  (any of `others`) or the grid edge stops it, instead of overlapping or
  rejecting the whole resize. Width is fitted first (at the current height
  `orig_h`), then height at the fitted width; the result never collides because
  the original placement doesn't.

  `bounds` are the widget type's `{min, max}` size maps.
  """
  @spec fit_size(
          integer(),
          integer(),
          integer(),
          integer(),
          pos_integer(),
          [map()],
          pos_integer(),
          {%{w: pos_integer(), h: pos_integer()}, %{w: pos_integer(), h: pos_integer()}}
        ) :: {pos_integer(), pos_integer()}
  def fit_size(x, y, req_w, req_h, orig_h, others, cols, {min_size, max_size}) do
    min_w = min(min_size.w, cols)
    req_w = req_w |> max(min_w) |> min(min(max_size.w, cols - x))
    req_h = req_h |> max(min_size.h) |> min(min(max_size.h, @max_rows - y))

    probe_h = min(orig_h, req_h)
    w = largest_fitting(req_w, min_w, fn w -> not collides?(x, y, w, probe_h, others) end)
    h = largest_fitting(req_h, min_size.h, fn h -> not collides?(x, y, w, h, others) end)
    {w, h}
  end

  defp largest_fitting(from, floor, fits?) do
    Enum.find(from..floor//-1, floor, fits?)
  end
end
