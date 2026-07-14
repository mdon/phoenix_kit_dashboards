defmodule PhoenixKitDashboards.Lattice do
  @moduledoc """
  The grid design space: a GAPLESS lattice of nominal **25px square cells**.

  A layout's `cols × rows` is **exactly one screenful** — the canvas scales to
  the viewing pane (per-axis stretch when the shapes roughly match, letterboxed
  artboard beyond that), so nothing ever scrolls. Widget cards carry a small
  internal margin instead of grid gaps, and content self-fits via
  container-query type scaling. All widget sizes (min/default/max, per-view
  minimums) are declared in lattice units.
  """

  @cell 25

  # Hard bounds for per-layout lattice dimensions (and widget spans).
  # 160 cols × 25px = 4000px design width — beyond 4K.
  @max_dim 160
  @min_dim 4

  # Stretch tolerance: the canvas fills the pane with independent per-axis
  # scales when they differ by no more than this ratio (cells go imperceptibly
  # non-square and the screen is filled edge-to-edge, no orphan strip). Beyond
  # it, uniform scale + letterbox (an intact artboard, never distortion).
  @stretch_tolerance 1.10

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
