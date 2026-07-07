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

  # `preview_width` is the width the builder previews the tier at (a device frame),
  # so a phone layout is edited at phone width rather than stretched to the monitor.
  @breakpoints [
    %{key: "tv", label: "TV", min_width: 1920, cols: 16, preview_width: 1600},
    %{key: "desktop", label: "Desktop", min_width: 1280, cols: 12, preview_width: 1200},
    %{key: "ipad", label: "iPad", min_width: 768, cols: 8, preview_width: 820},
    %{key: "phone", label: "Phone", min_width: 0, cols: 4, preview_width: 390}
  ]

  @default_key "desktop"

  @type t :: %{
          key: String.t(),
          label: String.t(),
          min_width: non_neg_integer(),
          cols: pos_integer(),
          preview_width: pos_integer()
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

  @doc "The column count for a breakpoint key (12 if unknown)."
  @spec cols(String.t()) :: pos_integer()
  def cols(key) do
    case get(key) do
      %{cols: cols} -> cols
      _ -> 12
    end
  end

  @max_cols @breakpoints |> Enum.map(& &1.cols) |> Enum.max()

  @doc """
  The largest tier's column count — the widest any widget span can be. Size
  bounds are sanitized against this (not a hardcoded 12) so a widget can span a
  full TV row; each breakpoint still clamps spans to its own `cols/1` at
  placement time.
  """
  @spec max_cols() :: pos_integer()
  def max_cols, do: @max_cols

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
