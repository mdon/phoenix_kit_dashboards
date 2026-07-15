defmodule PhoenixKitDashboards.Web.BuilderLive do
  @moduledoc """
  The dashboard builder — a responsive, server-rendered grid of widgets that can
  be added from the catalog, reordered, resized, configured, and removed.

  ## Phoenix-first, server-authoritative

  The grid is plain HEEx + a CSS grid: each widget instance is anchored at its
  placement's `x`/`y` cells (`grid-column/-row: <line> / span <n>`) on the active
  layout's lattice. It renders — and is fully readable — **without any
  JavaScript**. The server owns the canonical layout (the JSONB `layout` list);
  every mutation re-renders normally (no `phx-update="ignore"`), so
  adding/removing/moving/resizing a widget is live.

  There are two render modes, derived from the dashboard's **type** (fixed at
  creation — `config["type"]` = `"grid"` | `"pixel"`) via `Dashboard.layout_mode/1`
  (legacy `config["mode"]` still maps):

  - **grid** — explicit cell placement on a responsive column grid: each widget
    is anchored at `x`/`y` cells and spans `w`×`h` — place it ANYWHERE (gaps are
    fine), widgets never overlap. Drag by the grip (`DashboardGridDrag`, cell-
    snapped live preview), resize by the corner (snaps + grows until blocked).
  - **free** — an absolute **pixel canvas**: drag and resize anywhere, exact px,
    no snapping. Widgets may overlap — deliberately, via the per-widget
    bring-to-front / send-to-back controls (a `z` key in the `pixel` map).
    Uses separate `fx/fy/fw/fh` px keys so the two layouts never disturb each
    other. The `DashboardFreeFit` hook scales the whole canvas to **fill the
    available width** (fit-to-width, so the exact layout is preserved on any
    screen — it just shrinks on a phone); vertical overflow scrolls.

  Widgets with a `refresh_interval` are re-queried by a host-driven `:refresh_tick`
  loop.

  Custom hooks (shipped via `js_sources/0`): `DashboardGridDrag` (grid cell
  placement — the widget follows the drag cell-by-cell, never onto an occupied
  spot), `DashboardCatalogDrag` (drag a widget type OUT of the catalog and drop
  it on a grid cell or canvas point; a plain click still adds at the first free
  spot), `DashboardFreeDrag` (free-canvas move via `left/top`) and
  `DashboardResize` (corner grip `.pk-resize-handle` — px in free mode; cell-snap
  clamped by neighbours in grid). The non-hook fallback is the Settings modal's
  inputs (px size + X/Y position in free; cell size + Column/Row position in
  grid), all server-driven. Every layout-tweak handler is
  guarded so a hostile/malformed event can't crash or brick the builder.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [
      actor_uuid: 1,
      actor_opts: 1,
      user_role_uuids: 1,
      scope_label: 1,
      translate_catalog: 1
    ]

  alias Phoenix.LiveView.JS
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  # How often the host checks whether any live widget is due for a refresh.
  @refresh_tick_ms 1000

  # Pixel-canvas widget size bounds (mirror the context's px clamps).
  @free_min_px 60
  @free_max_px 4000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:catalog, Registry.list_for_scope(socket.assigns[:phoenix_kit_current_scope]))
     |> assign(:settings_instance, nil)
     # The layout being viewed/edited — resolved in handle_params (first layout,
     # or the ?layout= deep link). No detection, no loading state: a dashboard
     # opens instantly on a designed layout.
     |> assign(:active_layout, nil)
     # The layout id currently in inline-rename mode (nil = none).
     |> assign(:renaming_layout, nil)
     |> assign(:refresh_at, %{})
     # QoL: show the empty grid cells while designing (session-local toggle).
     |> assign(:show_grid_lines, false)
     |> assign(:refresh_scheduled?, false)}
  end

  @impl true
  def handle_params(%{"uuid" => uuid} = params, _uri, socket) do
    case Dashboards.get(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard not found."))
         |> push_navigate(to: Paths.index())}

      dashboard ->
        if can_view?(dashboard, socket) do
          {:noreply,
           socket
           |> assign(:dashboard, dashboard)
           |> assign(:page_title, dashboard.title)
           |> resolve_active_layout(params["layout"])
           |> maybe_schedule_refresh()}
        else
          {:noreply,
           socket
           |> put_flash(
             :error,
             Gettext.gettext(PhoenixKitWeb.Gettext, "You do not have access to this dashboard.")
           )
           |> push_navigate(to: Paths.index())}
        end
    end
  end

  # EVERY event operates on a FRESH dashboard: builder sessions are
  # long-lived and every context write persists the whole JSONB layout
  # column, so acting on the mounted-at copy would clobber anything another
  # session (a second tab, an external script) changed since — wholesale.
  # Re-fetching narrows the stale window from session-lifetime to the
  # single event. A dashboard deleted underneath the session exits cleanly.
  @impl true
  def handle_event(event, params, socket) do
    case Dashboards.get(socket.assigns.dashboard.uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard not found."))
         |> push_navigate(to: Paths.index())}

      dashboard ->
        socket = assign(socket, :dashboard, dashboard)
        do_handle_event(event, params, ensure_active_layout(socket))
    end
  end

  # The active layout may have been deleted by another session — fall back to
  # the first one rather than editing a ghost id.
  defp ensure_active_layout(socket) do
    active = socket.assigns.active_layout
    ids = socket.assigns.dashboard |> Dashboards.layouts() |> Enum.map(& &1["id"])

    if is_nil(active) or active in ids do
      socket
    else
      socket
      |> assign(:active_layout, Dashboards.first_layout_id(socket.assigns.dashboard))
      |> assign(:renaming_layout, nil)
    end
  end

  defp do_handle_event("add_widget", %{"key" => key}, socket) when is_binary(key) do
    added(socket, Dashboards.add_widget(socket.assigns.dashboard, key, actor_opts(socket)))
  end

  # A catalog entry dragged out and dropped on a grid cell (DashboardCatalogDrag).
  # x/y are 0-based cells for the active bp; the context clamps + refuses an
  # occupied spot (the hook only offers free cells).
  defp do_handle_event("add_widget_at", %{"key" => key, "x" => x, "y" => y}, socket)
       when is_binary(key) do
    added(
      socket,
      Dashboards.add_widget_at(
        socket.assigns.dashboard,
        key,
        socket.assigns.active_layout,
        to_i(x),
        to_i(y),
        actor_opts(socket)
      )
    )
  end

  # A catalog entry dropped on the pixel canvas at exact px.
  defp do_handle_event("add_widget_px", %{"key" => key, "fx" => fx, "fy" => fy}, socket)
       when is_binary(key) do
    added(
      socket,
      Dashboards.add_widget_px(
        socket.assigns.dashboard,
        key,
        to_i(fx),
        to_i(fy),
        actor_opts(socket)
      )
    )
  end

  defp do_handle_event("remove_widget", %{"id" => instance_id}, socket) do
    apply_layout(
      socket,
      Dashboards.remove_widget(socket.assigns.dashboard, instance_id, actor_opts(socket))
    )
  end

  # Pushed by the DashboardGridDrag hook when a widget is dropped on a new cell
  # (the active bp). x/y are 0-based grid cells; the context clamps to the tier
  # and refuses an occupied spot (the hook never offers one — stale/crafted
  # events only, so the error is a silent no-op).
  defp do_handle_event("move_widget_grid", %{"id" => id, "x" => x, "y" => y}, socket)
       when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.place_widget_grid(
        socket.assigns.dashboard,
        id,
        socket.assigns.active_layout,
        to_i(x),
        to_i(y)
      )
    )
  end

  # Legacy/no-JS re-pack: set the given id order as the reading order and pack
  # the widgets compactly in it (kept server-side; the drag hook places cells
  # directly via move_widget_grid).
  defp do_handle_event("reorder_widgets", %{"ordered_ids" => ordered_ids} = params, socket)
       when is_list(ordered_ids) do
    case Dashboards.reorder_widgets(
           socket.assigns.dashboard,
           socket.assigns.active_layout,
           ordered_ids
         ) do
      {:ok, dashboard} ->
        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> flash_sortable(params["moved_id"], "ok")}

      {:error, _} ->
        {:noreply, flash_sortable(socket, params["moved_id"], "error")}
    end
  end

  defp do_handle_event("set_layout", %{"id" => id}, socket) when is_binary(id) do
    if Dashboards.get_layout(socket.assigns.dashboard, id) do
      {:noreply, socket |> assign(:active_layout, id) |> assign(:renaming_layout, nil)}
    else
      {:noreply, socket}
    end
  end

  # "+" — instant-create seeded from the active layout (doubles as duplicate),
  # activate it, and drop straight into rename mode.
  defp do_handle_event("add_layout", _params, socket) do
    case Dashboards.add_layout(socket.assigns.dashboard, socket.assigns.active_layout) do
      {:ok, dashboard, entry} ->
        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:active_layout, entry["id"])
         |> assign(:renaming_layout, entry["id"])}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp do_handle_event("start_rename_layout", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, assign(socket, :renaming_layout, id)}
  end

  defp do_handle_event("cancel_rename_layout", _params, socket) do
    {:noreply, assign(socket, :renaming_layout, nil)}
  end

  defp do_handle_event("rename_layout", %{"id" => id, "name" => name}, socket)
       when is_binary(id) and is_binary(name) do
    case Dashboards.rename_layout(socket.assigns.dashboard, id, name) do
      {:ok, dashboard} ->
        {:noreply, socket |> assign(:dashboard, dashboard) |> assign(:renaming_layout, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :renaming_layout, nil)}
    end
  end

  defp do_handle_event("delete_layout", %{"id" => id}, socket) when is_binary(id) do
    case Dashboards.delete_layout(socket.assigns.dashboard, id) do
      {:ok, dashboard} ->
        # If the active layout died, fall back to the first remaining one.
        socket = assign(socket, :dashboard, dashboard)

        active =
          if socket.assigns.active_layout == id,
            do: Dashboards.first_layout_id(dashboard),
            else: socket.assigns.active_layout

        {:noreply, socket |> assign(:active_layout, active) |> assign(:renaming_layout, nil)}

      {:error, :last_layout} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "A dashboard needs at least one layout.")
         )}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp do_handle_event("toggle_grid_lines", _params, socket) do
    {:noreply, update(socket, :show_grid_lines, &(!&1))}
  end

  # Exact lattice dimensions from the Layout bar's inputs. Values clamp into
  # the lattice bounds and never below the extent widgets occupy.
  defp do_handle_event("set_dims", %{"cols" => cols, "rows" => rows}, socket) do
    apply_layout(
      socket,
      Dashboards.set_grid_dims(
        socket.assigns.dashboard,
        socket.assigns.active_layout,
        to_i(cols),
        to_i(rows)
      )
    )
  end

  # "Fit screen": the DashboardFitScreen hook reports the real screen pixels;
  # the layout becomes that screen's shape on the 25px lattice.
  defp do_handle_event("fit_screen", %{"w" => w, "h" => h}, socket) do
    cell = Lattice.cell()

    apply_layout(
      socket,
      Dashboards.set_grid_dims(
        socket.assigns.dashboard,
        socket.assigns.active_layout,
        round(to_i(w) / cell),
        round(to_i(h) / cell)
      )
    )
  end

  # Cycle a widget instance through its declared views (the hover-toolbar
  # button) — view modes are user-chosen; size never switches them silently.
  # On the GRID the view is PER LAYOUT (designing the phone layout means
  # choosing how widgets look on the phone); the pixel canvas has no layouts,
  # so there it cycles the instance default.
  defp do_handle_event("cycle_view", %{"id" => instance_id}, socket)
       when is_binary(instance_id) do
    dashboard = socket.assigns.dashboard
    grid? = Dashboard.layout_mode(dashboard) == "grid"

    with %{} = inst <- Enum.find(dashboard.layout, &(&1["id"] == instance_id)),
         %Widget{views: [_ | _] = views} <- Registry.get(inst["widget_key"]) do
      keys = Enum.map(views, & &1.key)

      current =
        (grid? && Layout.view(inst, socket.assigns.active_layout)) || inst["view"] || hd(keys)

      next = Enum.at(keys, rem((Enum.find_index(keys, &(&1 == current)) || 0) + 1, length(keys)))

      result =
        if grid? do
          Dashboards.set_layout_view(dashboard, instance_id, socket.assigns.active_layout, next)
        else
          Dashboards.configure_widget(dashboard, instance_id, %{view: next}, actor_opts(socket))
        end

      apply_layout(socket, result)
    else
      _ -> {:noreply, socket}
    end
  end

  defp do_handle_event("grid_dim", %{"dim" => dim, "delta" => delta}, socket) do
    with {:ok, dim} <- Map.fetch(%{"cols" => :cols, "rows" => :rows}, dim),
         d when d in [-1, 1] <- to_i(delta) do
      case Dashboards.resize_grid(socket.assigns.dashboard, socket.assigns.active_layout, dim, d) do
        {:ok, dashboard} ->
          {:noreply, assign(socket, :dashboard, dashboard)}

        {:error, :occupied} ->
          msg =
            case dim do
              :cols ->
                Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Cannot remove the column — a widget still occupies it."
                )

              :rows ->
                Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Cannot remove the row — a widget still occupies it."
                )
            end

          {:noreply, put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      # Crafted/malformed payloads are ignored.
      _ -> {:noreply, socket}
    end
  end

  # Free/pixel-canvas resize (DashboardResize hook, free mode): absolute px size,
  # no snap. Stored under fw/fh; the context clamps to a sane px range.
  defp do_handle_event("resize_widget_to", %{"id" => id, "fw" => fw, "fh" => fh}, socket)
       when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.resize_widget_px(socket.assigns.dashboard, id, to_i(fw), to_i(fh))
    )
  end

  # Grid-mode resize (active layout): the card snaps to the nearest cell on
  # release. The context clamps to the widget type's min/max + the bp's columns.
  defp do_handle_event("resize_widget_to", %{"id" => id, "w" => w, "h" => h}, socket)
       when is_binary(id) do
    with rw when rw >= 1 <- to_i(w),
         rh when rh >= 1 <- to_i(h) do
      apply_layout(
        socket,
        Dashboards.resize_widget(
          socket.assigns.dashboard,
          id,
          socket.assigns.active_layout,
          rw,
          rh
        )
      )
    else
      # A non-positive / unparseable span (only a crafted event) is ignored rather
      # than silently snapping the widget to its minimum size.
      _ -> {:noreply, socket}
    end
  end

  # Pushed by the DashboardFreeDrag hook after a drag in the free canvas; fx/fy are
  # the absolute px position (no cell snap).
  defp do_handle_event("move_widget_to", %{"id" => id, "fx" => fx, "fy" => fy}, socket)
       when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.place_widget_px(socket.assigns.dashboard, id, to_i(fx), to_i(fy))
    )
  end

  # Bring a pixel widget above (or below) every other one — overlap on the free
  # canvas is allowed, z-order makes it deliberate.
  defp do_handle_event("restack_widget", %{"id" => id, "dir" => dir}, socket)
       when is_binary(id) and dir in ["front", "back"] do
    apply_layout(socket, Dashboards.restack_widget_px(socket.assigns.dashboard, id, dir))
  end

  defp do_handle_event("open_settings", %{"id" => instance_id}, socket) do
    {:noreply, assign(socket, :settings_instance, instance_id)}
  end

  defp do_handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :settings_instance, nil)}
  end

  defp do_handle_event("save_settings", params, socket) do
    case socket.assigns.settings_instance do
      nil -> {:noreply, socket}
      instance_id -> save_settings(socket, instance_id, params)
    end
  end

  # Ignore any malformed / unexpected event rather than crashing the builder.
  defp do_handle_event(event, _params, socket) do
    Logger.debug("[Dashboards] Unhandled event: #{inspect(event)}")
    {:noreply, socket}
  end

  # No open settings modal (e.g. a double submit racing close_settings) is a
  # no-op — otherwise configure_widget would write the unchanged layout and log
  # a phantom "widget_configured" activity for a nil instance.
  defp save_settings(socket, instance_id, params) do
    grid? = Dashboard.layout_mode(socket.assigns.dashboard) == "grid"

    attrs =
      %{settings: params["settings"] || %{}}
      |> then(&if grid?, do: &1, else: maybe_put_view(&1, params["view"]))
      |> maybe_put_min_override(params["min_override"])

    # On the grid the view is a PER-LAYOUT setting (stored on the active
    # layout's placement); everything else stays instance-level.
    socket =
      if grid? && params["view"] not in [nil, ""] do
        case Dashboards.set_layout_view(
               socket.assigns.dashboard,
               instance_id,
               socket.assigns.active_layout,
               params["view"]
             ) do
          {:ok, dashboard} -> assign(socket, :dashboard, dashboard)
          _ -> socket
        end
      else
        socket
      end

    socket = assign(socket, :settings_instance, nil)

    case Dashboards.configure_widget(
           socket.assigns.dashboard,
           instance_id,
           attrs,
           actor_opts(socket)
         ) do
      {:ok, d1} ->
        # Settings/view are now persisted. Apply the grid position, THEN the
        # size — resize fits against the neighbours at the widget's anchor, so
        # it must run at the destination cell or a valid combined edit would be
        # shrunk by the OLD neighbourhood. A failing geometry write (transient
        # DB error, or a Column/Row pointing at an occupied spot) keeps the last
        # successfully-saved dashboard rather than reverting to stale data.
        d2 =
          apply_or_keep(d1, &maybe_place(&1, instance_id, socket.assigns.active_layout, params))

        d3 =
          apply_or_keep(d2, &maybe_resize(&1, instance_id, socket.assigns.active_layout, params))

        {:noreply, assign(socket, :dashboard, d3)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp apply_or_keep(dashboard, fun) do
    case fun.(dashboard) do
      {:ok, updated} -> updated
      _ -> dashboard
    end
  end

  # Periodic tick: `send_update/2` every live widget whose interval has elapsed
  # so it re-queries. Reschedules itself while any live widget remains.
  @impl true
  def handle_info(:refresh_tick, socket) do
    now = System.monotonic_time(:millisecond)
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Resolve each widget's placement for the active tier once, so a refreshed
    # widget's `size` matches what it first rendered with (no size flip on refresh).
    placements =
      socket.assigns.dashboard
      |> Dashboards.resolve_items(socket.assigns.active_layout)
      |> Map.new(fn {item, p} -> {item["id"], p} end)

    refresh_at =
      Enum.reduce(
        socket.assigns.dashboard.layout,
        socket.assigns.refresh_at,
        &refresh_due(&1, &2, now, scope, placements)
      )

    socket = assign(socket, :refresh_at, refresh_at)

    if any_live_widget?(socket.assigns.dashboard) do
      Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
      {:noreply, socket}
    else
      # Loop stops when no live widget remains; clear the latch so re-adding one
      # can restart it (via maybe_schedule_refresh/1) without a full remount.
      {:noreply, assign(socket, :refresh_scheduled?, false)}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Dashboards] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Schedule the refresh loop once, when the dashboard has at least one live
  # widget and the socket is connected (no timers during the static mount).
  defp maybe_schedule_refresh(socket) do
    if connected?(socket) and not socket.assigns.refresh_scheduled? and
         any_live_widget?(socket.assigns.dashboard) do
      Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
      assign(socket, :refresh_scheduled?, true)
    else
      socket
    end
  end

  # send_update a single live widget when its interval has elapsed; updates the
  # per-instance next-refresh time. A no-op for static widgets or not-yet-due
  # ones — and for widgets the viewer can't see (they render a placeholder, so a
  # send_update would target a component that isn't mounted and log a warning
  # every tick).
  #
  # The not-yet-seen default is `now`, NOT 0: `now` is monotonic time, which is
  # a large NEGATIVE number on the BEAM — against a 0 default the due-check
  # could never pass, so no widget ever refreshed (the clock only appeared to
  # tick because unrelated re-renders re-ran its update/2).
  defp refresh_due(inst, acc, now, scope, placements) do
    case Registry.get(inst["widget_key"]) do
      %Widget{refresh_interval: ms} = widget
      when is_integer(ms) ->
        if now >= Map.get(acc, inst["id"], now) and Registry.visible_for_scope?(widget, scope) do
          send_update(
            widget.component,
            widget_update_assigns(inst, scope, placements[inst["id"]])
          )

          Map.put(acc, inst["id"], now + ms)
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp any_live_widget?(dashboard) do
    Enum.any?(dashboard.layout, fn inst ->
      match?(%Widget{refresh_interval: ms} when is_integer(ms), Registry.get(inst["widget_key"]))
    end)
  end

  # The assigns a widget's LiveComponent receives on a periodic refresh — `size` is
  # the active tier's resolved placement (matching the first render), or the default
  # tier when unavailable.
  defp widget_update_assigns(inst, scope, placement) do
    # Fallback: Layout.placement/2 returns the span defaults for any id.
    p = placement || Layout.placement(inst, "default")

    [
      id: inst["id"],
      settings: inst["settings"] || %{},
      # The RESOLVED placement carries the layout's view override (pixel mode
      # has no placement → the instance default).
      view: (placement || %{})["view"] || inst["view"],
      size: %{w: p["w"], h: p["h"]},
      scope: scope
    ]
  end

  # Only carry a `:view` into the config update when the form actually submitted
  # one (widgets without declared views render no selector).
  defp maybe_put_view(attrs, nil), do: attrs
  defp maybe_put_view(attrs, ""), do: attrs
  defp maybe_put_view(attrs, view), do: Map.put(attrs, :view, view)

  # The "Allow smaller than recommended" checkbox (grid mode only; absent in
  # the pixel form → leave the flag untouched).
  defp maybe_put_min_override(attrs, nil), do: attrs

  defp maybe_put_min_override(attrs, val),
    do: Map.put(attrs, :min_override, val in [true, "true"])

  # Resolve which layout to show: the ?layout= deep link when valid, else the
  # current assign when still valid (live patches must not reset the tab), else
  # the first layout.
  defp resolve_active_layout(socket, param_id) do
    dashboard = socket.assigns.dashboard

    cond do
      is_binary(param_id) and Dashboards.get_layout(dashboard, param_id) != nil ->
        assign(socket, :active_layout, param_id)

      socket.assigns.active_layout != nil and
          Dashboards.get_layout(dashboard, socket.assigns.active_layout) != nil ->
        socket

      true ->
        assign(socket, :active_layout, Dashboards.first_layout_id(dashboard))
    end
  end

  # Assign the updated dashboard on a successful layout write; a rare `{:error, _}`
  # (transient DB failure) is a no-op rather than a `MatchError` crash.
  defp apply_layout(socket, {:ok, dashboard}),
    do: {:noreply, assign(socket, :dashboard, dashboard)}

  defp apply_layout(socket, {:error, _}), do: {:noreply, socket}

  # Shared add-widget outcome: assign + restart the refresh loop if the new
  # widget is a live one; flash on failure.
  defp added(socket, {:ok, dashboard}) do
    {:noreply, socket |> assign(:dashboard, dashboard) |> maybe_schedule_refresh()}
  end

  defp added(socket, {:error, _}) do
    {:noreply,
     put_flash(socket, :error, Gettext.gettext(PhoenixKitWeb.Gettext, "Could not add widget."))}
  end

  # The Settings modal's size inputs (server-driven resize fallback). Free mode
  # submits px (fw/fh); grid mode submits cell spans (w/h). Blank values leave the
  # size untouched; the context clamps to the widget/px min/max.
  defp maybe_resize(dashboard, id, _bp, %{"fw" => fw, "fh" => fh}) when fw != "" and fh != "" do
    Dashboards.resize_widget_px(dashboard, id, to_i(fw), to_i(fh))
  end

  defp maybe_resize(dashboard, id, bp, %{"w" => w, "h" => h}) when w != "" and h != "" do
    Dashboards.resize_widget(dashboard, id, bp, to_i(w), to_i(h))
  end

  defp maybe_resize(dashboard, _id, _bp, _params), do: {:ok, dashboard}

  # The Settings modal's grid Column/Row inputs (the no-JS placement fallback).
  # Displayed 1-based; the placement is 0-based cells.
  defp maybe_place(dashboard, id, bp, %{"x" => x, "y" => y}) when x != "" and y != "" do
    Dashboards.place_widget_grid(dashboard, id, bp, to_i(x) - 1, to_i(y) - 1)
  end

  # Pixel mode: exact-px position from the modal's X/Y inputs (the no-JS/no-drag
  # fallback, like Column/Row in grid mode).
  defp maybe_place(dashboard, id, _bp, %{"fx" => fx, "fy" => fy}) when fx != "" and fy != "" do
    Dashboards.place_widget_px(dashboard, id, to_i(fx), to_i(fy))
  end

  defp maybe_place(dashboard, _id, _bp, _params), do: {:ok, dashboard}

  # Pulse the just-moved widget green/red (`sortable:flash`, answered by the
  # DashboardGridDrag hook).
  defp flash_sortable(socket, nil, _status), do: socket

  defp flash_sortable(socket, moved_id, status) do
    push_event(socket, "sortable:flash", %{uuid: moved_id, status: status})
  end

  defp can_view?(dashboard, socket) do
    Dashboards.visible_to?(dashboard, actor_uuid(socket), user_role_uuids(socket))
  end

  defp settings_instance_data(dashboard, instance_id) do
    Enum.find(dashboard.layout, &(&1["id"] == instance_id))
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Viewport-bounded (100dvh minus core's h-16 admin header), NOT h-full:
    the admin layout's column is content-sized, so h-full resolves to auto and
    any content growth (a fit-rescale, a widget near the fold) would grow the
    PAGE and pop a window scrollbar — the builder is app-like, its grid/canvas
    panes scroll internally instead. --%>
    <div class="flex h-[calc(100dvh-4rem)] flex-col">
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <div class="flex items-center gap-3">
          <.link navigate={Paths.index()} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <h1 class="text-lg font-semibold">{@dashboard.title}</h1>
          <span class="badge badge-ghost badge-sm">{scope_label(@dashboard.scope)}</span>
          <.link
            navigate={Paths.edit(@dashboard.uuid)}
            class="btn btn-ghost btn-xs btn-square"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard settings")}
          >
            <.icon name="hero-pencil" class="w-3.5 h-3.5" />
          </.link>
        </div>
        <div class="flex items-center gap-2">
          <button
            id="dashboard-fullscreen-btn"
            phx-hook="DashboardFullscreen"
            data-target={
              if Dashboard.layout_mode(@dashboard) == "free",
                do: "dashboard-free-fit",
                else: "dashboard-grid-fit"
            }
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Full screen")}
          >
            <.icon name="hero-arrows-pointing-out" class="w-4 h-4" />
          </button>
          <%!-- Client-side toggle (JS.toggle, no server round-trip) — the panel is
          always rendered, hidden by default, so opening it is instant. --%>
          <button
            id="dashboard-catalog-toggle"
            type="button"
            phx-click={JS.toggle(to: "#dashboard-catalog")}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-squares-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Widgets")}
          </button>
        </div>
      </div>

      <div class="relative flex flex-1 min-h-0">
        <.grid
          dashboard={@dashboard}
          scope={@phoenix_kit_current_scope}
          active_layout={@active_layout}
          renaming_layout={@renaming_layout}
          show_grid_lines={@show_grid_lines}
        />
        <.catalog_drawer catalog={@catalog} />
      </div>

      <.settings_modal
        :if={@settings_instance}
        instance={settings_instance_data(@dashboard, @settings_instance)}
        mode={Dashboard.layout_mode(@dashboard)}
        active_layout={@active_layout}
        grid_placement={Dashboards.resolve_placement(@dashboard, @settings_instance, @active_layout)}
        cols={Dashboards.grid_cols(@dashboard, @active_layout)}
        max_rows={Dashboards.grid_rows(@dashboard, @active_layout)}
      />
    </div>
    """
  end

  # Mode-aware grid. "grid" is explicit cell placement (x/y anchor + w/h span,
  # DashboardGridDrag); "free" is exact-px placement (DashboardFreeDrag,
  # z-order restack).
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:active_layout, :string, required: true)
  attr(:renaming_layout, :string, default: nil)
  attr(:show_grid_lines, :boolean, required: true)

  defp grid(assigns) do
    assigns = assign(assigns, :mode, Dashboard.layout_mode(assigns.dashboard))

    ~H"""
    <div class="flex min-w-0 flex-1 flex-col overflow-hidden">
      <%!-- No loading state: layouts are user-defined, nothing to detect —
      a dashboard opens instantly on its (deep-linked or first) layout. --%>
      <div class="flex min-h-0 flex-1 flex-col">
        <.layout_bar
          :if={@mode == "grid"}
          active_layout={@active_layout}
          renaming_layout={@renaming_layout}
          dashboard={@dashboard}
          show_grid_lines={@show_grid_lines}
        />

        <%!-- The empty hint only replaces the PIXEL canvas; a grid dashboard
        always renders its surface (so the Show-grid guides work on an empty
        board and catalog drag-outs have cells to drop onto) with the hint
        floating over it. --%>
        <div
          :if={@dashboard.layout == [] and @mode != "grid"}
          class="flex flex-1 flex-col items-center justify-center bg-base-200 text-base-content/40"
        >
          <.icon name="hero-squares-plus" class="w-12 h-12" />
          <p class="mt-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Add widgets from the panel on the right.")}</p>
        </div>

        <.grid_mode
          :if={@mode == "grid"}
          dashboard={@dashboard}
          scope={@scope}
          active_layout={@active_layout}
          show_grid_lines={@show_grid_lines}
          empty={@dashboard.layout == []}
        />
        <.free_mode :if={@dashboard.layout != [] and @mode == "free"} dashboard={@dashboard} scope={@scope} />
      </div>
    </div>
    """
  end

  attr(:active_layout, :string, required: true)
  attr(:renaming_layout, :string, default: nil)
  attr(:dashboard, :map, required: true)
  attr(:show_grid_lines, :boolean, required: true)

  # The layout tab strip: [Layout 1] [Layout 2] [+], an actions dropdown on the
  # ACTIVE tab (rename / delete — no nested buttons inside tabs, per a11y), and
  # the per-layout Columns/Rows + Show-grid controls on the right. Renaming
  # swaps the tab for an inline input (Enter commits, Esc/blur cancels).
  defp layout_bar(assigns) do
    assigns = assign(assigns, :entries, Dashboards.layouts(assigns.dashboard))

    ~H"""
    <div class="flex items-center gap-2 border-b border-base-300 bg-base-100 px-4 py-1.5">
      <%!-- overflow-y-hidden: overflow-x-auto forces the OTHER axis to compute
      as auto too, so daisyUI's .btn:active 0.5px press-shift would otherwise
      pop a scrollbar for as long as a tab is held down. --%>
      <div
        role="tablist"
        aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard layouts")}
        class="flex min-w-0 flex-nowrap items-center gap-1 overflow-x-auto overflow-y-hidden"
      >
        <%= for entry <- @entries do %>
          <form
            :if={@renaming_layout == entry["id"]}
            phx-submit="rename_layout"
            phx-value-id={entry["id"]}
            class="shrink-0"
          >
            <input
              type="text"
              name="name"
              value={entry["name"]}
              maxlength="60"
              class="input input-xs w-36"
              autofocus
              phx-keydown="cancel_rename_layout"
              phx-key="escape"
              phx-blur="cancel_rename_layout"
            />
          </form>
          <button
            :if={@renaming_layout != entry["id"]}
            type="button"
            role="tab"
            aria-selected={to_string(@active_layout == entry["id"])}
            phx-click="set_layout"
            phx-value-id={entry["id"]}
            class={[
              "btn btn-xs max-w-40 shrink-0",
              if(@active_layout == entry["id"], do: "btn-primary", else: "btn-ghost")
            ]}
            title={"#{entry["name"]} · #{entry["cols"]}×#{entry["rows"]}"}
          >
            <span class="truncate">{entry["name"]}</span>
          </button>
        <% end %>

        <button
          type="button"
          phx-click="add_layout"
          class="btn btn-ghost btn-xs btn-square shrink-0"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Add a layout (copies the current one)")}
          aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Add layout")}
        >
          <.icon name="hero-plus" class="w-3.5 h-3.5" />
        </button>
      </div>

      <%!-- Settings for the ACTIVE layout: rename/delete plus its grid size
      and the Fit-screen action — dimension controls live here, out of the
      bar (they're a deliberate per-layout setting, not a view control). --%>
      <div class="dropdown dropdown-end shrink-0">
        <button
          type="button"
          tabindex="0"
          class="btn btn-ghost btn-xs btn-square"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Layout settings")}
          aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Layout settings")}
        >
          <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
        </button>
        <div tabindex="0" class="dropdown-content z-30 w-64 rounded-box bg-base-100 p-2 shadow">
          <ul class="menu p-0">
            <li>
              <button type="button" phx-click="start_rename_layout" phx-value-id={@active_layout}>
                <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Rename")}
              </button>
            </li>
            <li :if={length(@entries) > 1}>
              <button
                type="button"
                phx-click="delete_layout"
                phx-value-id={@active_layout}
                data-confirm={
                  Gettext.gettext(
                    PhoenixKitWeb.Gettext,
                    "Delete this layout? Its placements are removed; the widgets stay available in the other layouts."
                  )
                }
                class="text-error"
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
              </button>
            </li>
          </ul>

          <div class="divider my-1"></div>

          <div class="px-1 pb-1.5 text-xs font-medium text-base-content/50">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Grid size (columns × rows)")}
          </div>
          <form id="grid-dims" phx-change="set_dims" class="flex items-center gap-2 px-1">
            <input
              type="number"
              name="cols"
              value={Dashboards.grid_cols(@dashboard, @active_layout)}
              min={Lattice.min_dim()}
              max={Lattice.max_dim()}
              class="input input-sm w-20 text-center tabular-nums"
              aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Columns")}
            />
            <span class="text-base-content/40">×</span>
            <input
              type="number"
              name="rows"
              value={Dashboards.grid_rows(@dashboard, @active_layout)}
              min={Lattice.min_dim()}
              max={Lattice.max_dim()}
              class="input input-sm w-20 text-center tabular-nums"
              aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Rows")}
            />
          </form>
          <button
            id="dashboard-fit-screen"
            type="button"
            phx-hook="DashboardFitScreen"
            class="btn btn-ghost btn-sm mt-1.5 w-full justify-start gap-2"
            title={
              Gettext.gettext(
                PhoenixKitWeb.Gettext,
                "Resize this layout's grid to match the screen you're viewing on"
              )
            }
          >
            <.icon name="hero-viewfinder-circle" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Fit this screen")}
          </button>
        </div>
      </div>

      <div class="ml-auto flex items-center gap-3">
        <label class="flex cursor-pointer items-center gap-1.5">
          <span class="text-xs font-medium text-base-content/50">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Show grid")}
          </span>
          <input
            type="checkbox"
            class="toggle toggle-xs"
            phx-click="toggle_grid_lines"
            checked={@show_grid_lines}
          />
        </label>
      </div>
    </div>
    """
  end

  # Grid mode — the active layout, laid out at its design width and fit-scaled
  # to the pane by `DashboardGridFit`. Fully editable at any scale: cell-drag
  # via `DashboardGridDrag` (screen-space metrics, transform-aware), corner
  # resize via the scale-aware `DashboardResize`, or the Settings modal inputs.
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:active_layout, :string, required: true)
  attr(:show_grid_lines, :boolean, required: true)
  attr(:empty, :boolean, default: false)

  defp grid_mode(assigns) do
    entry =
      Dashboards.get_layout(assigns.dashboard, assigns.active_layout) ||
        %{"name" => "Layout", "cols" => 64, "rows" => 36}

    assigns =
      assign(assigns,
        items: Dashboards.resolve_items(assigns.dashboard, assigns.active_layout),
        cols: entry["cols"],
        rows: entry["rows"],
        layout_name: entry["name"],
        design_w: Dashboards.design_width(assigns.dashboard, assigns.active_layout),
        design_h: Dashboards.design_height(assigns.dashboard, assigns.active_layout)
      )

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <%!-- ONE SCREENFUL, NEVER SCROLLS, STANDARD 25px CELLS: per-axis
      stretch only absorbs the last ~10% (a fitted screen fills exactly);
      otherwise the intact artboard shrinks into a smaller pane or floats
      centered at natural size in a bigger one — never blown up (a bigger
      display wants its own fitted layout). DashboardGridFit owns the math. --%>
      <div
        id="dashboard-grid-fit"
        phx-hook="DashboardGridFit"
        data-design-width={@design_w}
        data-design-height={@design_h}
        class="relative flex flex-1 flex-col items-center justify-center overflow-hidden bg-base-200 p-3"
      >
        <%!-- Empty-board hint floats over the surface; pointer-events-none so
        catalog drops land on the cells underneath. --%>
        <div
          :if={@empty}
          class="pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center text-base-content/40"
        >
          <.icon name="hero-squares-plus" class="w-12 h-12" />
          <p class="mt-2">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Add widgets from the panel on the right.")}
          </p>
        </div>
        <%!-- No-JS fallback: the canvas starts hidden (the pre-fit frame must
        never flash), so without the hook a pure-CSS delayed animation reveals
        it. NOT a <noscript> style — morphdom livens noscript children when
        the LV patches after connect, leaking the styles into the JS-on page. --%>
        <style>
          @keyframes pk-canvas-reveal {
            to {
              opacity: 1;
            }
          }
        </style>
        <%!-- The spacer carries the SCALED dimensions (set by the fit hook) so
        flex centering positions the artboard; the canvas is scaled inside it. --%>
        <div class="pk-grid-scale-spacer relative">
          <div
            class={[
              "pk-grid-scale-canvas absolute left-0 top-0",
              "bg-base-100 shadow-xl ring-1 ring-base-content/10"
            ]}
            style={"width: #{@design_w}px; height: #{@design_h}px; transform-origin: top left; opacity: 0; animation: pk-canvas-reveal 0s 2.5s forwards;"}
          >
            <div
              id="dashboard-grid"
              phx-hook="DashboardGridDrag"
              data-cols={@cols}
              data-max-rows={@rows}
              class="relative grid h-full w-full content-start"
              style={grid_style(@cols, @rows, @show_grid_lines)}
            >
              <.widget_card
                :for={{inst, placement} <- @items}
                inst={inst}
                placement={placement}
                scope={@scope}
                mode="grid"
                active_layout={@active_layout}
                cols={@cols}
              />
            </div>
          </div>
        </div>
        <%!-- Artboard caption — editor chrome, so it never scales with the
        board; the fit hook hides it when the board leaves no room below. --%>
        <div class="pk-grid-caption pointer-events-none absolute bottom-1 left-0 right-0 text-center font-mono text-[11px] tracking-wide text-base-content/50">
          {@layout_name} · {@cols}×{@rows}
        </div>
      </div>
    </div>
    """
  end

  # The lattice template + (optionally) the cell guides as a CSS background —
  # exact at any pitch since the lattice is gapless, and zero extra DOM (the
  # old per-cell divs would be thousands of nodes at 25px cells).
  defp grid_style(cols, rows, show_grid_lines) do
    base =
      "grid-template-columns: repeat(#{cols}, minmax(0, 1fr)); " <>
        "grid-template-rows: repeat(#{rows}, minmax(0, 1fr));"

    if show_grid_lines do
      # A dot at each cell corner, not hairlines — at this pitch full lines
      # read as graph paper; dots stay calm. Pitch in fractions of the box,
      # so the guides track the FITTED cell size exactly (the fit hook sizes
      # the canvas natively — cells are only nominally 25px).
      dot = "color-mix(in oklab, var(--color-base-content) 9%, transparent)"

      base <>
        " background-image: radial-gradient(circle at 1px 1px, #{dot} 1px, transparent 1.4px);" <>
        " background-size: calc(100% / #{cols}) calc(100% / #{rows});"
    else
      base
    end
  end

  # Free/pixel mode — exact-px placement on a scrollable canvas, fit-scaled to
  # the available width. No Layout bar (a pixel canvas has no named layouts).
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)

  defp free_mode(assigns) do
    {cw, ch} = free_canvas_dims(assigns.dashboard.layout)
    assigns = assign(assigns, cw: cw, ch: ch)

    ~H"""
    <div class="relative flex min-h-0 flex-1 flex-col">
      <%!-- No padding and no canvas frame: the canvas fills the pane edge-to-edge
      (DashboardFreeFit also grows its height to at least the pane's), so there
      is no visible gap around it. --%>
      <div
        id="dashboard-free-fit"
        phx-hook="DashboardFreeFit"
        class="relative flex-1 overflow-auto bg-base-200"
        style="scrollbar-gutter: stable;"
      >
      <%!-- The spacer carries the scaled dimensions so the area scrolls; the
      canvas is scaled in place (transform) by DashboardFreeFit to fill the
      width. It starts hidden so the pre-fit (unscaled) frame never flashes —
      the fit is one synchronous measure on mount, so there is NO loading
      state (same as grid mode). Without JS a pure-CSS delayed animation
      reveals it (a <noscript> style would leak: morphdom livens noscript
      children when the LV patches after connect). --%>
      <style>
        @keyframes pk-canvas-reveal {
          to {
            opacity: 1;
          }
        }
      </style>
      <div class="pk-free-spacer relative" style={"width: #{@cw}px; height: #{@ch}px;"}>
        <div
          id="dashboard-free-grid"
          phx-hook="DashboardFreeDrag"
          class="pk-free-canvas absolute left-0 top-0"
          style={"width: #{@cw}px; height: #{@ch}px; transform-origin: top left; opacity: 0; animation: pk-canvas-reveal 0s 2.5s forwards;"}
          data-logical-width={@cw}
          data-logical-height={@ch}
        >
          <.widget_card :for={inst <- @dashboard.layout} inst={inst} scope={@scope} mode="free" />
        </div>
      </div>
    </div>
    </div>
    """
  end

  # One placed widget: a framed card with mode-appropriate controls + its body.
  attr(:inst, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:mode, :string, required: true)
  attr(:placement, :map, default: nil)
  attr(:active_layout, :string, default: nil)
  attr(:cols, :integer, default: nil)

  defp widget_card(assigns) do
    widget = Registry.get(assigns.inst["widget_key"])

    assigns =
      assigns
      |> assign(:limits, card_limits(assigns))
      |> assign(:hidden?, assigns.mode == "grid" and (assigns.placement || %{})["hidden"] == true)
      |> assign(:views, (widget && widget.views) || [])
      |> assign(:view_name, current_view_name(widget, assigns.inst, assigns.placement))

    ~H"""
    <div
      id={"pk-w-#{@inst["id"]}"}
      phx-hook="DashboardResize"
      class={[
        "sortable-item group/widget relative flex flex-col overflow-hidden rounded-lg border shadow-sm",
        # The lattice is gapless — this margin IS the visual gap between cards.
        @mode == "grid" && "m-[2px]",
        if(@hidden?,
          do: "border-dashed border-base-300 bg-base-100/40 opacity-50",
          else: "border-base-300 bg-base-100"
        )
      ]}
      data-id={@inst["id"]}
      data-free={to_string(@mode == "free")}
      data-x={@mode == "grid" && (@placement || %{})["x"]}
      data-y={@mode == "grid" && (@placement || %{})["y"]}
      data-w={@limits.w}
      data-h={@limits.h}
      data-min-w={@limits.min_w}
      data-max-w={@limits.max_w}
      data-min-h={@limits.min_h}
      data-max-h={@limits.max_h}
      style={if @mode == "free", do: free_placement_style(@inst), else: grid_area_style(@placement)}
    >
      <%!-- The WHOLE top bar is the drag handle (the drag hooks ignore
      pointer-downs on the buttons inside it); the grip icon is just the visual
      affordance. --%>
      <div
        class={[
          grip_class(@mode),
          "flex cursor-grab touch-none select-none items-center justify-between gap-1",
          "border-b border-base-300 bg-base-200/40 px-1.5 py-1"
        ]}
        title={grip_title(@mode)}
      >
        <span class="px-1 text-base-content/30" aria-hidden="true">
          <.icon name="hero-bars-2" class="w-4 h-4" />
        </span>

        <div class="flex items-center gap-0.5 opacity-40 transition-opacity group-hover/widget:opacity-100">
          <%!-- Pixel widgets may overlap; front/back makes the stacking deliberate. --%>
          <button
            :if={@mode == "free"}
            type="button"
            phx-click="restack_widget"
            phx-value-id={@inst["id"]}
            phx-value-dir="front"
            class="btn btn-ghost btn-xs btn-square"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Bring to front")}
          >
            <.icon name="hero-chevron-double-up" class="w-3.5 h-3.5" />
          </button>
          <button
            :if={@mode == "free"}
            type="button"
            phx-click="restack_widget"
            phx-value-id={@inst["id"]}
            phx-value-dir="back"
            class="btn btn-ghost btn-xs btn-square"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Send to back")}
          >
            <.icon name="hero-chevron-double-down" class="w-3.5 h-3.5" />
          </button>
          <%!-- View modes are user-chosen (never size-switched): cycle through
          the widget's declared views right from the toolbar. --%>
          <button
            :if={@views != []}
            type="button"
            phx-click="cycle_view"
            phx-value-id={@inst["id"]}
            class="btn btn-ghost btn-xs btn-square"
            title={"#{Gettext.gettext(PhoenixKitWeb.Gettext, "View")}: #{@view_name} — #{Gettext.gettext(PhoenixKitWeb.Gettext, "click to cycle")}"}
          >
            <.icon name="hero-eye" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="open_settings"
            phx-value-id={@inst["id"]}
            class="btn btn-ghost btn-xs btn-square"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Settings")}
          >
            <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="remove_widget"
            phx-value-id={@inst["id"]}
            phx-disable-with="…"
            data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove this widget?")}
            class="btn btn-ghost btn-xs btn-square text-error"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
      <div class={[
        "min-h-0 flex-1",
        # ONE SCREENFUL, NOTHING SCROLLS: grid content self-fits (or clips) at
        # its box; only pixel-canvas cards keep scroll as the escape hatch.
        if(@mode == "grid", do: "overflow-hidden", else: "overflow-auto")
      ]}>
        <.widget_body inst={@inst} scope={@scope} placement={@placement} />
      </div>
      <span
        class="pk-resize-handle absolute bottom-0 right-0 h-4 w-4 cursor-nwse-resize touch-none opacity-0 transition-opacity group-hover/widget:opacity-100"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Drag to resize")}
      >
        <svg viewBox="0 0 10 10" class="h-full w-full text-base-content/40" aria-hidden="true">
          <path d="M9 1v8H1" fill="none" stroke="currentColor" stroke-width="1.2" />
          <path d="M9 5v4H5" fill="none" stroke="currentColor" stroke-width="1.2" />
        </svg>
      </span>
    </div>
    """
  end

  defp current_view_name(nil, _inst, _placement), do: ""

  defp current_view_name(widget, inst, placement) do
    key = (placement || %{})["view"] || inst["view"] || Widget.default_view(widget)

    case Enum.find(widget.views, &(&1.key == key)) do
      %{name: name} -> translate_catalog(name)
      _ -> key || ""
    end
  end

  # Resize bounds fed to the DashboardResize hook (as data-*). Grid: the resolved
  # placement span + the widget type's min/max clamped to the active layout's
  # columns. Pixel: the default-bp span (unused by the pixel resize, which uses px).
  defp card_limits(%{mode: "grid", inst: inst, placement: placement, cols: cols} = assigns) do
    {min, max} = widget_size_bounds(inst, assigns.active_layout)
    cols = cols || 12
    p = placement || %{}

    %{
      w: p["w"] |> to_int(4),
      h: p["h"] |> to_int(2),
      # Both bounds clamp to the tier's columns — a widget whose global min_w
      # exceeds them (legal, the cap is the largest tier) must not hand the
      # resize hook min > max, or the client would snap to a span the server
      # then rejects down to the column count.
      min_w: min(min.w, cols),
      max_w: min(max.w, cols),
      min_h: min.h,
      max_h: max.h
    }
  end

  defp card_limits(%{inst: inst}), do: size_limits(inst)

  # Span limits for an instance on a layout,
  # clamped to that tier's column count — the settings modal passes the active
  # tier (and its dashboard-resolved column count) so its W input allows a full
  # row there.
  defp size_limits(inst, bp \\ "default", cols \\ nil) do
    cols = cols || 12
    p = Layout.placement(inst, bp)
    w = p["w"] |> to_int(4) |> clamp(1, cols)
    h = p["h"] |> to_int(2) |> max(1)
    {min, max} = widget_size_bounds(inst, bp)

    %{w: w, h: h, min_w: min(min.w, cols), max_w: min(max.w, cols), min_h: min.h, max_h: max.h}
  end

  # Min/max span for an instance — the min follows the LAYOUT's resolved view
  # when that view declares one (mirrors the context's clamp); falls back to a
  # permissive range for an instance whose provider is no longer installed.
  defp widget_size_bounds(inst, bp) do
    case Registry.get(inst["widget_key"]) do
      %Widget{} = widget -> {instance_min(inst, bp, widget), widget.max_size}
      _ -> {%{w: 1, h: 1}, %{w: Lattice.max_dim(), h: Lattice.max_dim()}}
    end
  end

  # Mirrors the context: the per-instance override drops the recommended floor.
  defp instance_min(%{"min_override" => true}, _bp, _widget), do: %{w: 1, h: 1}
  defp instance_min(inst, bp, widget), do: Widget.min_size_for(widget, Layout.view(inst, bp))

  # Grid mode: explicit cell placement — `x`/`y` (0-based, from the resolved
  # placement, which always carries them) anchor the card, spanning `w`×`h`.
  # Span-only fallback (auto flow) kept for a defensive nil placement.
  defp grid_area_style(placement) do
    p = placement || %{}
    w = p["w"] |> to_int(4) |> max(1)
    h = p["h"] |> to_int(2) |> max(1)

    case {p["x"], p["y"]} do
      {x, y} when is_integer(x) and is_integer(y) ->
        "grid-column: #{x + 1} / span #{w}; grid-row: #{y + 1} / span #{h};"

      _ ->
        "grid-column: span #{w}; grid-row: span #{h};"
    end
  end

  # Grid mode drags via this module's DashboardGridDrag hook (.pk-drag-handle);
  # free mode drags via its DashboardFreeDrag hook (.pk-free-handle).
  defp grip_class("free"), do: "pk-free-handle"
  defp grip_class(_grid), do: "pk-drag-handle"

  defp grip_title(_mode), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Drag to move")

  # Free/pixel canvas: absolute px placement — no grid, no snap. `z` orders
  # deliberately-overlapping widgets (restack_widget).
  defp free_placement_style(inst) do
    {fx, fy, fw, fh} = free_geometry(inst)
    z = Layout.pixel(inst)["z"] |> to_int(0)

    "position: absolute; left: #{fx}px; top: #{fy}px; width: #{fw}px; height: #{fh}px; z-index: #{z};"
  end

  # A widget's free-canvas geometry in px, read from its embedded `pixel` map
  # (seeded on add). `Layout.pixel/1` also falls back to legacy flat keys.
  defp free_geometry(inst) do
    px = Layout.pixel(inst)
    fx = px["fx"] |> to_int(0) |> max(0)
    fy = px["fy"] |> to_int(0) |> max(0)
    fw = px["fw"] |> to_int(@free_min_px) |> max(@free_min_px)
    fh = px["fh"] |> to_int(@free_min_px) |> max(@free_min_px)
    {fx, fy, fw, fh}
  end

  # The logical **content** dimensions (px): grow to contain every widget (+
  # margin). The width floor is deliberately small — DashboardFreeFit widens the
  # canvas to at least the container width, so an empty/narrow layout renders at
  # natural size (the container is its "normal" width) and only a layout wider
  # than the container scales down. The height floor keeps an empty canvas a
  # usable drop area.
  defp free_canvas_dims(layout) do
    Enum.reduce(layout, {320, 480}, fn inst, {mw, mh} ->
      {fx, fy, fw, fh} = free_geometry(inst)
      {max(mw, fx + fw + 80), max(mh, fy + fh + 80)}
    end)
  end

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(_v, default), do: default

  defp to_i(v) when is_integer(v), do: v
  defp to_i(v) when is_float(v), do: round(v)

  defp to_i(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_i(_v), do: 0

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)

  # Resolve the widget type for an instance and render its LiveComponent. The
  # widget's `size` is the placement for the tier being viewed (so density-aware
  # widgets adapt), falling back to the default tier when none is given (pixel mode).
  # A placed widget is re-gated by the same visibility rule as the catalog
  # (module enabled + scope permission) — otherwise disabling a module (or
  # revoking access) would keep its widgets querying and showing live data on
  # any dashboard they were already placed on. The card chrome stays, so the
  # instance can still be removed or moved while unavailable.
  attr(:inst, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:placement, :map, default: nil)

  defp widget_body(assigns) do
    # Fallback (pixel mode): Layout.placement/2 returns span defaults for any id.
    placement = assigns.placement || Layout.placement(assigns.inst, "default")
    widget = Registry.get(assigns.inst["widget_key"])

    assigns =
      assigns
      |> assign(:widget, widget)
      |> assign(:placement, placement)
      |> assign(:available, widget && Registry.visible_for_scope?(widget, assigns.scope))

    ~H"""
    <div :if={is_nil(@widget)} class="card bg-base-100 h-full">
      <div class="card-body p-4 text-sm text-base-content/50">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Unknown widget")}: {@inst["widget_key"]}
      </div>
    </div>
    <div :if={@widget && !@available} class="card bg-base-100 h-full">
      <div class="card-body p-4 items-center justify-center text-center text-sm text-base-content/50">
        <.icon name="hero-lock-closed" class="w-5 h-5" />
        <span>
          {@widget.name} — {Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "unavailable (module disabled or access restricted)."
          )}
        </span>
      </div>
    </div>
    <.live_component
      :if={@widget && @available}
      module={@widget.component}
      id={@inst["id"]}
      settings={@inst["settings"] || %{}}
      view={(@placement || %{})["view"] || @inst["view"]}
      size={%{w: @placement["w"], h: @placement["h"]}}
      scope={@scope}
    />
    """
  end

  attr(:catalog, :list, required: true)

  # A slide-over panel floating above the grid (never squeezing it), closed by
  # default — the "Widgets" button or the in-panel X toggles it. Entries are
  # grouped by the module that PROVIDES the widget (Built-in first). They CLICK
  # to add at the first free spot, or DRAG OUT onto the grid/canvas to place
  # directly (DashboardCatalogDrag — a drag starts after a small movement
  # threshold, so plain clicks keep working).
  defp catalog_drawer(assigns) do
    assigns = assign(assigns, :sections, catalog_sections(assigns.catalog))

    ~H"""
    <%!-- Always rendered, hidden by default: JS.toggle flips display client-side
    (LiveView keeps JS-toggled visibility across patches), so opening is
    instant. No entrance animation: sliding in from translateX(100%)
    momentarily overflows the container's right edge and flashes a page
    scrollbar. --%>
    <div
      id="dashboard-catalog"
      phx-hook="DashboardCatalogDrag"
      style="display: none"
      class="absolute bottom-0 right-0 top-0 z-20 w-72 overflow-auto border-l border-base-300 bg-base-100 shadow-xl"
    >
      <div class="flex items-center justify-between border-b border-base-300 p-3">
        <span class="text-sm font-semibold">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget catalog")}
        </span>
        <button
          type="button"
          phx-click={JS.hide(to: "#dashboard-catalog")}
          class="btn btn-ghost btn-xs btn-square"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Close")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <div :for={{label, widgets} <- @sections} class="p-2">
        <div class="px-2 pb-1 pt-1 text-xs font-medium uppercase tracking-wide text-base-content/40">
          {label}
        </div>
        <div class="flex flex-col gap-2">
          <button
            :for={widget <- widgets}
            type="button"
            phx-click="add_widget"
            phx-value-key={widget.key}
            data-widget-key={widget.key}
            data-w={widget.default_size.w}
            data-h={widget.default_size.h}
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Click to add, or drag onto the dashboard")}
            class="text-left p-2 rounded hover:bg-base-200 flex gap-2 items-start cursor-grab"
          >
            <.icon name={widget.icon} class="w-5 h-5 mt-0.5 text-base-content/60" />
            <span>
              <span class="block text-sm font-medium">{translate_catalog(widget.name)}</span>
              <span class="block text-xs text-base-content/50">
                {translate_catalog(widget.description)}
              </span>
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Catalog entries grouped by providing module, Built-in (this module's own
  # widgets) first, other providers alphabetically. Entries keep their registry
  # order within a section.
  defp catalog_sections(catalog) do
    catalog
    |> Enum.group_by(&provider_label/1)
    |> Enum.sort_by(fn {label, _widgets} -> {label != builtin_label(), label} end)
  end

  defp provider_label(%Widget{source: PhoenixKitDashboards}), do: builtin_label()

  defp provider_label(%Widget{source: source}) when is_atom(source) and not is_nil(source) do
    # Providers implement PhoenixKit.Module, whose module_name/0 is the
    # human-readable name ("Projects"); fall back to the module's last segment.
    if function_exported?(source, :module_name, 0) do
      source.module_name()
    else
      source |> Module.split() |> List.last()
    end
  end

  defp provider_label(_widget), do: builtin_label()

  defp builtin_label, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Built-in")

  # Settings form generated from the widget type's settings_schema.
  attr(:instance, :map, required: true)
  attr(:mode, :string, required: true)
  attr(:active_layout, :string, required: true)
  attr(:grid_placement, :map, default: nil)
  attr(:cols, :integer, required: true)
  attr(:max_rows, :integer, required: true)

  defp settings_modal(assigns) do
    widget = Registry.get(assigns.instance["widget_key"])
    {fx, fy, fw, fh} = free_geometry(assigns.instance)

    # Show the RESOLVED size for the tier being edited (matches what's on screen, incl.
    # derived tiers) so saving doesn't overwrite a derived size with the default.
    grid = assigns.grid_placement || Layout.placement(assigns.instance, assigns.active_layout)

    assigns =
      assign(assigns,
        widget: widget,
        limits: size_limits(assigns.instance, assigns.active_layout, assigns.cols),
        free?: assigns.mode == "free",
        free_min_px: @free_min_px,
        free_max_px: @free_max_px,
        fw: fw,
        fh: fh,
        fx: fx,
        fy: fy,
        grid_w: grid["w"],
        grid_h: grid["h"],
        # 1-based for the form; the placement stores 0-based cells.
        grid_x: (grid["x"] || 0) + 1,
        grid_y: (grid["y"] || 0) + 1
      )

    ~H"""
    <.modal show={true} on_close="close_settings" id="widget-settings-modal">
      <:title>
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget settings")}
        <span :if={@widget} class="text-base-content/50 text-sm">
          — {translate_catalog(@widget.name)}
        </span>
      </:title>

      <form id="widget-settings-form" phx-submit="save_settings" class="flex flex-col gap-3">
          <.select
            :if={@widget && @widget.views != []}
            name="view"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
            value={(@grid_placement || %{})["view"] || @instance["view"]}
            options={Enum.map(@widget.views, fn v -> {translate_catalog(v.name), v.key} end)}
          />
          <div :if={@widget}>
            <span class="label-text text-sm">
              {if @free?,
                do: Gettext.gettext(PhoenixKitWeb.Gettext, "Size & position (px)"),
                else: Gettext.gettext(PhoenixKitWeb.Gettext, "Size")}
            </span>
            <div :if={@free?} class="grid grid-cols-4 items-end gap-2">
              <.input
                type="number"
                name="fw"
                value={@fw}
                min={@free_min_px}
                max={@free_max_px}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Width")}
              />
              <.input
                type="number"
                name="fh"
                value={@fh}
                min={@free_min_px}
                max={@free_max_px}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Height")}
              />
              <.input
                type="number"
                name="fx"
                value={@fx}
                min="0"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "X")}
              />
              <.input
                type="number"
                name="fy"
                value={@fy}
                min="0"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Y")}
              />
            </div>
            <div :if={!@free?} class="grid grid-cols-4 items-end gap-2">
              <%!-- min is HTML-permissive (1): the real floor is server-clamped,
              and the "Allow smaller" checkbox in this same submit may drop it —
              a strict min attr would block that save via native validation. --%>
              <.input
                type="number"
                name="w"
                value={@grid_w}
                min="1"
                max={@limits.max_w}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Width")}
              />
              <.input
                type="number"
                name="h"
                value={@grid_h}
                min="1"
                max={@limits.max_h}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Height")}
              />
              <%!-- Column/Row maxima are HTML-permissive too: a tight max is
              computed from the CURRENT width, so "shrink + move right" in one
              save would trip native validation. The server clamps exactly. --%>
              <.input
                type="number"
                name="x"
                value={@grid_x}
                min="1"
                max={@cols}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Column")}
              />
              <.input
                type="number"
                name="y"
                value={@grid_y}
                min="1"
                max={@max_rows}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Row")}
              />
            </div>
            <div :if={!@free?} class="mt-2">
              <.checkbox
                name="min_override"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Allow smaller than recommended")}
                checked={@instance["min_override"] == true}
              />
              <p class="mt-0.5 text-xs text-base-content/50">
                {Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Drops this widget's minimum size to 1×1 — it may render cramped below the recommended size."
                )}
              </p>
            </div>
            <p class="mt-1 text-xs text-base-content/50">
              {if @free?,
                do: Gettext.gettext(PhoenixKitWeb.Gettext, "Tip: drag the bottom-right corner to resize."),
                else:
                  Gettext.gettext(
                    PhoenixKitWeb.Gettext,
                    "Tip: drag the widget by its grip to any cell; drag the bottom-right corner to resize."
                  )}
            </p>
          </div>
          <.settings_field
            :for={field <- (@widget && @widget.settings_schema) || []}
            field={field}
            value={Map.get(@instance["settings"] || %{}, field.key)}
          />
      </form>

      <%!-- Buttons live in the :actions slot — OUTSIDE the modal's scrollable
      content area (in-form buttons flush at its bottom edge made daisyUI's
      .btn:active press-nudge overflow the container and flash its scrollbar).
      The submit stays associated with the form via the form= attribute. --%>
      <:actions>
        <button type="button" phx-click="close_settings" class="btn btn-ghost btn-sm">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
        </button>
        <button
          type="submit"
          form="widget-settings-form"
          phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
          class="btn btn-primary btn-sm"
        >
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Save")}
        </button>
      </:actions>
    </.modal>
    """
  end

  # Generated from the widget type's settings_schema. Dynamic field names
  # (`settings[<key>]`) bind via raw name=/value= — core form components accept
  # that (no %FormField{}) and give us the daisyUI 5 wrapper + label wiring.
  attr(:field, :map, required: true)
  attr(:value, :any, required: true)

  defp settings_field(%{field: %{type: :text}} = assigns) do
    ~H"""
    <.textarea name={"settings[#{@field.key}]"} label={translate_catalog(@field[:label]) || @field.key} value={@value} />
    """
  end

  defp settings_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <.checkbox
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      checked={@value in [true, "true"]}
    />
    """
  end

  defp settings_field(%{field: %{type: :select}} = assigns) do
    ~H"""
    <.select
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      value={@value}
      options={@field[:options] || []}
    />
    """
  end

  defp settings_field(assigns) do
    ~H"""
    <.input
      type={if @field.type == :number, do: "number", else: "text"}
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      value={@value}
    />
    """
  end
end
