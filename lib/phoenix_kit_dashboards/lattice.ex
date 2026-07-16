defmodule PhoenixKitDashboards.Lattice do
  @moduledoc """
  The grid design space: a GAPLESS lattice of nominal **25px square cells**.

  A layout's `cols × rows` is **exactly one screenful** of STANDARD cells —
  nothing ever scrolls. The fit hook stretches per-axis only to absorb the
  last ~10% (a fitted screen fills exactly edge-to-edge); otherwise the
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
end
