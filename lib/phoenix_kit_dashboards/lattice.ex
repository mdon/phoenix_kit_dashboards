defmodule PhoenixKitDashboards.Lattice do
  @moduledoc """
  The grid design space: a GAPLESS lattice of nominal **25px square cells**.

  A layout's `cols × rows` is **exactly one screenful** of STANDARD cells —
  nothing ever scrolls. The fit hook stretches per-axis only to absorb the
  last ~4% (a fitted screen fills exactly edge-to-edge); otherwise the
  intact artboard shrinks into a smaller pane, or floats centered at natural
  size in a bigger one — never blown up (a bigger display wants its own
  fitted layout). Widget cards carry a small internal margin instead of grid
  gaps, and content self-fits via container-query type scaling. All widget
  sizes (default, min, per-view minimums) are declared in lattice units.
  """

  @cell 25

  # Hard bounds for per-layout lattice dimensions (and widget spans).
  # 160 cols × 25px = 4000px design width — beyond 4K.
  @max_dim 160
  @min_dim 4

  # Stretch tolerance: the canvas fills the pane with independent per-axis
  # scales when both stay within this ratio of 1 and of each other (cells go
  # imperceptibly non-square, no orphan strip). Tight on purpose — it only
  # absorbs Fit-screen rounding (±half a cell), and anything past ~4%
  # visibly distorts the board's shape (a Square layout must LOOK square).
  # Beyond it: shrink-to-fit or float-at-natural-size — never blown up.
  @stretch_tolerance 1.04

  @doc "The nominal square cell size in design px."
  @spec cell() :: pos_integer()
  def cell, do: @cell

  @doc "Design-space canvas width for a column count."
  @spec design_width(pos_integer()) :: pos_integer()
  def design_width(cols) when is_integer(cols) and cols > 0, do: cols * @cell

  @doc "Design-space canvas height for a row count."
  @spec design_height(pos_integer()) :: pos_integer()
  def design_height(rows) when is_integer(rows) and rows > 0, do: rows * @cell

  @doc "Hard upper bound for layout dimensions and widget spans."
  @spec max_dim() :: pos_integer()
  def max_dim, do: @max_dim

  @doc "Hard lower bound for layout dimensions."
  @spec min_dim() :: pos_integer()
  def min_dim, do: @min_dim

  @doc "Per-axis stretch tolerance (see moduledoc)."
  @spec stretch_tolerance() :: float()
  def stretch_tolerance, do: @stretch_tolerance

  # Free/pixel-canvas widget bounds (px). A pixel dashboard is an absolute-px
  # canvas rather than a lattice, but its bounds live here as the one home for
  # every geometry constant.
  @free_min_px 60
  @free_max_px 4000
  @free_max_pos 20_000

  @doc "Minimum free/pixel-canvas widget size in px."
  @spec free_min_px() :: pos_integer()
  def free_min_px, do: @free_min_px

  @doc "Maximum free/pixel-canvas widget size in px (also the per-move growth budget)."
  @spec free_max_px() :: pos_integer()
  def free_max_px, do: @free_max_px

  @doc "Absolute hard cap for a free/pixel-canvas position (px)."
  @spec free_max_pos() :: pos_integer()
  def free_max_pos, do: @free_max_pos

  @doc """
  Coerce a stored geometry value to an integer — the single coercion for
  tampered/legacy JSONB that may carry a string or float where an int is
  expected. Floats truncate; numeric strings parse; anything else falls back to
  `default`.
  """
  @spec to_int(term(), integer()) :: integer()
  def to_int(v, _default) when is_integer(v), do: v
  def to_int(v, _default) when is_float(v), do: trunc(v)

  def to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  def to_int(_v, default), do: default

  @doc """
  Clamp an integer into `[lo, hi]` — the single clamp shared across the module.
  A non-integer value (tampered/legacy JSONB) collapses to `lo` rather than
  raising in downstream cell arithmetic.
  """
  @spec clamp(term(), integer(), integer()) :: integer()
  def clamp(v, lo, hi) when is_integer(v), do: v |> max(lo) |> min(hi)
  def clamp(_v, lo, _hi), do: lo
end
