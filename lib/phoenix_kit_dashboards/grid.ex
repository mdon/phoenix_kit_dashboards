defmodule PhoenixKitDashboards.Grid do
  @moduledoc """
  Pure cell-placement math for **grid** dashboards.

  A grid widget occupies an explicit rectangle of cells — `x` (column, 0-based),
  `y` (row, 0-based), spanning `w`×`h` — on a layout's lattice. Widgets
  can sit anywhere (gaps are allowed, that's the point of the grid type) but
  never overlap; these helpers are the single source of truth for what fits
  where, shared by every placement mutation and by the render-time resolution
  of layouts that predate explicit coordinates:

    * `collides?/5` — would a rectangle overlap any placed widget?
    * `first_free/4` — the first free rectangle in reading order (row-major).
    * `compact/2` — pack a list of spans into explicit cells in list order
      (legacy/derived layouts: "reflow + compact").
    * `fit_size/8` — clamp a requested resize so it grows until blocked by a
      neighbour or the grid edge, never onto another widget.

  Everything is integer cell math on plain string-keyed placement maps
  (`%{"x" => _, "y" => _, "w" => _, "h" => _}`) — no DOM, no DB. Stored `w`/`h`
  are coerced through `Lattice.to_int/2` before arithmetic, so a tampered/legacy
  JSONB span carrying a string or float can't raise `ArithmeticError`.
  """

  alias PhoenixKitDashboards.Lattice

  # The HARD row bound: placement scans never go past it and hostile
  # coordinates clamp to it. Matches the lattice dimension cap (a layout's
  # rows are 4..160).
  @max_rows 160

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
          # Floor to 1 like rendering / compact — a stored "0"/negative span
          # renders one cell wide, so collision must see at least one cell too
          # (else a zero-width span lets another widget pack into the same cell).
          ow = max(Lattice.to_int(p["w"], 1), 1)
          oh = max(Lattice.to_int(p["h"], 1), 1)
          x < ox + ow and ox < x + w and y < oy + oh and oy < y + h

        _ ->
          false
      end
    end)
  end

  @doc """
  The first `{x, y}` (reading order: row by row, left to right) where a `w`×`h`
  rectangle fits without overlapping `others`. Spans wider than the grid are
  handled by the caller (clamp first); `nil` if the grid is packed solid
  through `rows` (the caller's `below_all/1` fallback then stacks below the
  screenful — expected on a small/full layout, not "practically unreachable").
  `rows` defaults to `max_rows/0` for callers with no row bound of their own.
  """
  @spec first_free([map()], pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def first_free(others, w, h, cols, rows \\ @max_rows) do
    w = min(w, cols)
    max_y = min(rows, @max_rows) - h
    if max_y < 0, do: nil, else: Enum.find_value(0..max_y, &free_x_in_row(&1, others, w, h, cols))
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
        y when is_integer(y) -> y + max(Lattice.to_int(p["h"], 1), 1)
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  The cell `{x, y}` to drop a `w`×`h` rectangle onto `occupied`: the first free
  slot in reading order, or — when the grid is packed solid through `rows` —
  stacked directly below every placed widget (`below_all/1`). The single
  placement primitive behind `pack/4`, new-widget seeding, and render-time
  resolution (each previously re-spelled `first_free/5 || {0, below_all/1}`).
  """
  @spec slot([map()], pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def slot(occupied, w, h, cols, rows) do
    first_free(occupied, w, h, cols, rows) || {0, below_all(occupied)}
  end

  @doc """
  Pack `placements` (their `w`/`h` spans, in list order) into explicit cells,
  each dropped at its `slot/5` **onto `occupied`** — the already-placed
  rectangles the packing must flow around (pass `[]` for a fresh grid). Spans
  are coerced through `Lattice.to_int/2` and clamped into the `cols`×`rows`
  screenful; the returned placements carry integer `"x"`/`"y"`/`"w"`/`"h"`.

  This is the seeded primitive behind `compact/3` (a fresh pack) and the
  render-time resolution of layouts that mix stored and order-only placements.
  """
  @spec pack([map()], [map()], pos_integer(), pos_integer()) :: [map()]
  def pack(placements, occupied, cols, rows) do
    {packed, _occupied} =
      Enum.map_reduce(placements, occupied, fn p, occ ->
        w = min(max(Lattice.to_int(p["w"], 1), 1), cols)
        h = min(max(Lattice.to_int(p["h"], 1), 1), rows)
        {x, y} = slot(occ, w, h, cols, rows)
        placed = Map.merge(p, %{"x" => x, "y" => y, "w" => w, "h" => h})
        {placed, [placed | occ]}
      end)

    packed
  end

  @doc """
  Pack `placements` (their `w`/`h` spans, in list order) into explicit cells on
  a `cols`-wide grid: each gets the first free rectangle in reading order, spans
  clamped to the `cols`×`rows` screenful. Returns the placements with integer
  `"x"`/`"y"`/`"w"`/`"h"` set. `rows` defaults to `max_rows/0`; pass the layout's
  real row count so a full screenful falls back to `below_all/1` instead of
  packing past the visible bottom edge.

  This is the "reflow + compact" primitive behind widget reorder (sorted to
  reading order first by the caller) — a `pack/4` onto an empty grid.
  """
  @spec compact([map()], pos_integer(), pos_integer()) :: [map()]
  def compact(placements, cols, rows \\ @max_rows), do: pack(placements, [], cols, rows)

  @doc """
  Clamp a requested `req_w`×`req_h` resize of the widget anchored at `(x, y)` so
  it stays within the grid and **grows until blocked** — the nearest neighbour
  (any of `others`) or the grid edge stops it, instead of overlapping or
  rejecting the whole resize. Width is fitted first (at the current height
  `orig_h`), then height at the fitted width; the result never collides because
  the original placement doesn't.

  `bounds` are the widget type's `{min, max}` size maps; `rows` is the
  layout's own row count — a widget can never resize past the screenful's
  bottom edge.
  """
  @spec fit_size(
          integer(),
          integer(),
          integer(),
          integer(),
          pos_integer(),
          [map()],
          {pos_integer(), pos_integer()},
          {%{w: pos_integer(), h: pos_integer()}, %{w: pos_integer(), h: pos_integer()}}
        ) :: {pos_integer(), pos_integer()}
  def fit_size(x, y, req_w, req_h, orig_h, others, {cols, rows}, {min_size, max_size}) do
    # The grid edge caps even the type minimum: a widget parked against the
    # edge (min_override) must never grow past the screenful, so the fitting
    # floor is the available space when that's smaller than the min.
    floor_w = min(min(min_size.w, cols), max(cols - x, 1))
    floor_h = min(min_size.h, max(rows - y, 1))
    req_w = req_w |> max(floor_w) |> min(min(max_size.w, cols - x))
    req_h = req_h |> max(floor_h) |> min(min(max_size.h, rows - y))

    probe_h = min(orig_h, req_h)
    w = largest_fitting(req_w, floor_w, fn w -> not collides?(x, y, w, probe_h, others) end)
    h = largest_fitting(req_h, floor_h, fn h -> not collides?(x, y, w, h, others) end)
    {w, h}
  end

  defp largest_fitting(from, floor, fits?) do
    Enum.find(from..floor//-1, floor, fits?)
  end
end
