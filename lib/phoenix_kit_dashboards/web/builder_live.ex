defmodule PhoenixKitDashboards.Web.BuilderLive do
  @moduledoc """
  The dashboard builder — a responsive, server-rendered grid of widgets that can
  be added from the catalog, reordered, resized, configured, and removed.

  ## Phoenix-first, server-authoritative

  The grid is plain HEEx + a CSS grid: each widget instance is anchored at its
  placement's `x`/`y` cells (`grid-column/-row: <line> / span <n>`) on the active
  breakpoint's column grid. It renders — and is fully readable — **without any
  JavaScript**. The server owns the canonical layout (the JSONB `layout` list);
  every mutation re-renders normally (no `phx-update="ignore"`), so
  adding/removing/moving/resizing a widget is live.

  There are two layout modes (per-dashboard `config["mode"]`):

  - **grid** — explicit cell placement on a responsive column grid: each widget
    is anchored at `x`/`y` cells and spans `w`×`h` — place it ANYWHERE (gaps are
    fine), widgets never overlap. Drag by the grip (`DashboardGridDrag`, cell-
    snapped live preview), resize by the corner (snaps + grows until blocked).
  - **free** — an absolute **pixel canvas**: drag and resize anywhere, exact px,
    no snapping (widgets may overlap). Uses separate `fx/fy/fw/fh` px keys so the
    two layouts never disturb each other. The `DashboardFreeFit` hook scales the
    whole canvas to **fill the available width** (fit-to-width, so the exact layout
    is preserved on any screen — it just shrinks on a phone); vertical overflow
    scrolls and `zoom` is an optional manual multiplier on top.

  Widgets with a `refresh_interval` are re-queried by a host-driven `:refresh_tick`
  loop.

  Custom hooks (shipped via `js_sources/0`): `DashboardGridDrag` (grid cell
  placement — the widget follows the drag cell-by-cell, never onto an occupied
  spot), `DashboardCatalogDrag` (drag a widget type OUT of the catalog and drop
  it on a grid cell or canvas point; a plain click still adds at the first free
  spot), `DashboardFreeDrag` (free-canvas move via `left/top`) and
  `DashboardResize` (corner grip `.pk-resize-handle` — px in free mode; cell-snap
  clamped by neighbours in grid). The non-hook fallbacks are the free-canvas
  arrow nudges (px) and the Settings modal's inputs (px size in free; cell size +
  Column/Row position in grid), all server-driven. Every layout-tweak handler is
  guarded so a hostile/malformed event can't crash or brick the builder.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [actor_uuid: 1, actor_opts: 1, user_role_uuids: 1]

  alias PhoenixKitDashboards.Breakpoints
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  # How often the host checks whether any live widget is due for a refresh.
  @refresh_tick_ms 1000

  # Minimum pixel-canvas widget size (mirrors the context's px clamp).
  @free_min_px 60
  # px a free-mode arrow-nudge moves a widget (the no-JS move fallback).
  @free_nudge_px 10

  @impl true
  def mount(_params, _session, socket) do
    # Safety net: reveal the grid at the default tier if the DashboardBreakpoint
    # hook never reports (JS present but the hook/asset failed) — a stuck-invisible
    # dashboard is worse than the default tier. This must NOT race a slow-but-
    # working load (cold asset cache, heavy widget queries): losing that race
    # flashes the desktop tier before the detected one snaps in. A no-JS browser
    # is revealed instantly by the <noscript> style, so this timer only serves
    # the broken-asset case — it can afford to be generous.
    if connected?(socket), do: Process.send_after(self(), :reveal_grid_fallback, 4000)

    {:ok,
     socket
     |> assign(:catalog, Registry.list_for_scope(socket.assigns[:phoenix_kit_current_scope]))
     |> assign(:show_catalog, true)
     |> assign(:settings_instance, nil)
     # Which breakpoint the grid builder is editing. On connect the
     # DashboardBreakpoint hook detects the tier that best fits the screen (once)
     # and it stays there; the grid is hidden until `detected?` so there's no
     # wrong-tier flash. `bp_manual?` locks it once the user picks a tab.
     |> assign(:active_bp, Breakpoints.default())
     |> assign(:detected?, false)
     |> assign(:bp_manual?, false)
     # The viewer's own screen tier (from the detect hook), so we can tell when the
     # active view is a different size (shown scaled) vs the viewer's own size.
     |> assign(:screen_bp, Breakpoints.default())
     # True when the active view isn't the viewer's own size (drives the "scaled to
     # fit" banner). The grid is always fit-scaled + editable regardless.
     |> assign(:scaled?, false)
     |> assign(:refresh_at, %{})
     |> assign(:refresh_scheduled?, false)}
  end

  @impl true
  def handle_params(%{"uuid" => uuid}, _uri, socket) do
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

  @impl true
  def handle_event("toggle_catalog", _params, socket) do
    {:noreply, update(socket, :show_catalog, &(!&1))}
  end

  @impl true
  def handle_event("add_widget", %{"key" => key}, socket) when is_binary(key) do
    added(socket, Dashboards.add_widget(socket.assigns.dashboard, key, actor_opts(socket)))
  end

  # A catalog entry dragged out and dropped on a grid cell (DashboardCatalogDrag).
  # x/y are 0-based cells for the active bp; the context clamps + refuses an
  # occupied spot (the hook only offers free cells).
  @impl true
  def handle_event("add_widget_at", %{"key" => key, "x" => x, "y" => y}, socket)
      when is_binary(key) do
    added(
      socket,
      Dashboards.add_widget_at(
        socket.assigns.dashboard,
        key,
        socket.assigns.active_bp,
        to_i(x),
        to_i(y),
        actor_opts(socket)
      )
    )
  end

  # A catalog entry dropped on the pixel canvas at exact px.
  @impl true
  def handle_event("add_widget_px", %{"key" => key, "fx" => fx, "fy" => fy}, socket)
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

  @impl true
  def handle_event("remove_widget", %{"id" => instance_id}, socket) do
    apply_layout(
      socket,
      Dashboards.remove_widget(socket.assigns.dashboard, instance_id, actor_opts(socket))
    )
  end

  # Pushed by the DashboardGridDrag hook when a widget is dropped on a new cell
  # (the active bp). x/y are 0-based grid cells; the context clamps to the tier
  # and refuses an occupied spot (the hook never offers one — stale/crafted
  # events only, so the error is a silent no-op).
  @impl true
  def handle_event("move_widget_grid", %{"id" => id, "x" => x, "y" => y}, socket)
      when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.place_widget_grid(
        socket.assigns.dashboard,
        id,
        socket.assigns.active_bp,
        to_i(x),
        to_i(y)
      )
    )
  end

  # Legacy/no-JS re-pack: set the given id order as the reading order and pack
  # the widgets compactly in it (kept server-side; the drag hook places cells
  # directly via move_widget_grid).
  @impl true
  def handle_event("reorder_widgets", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    case Dashboards.reorder_widgets(
           socket.assigns.dashboard,
           socket.assigns.active_bp,
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

  # Manually pick a size to view/edit. It's editable at any size (fit-scaled);
  # `scaled?` (≠ the viewer's own size) just drives the banner. Locks off viewport
  # detection.
  @impl true
  def handle_event("set_bp", %{"bp" => bp}, socket) do
    if Breakpoints.valid?(bp) do
      {:noreply,
       socket
       |> assign(:active_bp, bp)
       |> assign(:scaled?, bp != socket.assigns.screen_bp)
       |> assign(:bp_manual?, true)
       |> assign(:detected?, true)}
    else
      {:noreply, socket}
    end
  end

  # The tier that best fits the screen, from the DashboardBreakpoint hook on connect.
  # We show a DESIGNED view (this tier if designed, else the nearest one scaled to
  # fit) — never a freshly-derived layout. Records the home tier on a brand-new
  # dashboard. Applied once, until the user manually picks a tab.
  @impl true
  def handle_event("detect_bp", %{"bp" => screen_bp}, socket) do
    cond do
      not Breakpoints.valid?(screen_bp) ->
        {:noreply, assign(socket, :detected?, true)}

      # The user already tapped a size before this arrived — keep their choice, but
      # still record their real screen so `scaled?` (view ≠ their size) is correct.
      socket.assigns.bp_manual? ->
        {:ok, dashboard} = Dashboards.put_home_bp(socket.assigns.dashboard, screen_bp)

        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:screen_bp, screen_bp)
         |> assign(:scaled?, socket.assigns.active_bp != screen_bp)
         |> assign(:detected?, true)}

      true ->
        {:ok, dashboard} = Dashboards.put_home_bp(socket.assigns.dashboard, screen_bp)
        active_bp = Dashboards.display_bp(dashboard, screen_bp)
        scaled? = active_bp != screen_bp

        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:screen_bp, screen_bp)
         |> assign(:active_bp, active_bp)
         |> assign(:scaled?, scaled?)
         # On a small screen the catalog floats over the grid, so start it closed
         # (the "Widgets" button opens it to add) — otherwise it blocks the grid.
         |> assign(:show_catalog, not scaled?)
         |> assign(:detected?, true)}
    end
  end

  # Reset the active breakpoint to auto (re-derive from a larger one).
  @impl true
  def handle_event("reset_bp", _params, socket) do
    apply_layout(
      socket,
      Dashboards.reset_breakpoint(socket.assigns.dashboard, socket.assigns.active_bp)
    )
  end

  # Free/pixel-canvas resize (DashboardResize hook, free mode): absolute px size,
  # no snap. Stored under fw/fh; the context clamps to a sane px range.
  @impl true
  def handle_event("resize_widget_to", %{"id" => id, "fw" => fw, "fh" => fh}, socket)
      when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.resize_widget_px(socket.assigns.dashboard, id, to_i(fw), to_i(fh))
    )
  end

  # Grid-mode resize (active breakpoint): the card snaps to the nearest cell on
  # release. The context clamps to the widget type's min/max + the bp's columns.
  @impl true
  def handle_event("resize_widget_to", %{"id" => id, "w" => w, "h" => h}, socket)
      when is_binary(id) do
    with rw when rw >= 1 <- to_i(w),
         rh when rh >= 1 <- to_i(h) do
      apply_layout(
        socket,
        Dashboards.resize_widget(socket.assigns.dashboard, id, socket.assigns.active_bp, rw, rh)
      )
    else
      # A non-positive / unparseable span (only a crafted event) is ignored rather
      # than silently snapping the widget to its minimum size.
      _ -> {:noreply, socket}
    end
  end

  # Free-canvas arrow nudge: shift the widget a few px (the no-JS move fallback).
  @impl true
  def handle_event("move_widget", %{"id" => id, "dir" => dir}, socket) do
    dashboard = socket.assigns.dashboard

    case Enum.find(dashboard.layout, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      inst ->
        {fx, fy, _fw, _fh} = free_geometry(inst)
        {nx, ny} = nudge_px(fx, fy, dir)
        apply_layout(socket, Dashboards.place_widget_px(dashboard, id, nx, ny))
    end
  end

  # Pushed by the DashboardFreeDrag hook after a drag in the free canvas; fx/fy are
  # the absolute px position (no cell snap).
  @impl true
  def handle_event("move_widget_to", %{"id" => id, "fx" => fx, "fy" => fy}, socket)
      when is_binary(id) do
    apply_layout(
      socket,
      Dashboards.place_widget_px(socket.assigns.dashboard, id, to_i(fx), to_i(fy))
    )
  end

  @impl true
  def handle_event("zoom", %{"dir" => dir}, socket) do
    delta = if dir == "in", do: 10, else: -10
    zoom = Dashboard.zoom(socket.assigns.dashboard) + delta
    apply_layout(socket, Dashboards.set_zoom(socket.assigns.dashboard, zoom))
  end

  @impl true
  def handle_event("open_settings", %{"id" => instance_id}, socket) do
    {:noreply, assign(socket, :settings_instance, instance_id)}
  end

  @impl true
  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :settings_instance, nil)}
  end

  @impl true
  def handle_event("save_settings", params, socket) do
    case socket.assigns.settings_instance do
      nil -> {:noreply, socket}
      instance_id -> save_settings(socket, instance_id, params)
    end
  end

  # Ignore any malformed / unexpected event rather than crashing the builder.
  @impl true
  def handle_event(event, _params, socket) do
    Logger.debug("[Dashboards] Unhandled event: #{inspect(event)}")
    {:noreply, socket}
  end

  # No open settings modal (e.g. a double submit racing close_settings) is a
  # no-op — otherwise configure_widget would write the unchanged layout and log
  # a phantom "widget_configured" activity for a nil instance.
  defp save_settings(socket, instance_id, params) do
    attrs =
      %{settings: params["settings"] || %{}}
      |> maybe_put_view(params["view"])
      |> maybe_put_min_override(params["min_override"])

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
        d2 = apply_or_keep(d1, &maybe_place(&1, instance_id, socket.assigns.active_bp, params))
        d3 = apply_or_keep(d2, &maybe_resize(&1, instance_id, socket.assigns.active_bp, params))
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
      |> Dashboards.resolve_items(socket.assigns.active_bp)
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

  # Fallback reveal: if the breakpoint hook never reported, un-hide the grid at the
  # default tier so it can't stay stuck invisible.
  @impl true
  def handle_info(:reveal_grid_fallback, socket) do
    {:noreply, assign(socket, :detected?, true)}
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
    p = placement || Layout.placement(inst, Breakpoints.default())

    [
      id: inst["id"],
      settings: inst["settings"] || %{},
      view: inst["view"],
      size: %{w: p["w"], h: p["h"]},
      scope: scope
    ]
  end

  # Arrow-nudge → new (fx, fy) px on the free canvas (clamped to the top-left).
  defp nudge_px(fx, fy, "left"), do: {max(fx - @free_nudge_px, 0), fy}
  defp nudge_px(fx, fy, "right"), do: {fx + @free_nudge_px, fy}
  defp nudge_px(fx, fy, "up"), do: {fx, max(fy - @free_nudge_px, 0)}
  defp nudge_px(fx, fy, "down"), do: {fx, fy + @free_nudge_px}
  defp nudge_px(fx, fy, _dir), do: {fx, fy}

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

  defp maybe_place(dashboard, _id, _bp, _params), do: {:ok, dashboard}

  # See the render comment: counters daisyUI's modal-open `scrollbar-gutter:
  # stable` (equal specificity, later in the document wins).
  defp gutter_fix_style do
    Phoenix.HTML.raw("<style>:root:has(.modal-open){scrollbar-gutter:auto}</style>")
  end

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
      <%!-- daisyUI's `:root:has(.modal-open)` sets `scrollbar-gutter: stable` with
      the page lock, reserving a ~15px gutter on a page with nothing to scroll —
      the fixed modal backdrop then sizes against the REDUCED containing block and
      leaves an uncovered strip at the right edge (grey in Chrome, white in
      Firefox — looks like a phantom scrollbar). This page is viewport-locked, so
      the gutter is pure artifact: counter it at equal specificity (later in the
      document wins). --%>
      {gutter_fix_style()}
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <div class="flex items-center gap-3">
          <.link navigate={Paths.index()} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <h1 class="text-lg font-semibold">{@dashboard.title}</h1>
          <span class="badge badge-ghost badge-sm">{@dashboard.scope}</span>
        </div>
        <button type="button" phx-click="toggle_catalog" class="btn btn-primary btn-sm">
          <.icon name="hero-squares-plus" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Widgets")}
        </button>
      </div>

      <div class="relative flex flex-1 min-h-0">
        <.grid
          dashboard={@dashboard}
          scope={@phoenix_kit_current_scope}
          active_bp={@active_bp}
          detected={@detected?}
          scaled={@scaled?}
        />
        <%!-- When the grid is fit-scaled (a small screen), the catalog floats as an
        overlay instead of squeezing the grid down to nothing. --%>
        <.catalog_drawer :if={@show_catalog} catalog={@catalog} overlay={@scaled?} />
      </div>

      <.settings_modal
        :if={@settings_instance}
        instance={settings_instance_data(@dashboard, @settings_instance)}
        mode={Dashboard.layout_mode(@dashboard)}
        active_bp={@active_bp}
        grid_placement={Dashboards.resolve_placement(@dashboard, @settings_instance, @active_bp)}
      />
    </div>
    """
  end

  # Mode-aware grid. "grid" is explicit cell placement (x/y anchor + w/h span,
  # DashboardGridDrag); "free" is pixel placement (arrow-nudge move, zoom).
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:active_bp, :string, required: true)
  attr(:detected, :boolean, required: true)
  attr(:scaled, :boolean, required: true)

  defp grid(assigns) do
    mode = Dashboard.layout_mode(assigns.dashboard)

    assigns =
      assigns
      |> assign(:mode, mode)
      |> assign(:zoom, Dashboard.zoom(assigns.dashboard))
      # Grid dashboards stay hidden until the best-fit tier is resolved (no
      # wrong-tier flash — the switcher tab + grid reveal together); pixel has no
      # tier detection, so it's revealed immediately.
      |> assign(:revealed, assigns.detected or mode != "grid")

    ~H"""
    <div class="flex min-w-0 flex-1 flex-col overflow-hidden">
      <div
        :if={@mode == "grid"}
        id="dashboard-bp-detect"
        phx-hook="DashboardBreakpoint"
        data-breakpoints={bp_thresholds()}
        class="hidden"
      >
      </div>

      <%!-- Until the best-fit tier is resolved, show a loading state instead of the
      grid — so the switcher never animates desktop→tv (the grid uses display:none,
      which doesn't prime the tab's colour transition, so it appears already on the
      right tier). <noscript> swaps them for no-JS. --%>
      {Phoenix.HTML.raw(
        ~s(<noscript><style>.pk-grid-loading{display:none!important}.pk-grid-ready{display:flex!important}</style></noscript>)
      )}

      <div class={[
        "pk-grid-loading flex flex-1 flex-col items-center justify-center gap-3 bg-base-200 text-base-content/50",
        @revealed && "hidden"
      ]}>
        <span class="loading loading-spinner loading-lg"></span>
        <p class="text-sm">{Gettext.gettext(PhoenixKitWeb.Gettext, "Fitting the dashboard to your screen…")}</p>
      </div>

      <div class={["pk-grid-ready flex min-h-0 flex-1 flex-col", not @revealed && "hidden"]}>
        <.mode_bar mode={@mode} zoom={@zoom} active_bp={@active_bp} dashboard={@dashboard} />

        <div
          :if={@dashboard.layout == []}
          class="flex flex-1 flex-col items-center justify-center bg-base-200 text-base-content/40"
        >
          <.icon name="hero-squares-plus" class="w-12 h-12" />
          <p class="mt-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Add widgets from the panel on the right.")}</p>
        </div>

        <.grid_mode
          :if={@dashboard.layout != [] and @mode == "grid"}
          dashboard={@dashboard}
          scope={@scope}
          active_bp={@active_bp}
          scaled={@scaled}
        />
        <.free_mode
          :if={@dashboard.layout != [] and @mode == "free"}
          dashboard={@dashboard}
          scope={@scope}
          zoom={@zoom}
        />
      </div>
    </div>
    """
  end

  attr(:mode, :string, required: true)
  attr(:zoom, :integer, required: true)
  attr(:active_bp, :string, required: true)
  attr(:dashboard, :map, required: true)

  defp mode_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-base-300 bg-base-100 px-4 py-1.5">
      <span class="text-xs font-medium text-base-content/50">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Layout")}
      </span>
      <%!-- Pixel: a fixed-type badge. Grid: the breakpoint switcher (type is fixed
      at creation, so there is no grid/free toggle). --%>
      <span :if={@mode == "free"} class="badge badge-ghost badge-sm gap-1">
        <.icon name="hero-arrows-pointing-out" class="w-3.5 h-3.5" />
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Pixel")}
      </span>

      <div :if={@mode == "grid"} class="join">
        <button
          :for={bp <- Breakpoints.all()}
          type="button"
          phx-click="set_bp"
          phx-value-bp={bp.key}
          title={"#{bp.label} · #{bp.cols} cols"}
          class={["join-item btn btn-xs gap-1", @active_bp == bp.key && "btn-primary"]}
        >
          <.icon name={bp_icon(bp.key)} class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">{bp.label}</span>
        </button>
      </div>

      <button
        :if={@mode == "grid" and @active_bp != Dashboards.home_bp(@dashboard) and Dashboards.customized?(@dashboard, @active_bp)}
        type="button"
        phx-click="reset_bp"
        class="btn btn-ghost btn-xs gap-1"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Reset this breakpoint to auto")}
      >
        <.icon name="hero-arrow-path" class="w-3 h-3" />
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Reset")}
      </button>

      <div :if={@mode == "free"} class="ml-auto flex items-center gap-1">
        <span class="text-xs text-base-content/50">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Zoom")}
        </span>
        <button type="button" phx-click="zoom" phx-value-dir="out" class="btn btn-ghost btn-xs btn-square">
          <.icon name="hero-minus" class="w-3 h-3" />
        </button>
        <span class="w-10 text-center text-xs tabular-nums">{@zoom}%</span>
        <button type="button" phx-click="zoom" phx-value-dir="in" class="btn btn-ghost btn-xs btn-square">
          <.icon name="hero-plus" class="w-3 h-3" />
        </button>
      </div>

      <div :if={@mode == "grid"} class="ml-auto flex items-center gap-1">
        <button
          id="dashboard-fullscreen-btn"
          phx-hook="DashboardFullscreen"
          data-target="dashboard-grid-fit"
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Full screen")}
        >
          <.icon name="hero-arrows-pointing-out" class="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
    """
  end

  # Grid mode — the active breakpoint, laid out at its design width and **fit-scaled
  # to the available space** by `DashboardGridFit` (shrink-to-fit; fills in
  # fullscreen). Fully editable at any scale: cell-drag via the module's
  # `DashboardGridDrag` (transform-aware), corner resize via the scale-aware
  # `DashboardResize`. A banner shows when the view isn't the viewer's own size.
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:active_bp, :string, required: true)
  attr(:scaled, :boolean, required: true)

  defp grid_mode(assigns) do
    bp = Breakpoints.get(assigns.active_bp) || Breakpoints.get(Breakpoints.default())

    assigns =
      assign(assigns,
        items: Dashboards.resolve_items(assigns.dashboard, assigns.active_bp),
        cols: bp.cols,
        preview_width: bp.preview_width,
        bp_label: bp.label
      )

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div
        :if={@scaled}
        class="flex items-center gap-2 border-b border-base-300 bg-info/10 px-4 py-1 text-xs text-base-content/60"
      >
        <.icon name="hero-magnifying-glass-minus" class="w-3.5 h-3.5 shrink-0" />
        <span>
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Editing the")} <b>{@bp_label}</b>
          {Gettext.gettext(PhoenixKitWeb.Gettext, "layout, scaled to fit your screen.")}
        </span>
      </div>
      <div
        id="dashboard-grid-fit"
        phx-hook="DashboardGridFit"
        data-design-width={@preview_width}
        class="flex-1 overflow-auto bg-base-200 p-4"
        style="scrollbar-gutter: stable;"
      >
        {Phoenix.HTML.raw(
          ~s(<noscript><style>.pk-grid-scale-canvas{opacity:1 !important}</style></noscript>)
        )}
        <div class="pk-grid-scale-spacer relative mx-auto">
          <div
            class="pk-grid-scale-canvas absolute left-0 top-0"
            style={"width: #{@preview_width}px; transform-origin: top left; opacity: 0;"}
          >
            <div
              id="dashboard-grid"
              phx-hook="DashboardGridDrag"
              data-cols={@cols}
              class="relative grid auto-rows-[8rem] content-start gap-3"
              style={"grid-template-columns: repeat(#{@cols}, minmax(0, 1fr));"}
            >
              <.widget_card
                :for={{inst, placement} <- @items}
                inst={inst}
                placement={placement}
                scope={@scope}
                mode="grid"
                active_bp={@active_bp}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Free/pixel mode — explicit placement on a fixed 12-col canvas, zoomable +
  # scrollable so it keeps exact placement on a small screen (pan/zoom to see).
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:zoom, :integer, required: true)

  defp free_mode(assigns) do
    {cw, ch} = free_canvas_dims(assigns.dashboard.layout)
    assigns = assign(assigns, cw: cw, ch: ch)

    ~H"""
    <div
      id="dashboard-free-fit"
      phx-hook="DashboardFreeFit"
      data-zoom={@zoom}
      class="flex-1 overflow-auto bg-base-200 p-4"
      style="scrollbar-gutter: stable;"
    >
      <%!-- The spacer carries the scaled dimensions so the area scrolls; the
      canvas is scaled in place (transform) by DashboardFreeFit to fill the width.
      It starts hidden so the pre-fit (unscaled) frame never flashes on load; the
      hook reveals it once scaled, and the <noscript> keeps it visible without JS. --%>
      {Phoenix.HTML.raw(
        ~s(<noscript><style>.pk-free-canvas{opacity:1 !important}</style></noscript>)
      )}
      <div class="pk-free-spacer relative" style={"width: #{@cw}px; height: #{@ch}px;"}>
        <div
          id="dashboard-free-grid"
          phx-hook="DashboardFreeDrag"
          class="pk-free-canvas absolute left-0 top-0 rounded border border-dashed border-base-300 bg-base-100/20"
          style={"width: #{@cw}px; height: #{@ch}px; transform-origin: top left; opacity: 0;"}
          data-logical-width={@cw}
          data-logical-height={@ch}
        >
          <.widget_card :for={inst <- @dashboard.layout} inst={inst} scope={@scope} mode="free" />
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
  attr(:active_bp, :string, default: nil)

  defp widget_card(assigns) do
    assigns =
      assigns
      |> assign(:limits, card_limits(assigns))
      |> assign(:hidden?, assigns.mode == "grid" and (assigns.placement || %{})["hidden"] == true)

    ~H"""
    <div
      id={"pk-w-#{@inst["id"]}"}
      phx-hook="DashboardResize"
      class={[
        "sortable-item group/widget relative flex flex-col overflow-hidden rounded-lg border shadow-sm",
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
          <.move_nudge :if={@mode == "free"} id={@inst["id"]} />
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
            data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove this widget?")}
            class="btn btn-ghost btn-xs btn-square text-error"
            title={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
      <div class="min-h-0 flex-1 overflow-auto">
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

  # Arrow-nudge move control (pixel mode).
  attr(:id, :string, required: true)

  defp move_nudge(assigns) do
    ~H"""
    <div class="flex items-center opacity-40 transition-opacity group-hover/widget:opacity-100">
      <button
        :for={{dir, icon} <- [{"left", "hero-chevron-left"}, {"up", "hero-chevron-up"}, {"down", "hero-chevron-down"}, {"right", "hero-chevron-right"}]}
        type="button"
        phx-click="move_widget"
        phx-value-id={@id}
        phx-value-dir={dir}
        class="btn btn-ghost btn-xs btn-square"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Move") <> " " <> dir}
      >
        <.icon name={icon} class="w-3 h-3" />
      </button>
    </div>
    """
  end

  # Resize bounds fed to the DashboardResize hook (as data-*). Grid: the resolved
  # placement span + the widget type's min/max clamped to the active breakpoint's
  # columns. Pixel: the default-bp span (unused by the pixel resize, which uses px).
  defp card_limits(%{mode: "grid", inst: inst, placement: placement, active_bp: bp}) do
    {min, max} = widget_size_bounds(inst)
    cols = Breakpoints.cols(bp)
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

  # Span limits for an instance at a breakpoint (defaulting to the default tier),
  # clamped to that tier's column count — the settings modal passes the active
  # tier so its W input allows a full row there (e.g. 16 on TV, 4 on Phone).
  defp size_limits(inst, bp \\ Breakpoints.default()) do
    cols = Breakpoints.cols(bp)
    p = Layout.placement(inst, bp)
    w = p["w"] |> to_int(4) |> clamp(1, cols)
    h = p["h"] |> to_int(2) |> max(1)
    {min, max} = widget_size_bounds(inst)

    %{w: w, h: h, min_w: min(min.w, cols), max_w: min(max.w, cols), min_h: min.h, max_h: max.h}
  end

  # Breakpoint tier thresholds (largest→smallest) as JSON for the detect hook.
  defp bp_thresholds do
    Breakpoints.all() |> Enum.map(&%{k: &1.key, w: &1.min_width}) |> Jason.encode!()
  end

  # Device icon for the breakpoint switcher.
  defp bp_icon("tv"), do: "hero-tv"
  defp bp_icon("desktop"), do: "hero-computer-desktop"
  defp bp_icon("ipad"), do: "hero-device-tablet"
  defp bp_icon("phone"), do: "hero-device-phone-mobile"
  defp bp_icon(_), do: "hero-squares-2x2"

  # Min/max span for an instance — the min follows its selected view when that
  # view declares one (mirrors the context's clamp); falls back to a permissive
  # range for an instance whose provider is no longer installed.
  defp widget_size_bounds(inst) do
    case Registry.get(inst["widget_key"]) do
      %Widget{} = widget -> {instance_min(inst, widget), widget.max_size}
      _ -> {%{w: 1, h: 1}, %{w: Breakpoints.max_cols(), h: 8}}
    end
  end

  # Mirrors the context: the per-instance override drops the recommended floor.
  defp instance_min(%{"min_override" => true}, _widget), do: %{w: 1, h: 1}
  defp instance_min(inst, widget), do: Widget.min_size_for(widget, inst["view"])

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

  # Free/pixel canvas: absolute px placement — no grid, no snap.
  defp free_placement_style(inst) do
    {fx, fy, fw, fh} = free_geometry(inst)
    "position: absolute; left: #{fx}px; top: #{fy}px; width: #{fw}px; height: #{fh}px;"
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
    placement = assigns.placement || Layout.placement(assigns.inst, Breakpoints.default())
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
      view={@inst["view"]}
      size={%{w: @placement["w"], h: @placement["h"]}}
      scope={@scope}
    />
    """
  end

  attr(:catalog, :list, required: true)
  attr(:overlay, :boolean, default: false)

  # Catalog entries CLICK to add at the first free spot, or DRAG OUT onto the
  # grid/canvas to place directly (DashboardCatalogDrag — a drag starts after a
  # small movement threshold, so plain clicks keep working).
  defp catalog_drawer(assigns) do
    ~H"""
    <div
      id="dashboard-catalog"
      phx-hook="DashboardCatalogDrag"
      class={[
        "w-72 shrink-0 border-l border-base-300 bg-base-100 overflow-auto",
        # When the grid is fit-scaled (small screen), float over it instead of taking
        # flex width and squeezing the grid.
        @overlay && "absolute right-0 top-0 bottom-0 z-20 shadow-xl"
      ]}
    >
      <div class="p-3 border-b border-base-300 text-sm font-semibold">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget catalog")}
      </div>
      <div class="p-2 flex flex-col gap-2">
        <button
          :for={widget <- @catalog}
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
            <span class="block text-sm font-medium">{widget.name}</span>
            <span class="block text-xs text-base-content/50">{widget.description}</span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  # Settings form generated from the widget type's settings_schema.
  attr(:instance, :map, required: true)
  attr(:mode, :string, required: true)
  attr(:active_bp, :string, required: true)
  attr(:grid_placement, :map, default: nil)

  defp settings_modal(assigns) do
    widget = Registry.get(assigns.instance["widget_key"])
    {_fx, _fy, fw, fh} = free_geometry(assigns.instance)

    # Show the RESOLVED size for the tier being edited (matches what's on screen, incl.
    # derived tiers) so saving doesn't overwrite a derived size with the default.
    grid = assigns.grid_placement || Layout.placement(assigns.instance, assigns.active_bp)

    assigns =
      assign(assigns,
        widget: widget,
        limits: size_limits(assigns.instance, assigns.active_bp),
        free?: assigns.mode == "free",
        free_min_px: @free_min_px,
        fw: fw,
        fh: fh,
        grid_w: grid["w"],
        grid_h: grid["h"],
        # 1-based for the form; the placement stores 0-based cells.
        grid_x: (grid["x"] || 0) + 1,
        grid_y: (grid["y"] || 0) + 1,
        cols: Breakpoints.cols(assigns.active_bp),
        max_rows: PhoenixKitDashboards.Grid.max_rows()
      )

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-semibold text-lg mb-3">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget settings")}
          <span :if={@widget} class="text-base-content/50 text-sm">— {@widget.name}</span>
        </h3>

        <form phx-submit="save_settings" class="flex flex-col gap-3">
          <.select
            :if={@widget && @widget.views != []}
            name="view"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
            value={@instance["view"]}
            options={Enum.map(@widget.views, fn v -> {v.name, v.key} end)}
          />
          <div :if={@widget}>
            <span class="label-text text-sm">
              {if @free?,
                do: Gettext.gettext(PhoenixKitWeb.Gettext, "Size (px)"),
                else: Gettext.gettext(PhoenixKitWeb.Gettext, "Size")}
            </span>
            <div :if={@free?} class="flex items-center gap-2">
              <.input
                type="number"
                name="fw"
                value={@fw}
                min={@free_min_px}
                max="4000"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Width")}
              />
              <span class="mt-6 text-base-content/40">×</span>
              <.input
                type="number"
                name="fh"
                value={@fh}
                min={@free_min_px}
                max="4000"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Height")}
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
          <div class="modal-action">
            <button type="button" phx-click="close_settings" class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
            </button>
            <button
              type="submit"
              phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
              class="btn btn-primary btn-sm"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Save")}
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_settings"></div>
    </div>
    """
  end

  # Generated from the widget type's settings_schema. Dynamic field names
  # (`settings[<key>]`) bind via raw name=/value= — core form components accept
  # that (no %FormField{}) and give us the daisyUI 5 wrapper + label wiring.
  attr(:field, :map, required: true)
  attr(:value, :any, required: true)

  defp settings_field(%{field: %{type: :text}} = assigns) do
    ~H"""
    <.textarea name={"settings[#{@field.key}]"} label={@field[:label] || @field.key} value={@value} />
    """
  end

  defp settings_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <.checkbox
      name={"settings[#{@field.key}]"}
      label={@field[:label] || @field.key}
      checked={@value in [true, "true"]}
    />
    """
  end

  defp settings_field(%{field: %{type: :select}} = assigns) do
    ~H"""
    <.select
      name={"settings[#{@field.key}]"}
      label={@field[:label] || @field.key}
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
      label={@field[:label] || @field.key}
      value={@value}
    />
    """
  end
end
