defmodule PhoenixKitDashboards.Sizing do
  @moduledoc """
  The single source of truth for a widget **instance's** resize bounds.

  The context (placement clamps) and the builder LiveView (the limits fed to the
  `DashboardResize` hook as `data-*`) MUST agree, or the client snaps to a span
  the server then rejects. This module is that shared rule — replacing the two
  verbatim `size_bounds`/`instance_min` copies that previously lived in
  `Dashboards` and `Web.BuilderLive` and drifted independently.
  """

  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Widget

  @doc """
  Min/max span `{min_size, max_size}` for an instance on a layout.

  The min comes from the instance's selected view when that view declares one
  (`Widget.min_size_for/2`; an analog clock has a squarer floor than a text
  one). The per-instance `min_override` drops the floor to 1×1 — minimums are
  RECOMMENDATIONS (content renders degraded below them) and a user cramming a
  dense dashboard may opt out. Falls back to a permissive range when the type is
  unknown (a stale instance whose provider was uninstalled).
  """
  @spec bounds(map(), String.t()) :: {Widget.size(), Widget.size()}
  def bounds(item, layout_id) do
    case Registry.get(item["widget_key"]) do
      %Widget{} = widget -> {instance_min(item, layout_id, widget), widget.max_size}
      _ -> {%{w: 1, h: 1}, %{w: Lattice.max_dim(), h: Lattice.max_dim()}}
    end
  end

  defp instance_min(%{"min_override" => true}, _layout_id, _widget), do: %{w: 1, h: 1}

  defp instance_min(item, layout_id, widget),
    do: Widget.min_size_for(widget, Layout.view(item, layout_id))
end
