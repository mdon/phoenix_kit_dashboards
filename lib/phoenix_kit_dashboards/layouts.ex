defmodule PhoenixKitDashboards.Layouts do
  @moduledoc """
  Pure helpers for a grid dashboard's **layout list** — the ordered
  `config["layouts"]` entries (`%{"id","name","cols","rows"}`), each one exactly
  one screenful on the gapless 25px lattice (see `PhoenixKitDashboards.Lattice`).

  Read/derivation only: reading the (normalized, clamped) list, finding an entry
  by id, the first/landing id, and minting the next unused id/name for a new
  layout. This module never touches the Repo — the layout **write** paths
  (`add_layout` / `rename_layout` / `delete_layout` / `set_grid_dims`) stay in
  `PhoenixKitDashboards.Dashboards` alongside the CAS `persist`, which still
  re-exposes `layouts/1`, `get_layout/2`, and `first_layout_id/1` as its public
  API (via `defdelegate`).
  """

  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Schemas.Dashboard

  # Every dashboard starts with this deterministic default (16:9 screenful:
  # 64×36 cells = 1600×900 design px). The literal id matters: the entry is
  # synthesized in memory until the first layout mutation persists the list.
  @default_layout %{"id" => "l1", "name" => "Layout 1", "cols" => 64, "rows" => 36}

  @doc "The baseline single-layout entry a never-persisted dashboard renders on."
  @spec default_layout() :: map()
  def default_layout, do: @default_layout

  @doc """
  The dashboard's grid layouts, ordered. A dashboard that has never persisted
  a layout list gets the default single "Layout 1" (64×36).
  """
  @spec layouts(Dashboard.t()) :: [map()]
  def layouts(%Dashboard{} = dashboard) do
    case dashboard.config do
      %{"layouts" => [_ | _] = entries} ->
        case Enum.filter(entries, &match?(%{"id" => _}, &1)) do
          [] -> [@default_layout]
          valid -> Enum.map(valid, &normalize_entry/1)
        end

      _ ->
        [@default_layout]
    end
  end

  defp normalize_entry(%{"id" => id} = entry) do
    %{
      "id" => to_string(id),
      "name" => to_string(entry["name"] || "Layout"),
      "cols" =>
        Lattice.clamp(
          entry["cols"] || @default_layout["cols"],
          Lattice.min_dim(),
          Lattice.max_dim()
        ),
      "rows" =>
        Lattice.clamp(
          entry["rows"] || @default_layout["rows"],
          Lattice.min_dim(),
          Lattice.max_dim()
        )
    }
  end

  @doc "One layout entry by id, or nil."
  @spec get_layout(Dashboard.t(), String.t()) :: map() | nil
  def get_layout(%Dashboard{} = dashboard, id) when is_binary(id) do
    Enum.find(layouts(dashboard), &(&1["id"] == id))
  end

  @doc "The id of the first (default/landing) layout."
  @spec first_layout_id(Dashboard.t()) :: String.t()
  def first_layout_id(%Dashboard{} = dashboard), do: hd(layouts(dashboard))["id"]

  @doc """
  Mint a layout id not already used by `entries` — a short random id ("l" + 8
  hex chars), regenerated on the (astronomically unlikely) clash.
  """
  @spec new_layout_id([map()]) :: String.t()
  def new_layout_id(entries) do
    id = "l" <> (UUIDv7.generate() |> String.replace("-", "") |> String.slice(-8..-1//1))
    if Enum.any?(entries, &(&1["id"] == id)), do: new_layout_id(entries), else: id
  end

  @doc ~S[The next free "Layout N" name for `entries` (falls back to "Layout ?").]
  @spec next_layout_name([map()]) :: String.t()
  def next_layout_name(entries) do
    taken = MapSet.new(entries, & &1["name"])

    Enum.find_value(1..99, "Layout ?", fn n ->
      name = "Layout #{n}"
      if MapSet.member?(taken, name), do: nil, else: name
    end)
  end
end
