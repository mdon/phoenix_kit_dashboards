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
      viewable_by?: 2,
      actor_opts: 1,
      scope_label: 1
    ]

  import PhoenixKitDashboards.Web.BuilderComponents

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

  @impl true
  def mount(params, _session, socket) do
    # LIVE SYNC: subscribe to this dashboard's edits so a session viewing it
    # (e.g. a wall TV) re-renders the instant anyone edits it from elsewhere.
    if connected?(socket) and is_binary(params["uuid"]) do
      Dashboards.subscribe(params["uuid"])
    end

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
     # QoL: show the empty grid cells while designing (session-local toggle).
     |> assign(:show_grid_lines, false)}
  end

  @impl true
  def handle_params(%{"uuid" => uuid} = params, _uri, socket) do
    case Dashboards.get(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Dashboard not found."))
         |> push_navigate(to: Paths.index())}

      dashboard ->
        if viewable_by?(dashboard, socket) do
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
             gettext("You do not have access to this dashboard.")
           )
           |> push_navigate(to: Paths.index())}
        end
    end
  end

  # Tab visibility (DashboardVisibility hook): pause the refresh loop while the
  # tab is hidden, snap-to-now when it returns — so a backgrounded tab doesn't
  # accumulate a backlog of clock updates that fast-forwards on refocus. These
  # aren't mutations, so they bypass the re-fetching dispatcher below.
  @impl true
  def handle_event("refresh_pause", _params, socket) do
    Process.put(:pk_refresh_paused, true)
    {:noreply, socket}
  end

  def handle_event("refresh_resume", _params, socket) do
    Process.put(:pk_refresh_paused, false)
    # Every widget becomes due, so the next tick refreshes them all to the
    # CURRENT time at once (a clean snap, not a sweep through buffered ticks).
    Process.put(:pk_refresh_at, %{})
    # Kick an immediate tick only if the loop isn't already pending (a quick
    # hide→show still has its in-flight tick, which now sees paused? = false).
    # Latch BEFORE sending — events are processed one-at-a-time, so spamming
    # `refresh_resume` would otherwise enqueue N ticks that each spawn their own
    # self-rescheduling loop (a self-DoS).
    unless Process.get(:pk_refresh_scheduled, false) do
      Process.put(:pk_refresh_scheduled, true)
      send(self(), :refresh_tick)
    end

    {:noreply, socket}
  end

  # EVERY other event operates on a FRESH dashboard: builder sessions are
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
         |> put_flash(:error, gettext("Dashboard not found."))
         |> push_navigate(to: Paths.index())}

      dashboard ->
        if viewable_by?(dashboard, socket) do
          socket = assign(socket, :dashboard, dashboard)
          do_handle_event(event, params, ensure_active_layout(socket))
        else
          # Access is re-checked against the FRESH dashboard row, so a scope
          # flip (e.g. re-scoped to someone else's personal) fails closed here.
          # NOTE: the actor's roles/permissions come from the mount-time scope
          # (core's on_mount doesn't re-run per event), so a role/permission
          # REVOCATION only takes effect on the next remount — not mid-session.
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("You do not have access to this dashboard.")
           )
           |> push_navigate(to: Paths.index())}
        end
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
    with_offered_widget(socket, key, fn socket ->
      added(socket, Dashboards.add_widget(socket.assigns.dashboard, key, actor_opts(socket)))
    end)
  end

  # A catalog entry dragged out and dropped on a grid cell (DashboardCatalogDrag).
  # x/y are 0-based cells for the active layout_id; the context clamps + refuses an
  # occupied spot (the hook only offers free cells).
  defp do_handle_event("add_widget_at", %{"key" => key, "x" => x, "y" => y}, socket)
       when is_binary(key) do
    with_offered_widget(socket, key, fn socket ->
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
    end)
  end

  # A catalog entry dropped on the pixel canvas at exact px.
  defp do_handle_event("add_widget_px", %{"key" => key, "fx" => fx, "fy" => fy}, socket)
       when is_binary(key) do
    with_offered_widget(socket, key, fn socket ->
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
    end)
  end

  defp do_handle_event("remove_widget", %{"id" => instance_id}, socket) do
    # Removing the widget whose settings modal is open must close the modal —
    # the next render would otherwise crash resolving the gone instance.
    socket =
      if socket.assigns.settings_instance == instance_id,
        do: assign(socket, :settings_instance, nil),
        else: socket

    apply_layout(
      socket,
      Dashboards.remove_widget(socket.assigns.dashboard, instance_id, actor_opts(socket))
    )
  end

  # Pushed by the DashboardGridDrag hook when a widget is dropped on a new cell
  # (the active layout_id). x/y are 0-based grid cells; the context clamps to the layout
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
           gettext("A dashboard needs at least one layout.")
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
  # release. The context clamps to the widget type's min/max + the layout_id's columns.
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
    # Only for a widget that exists — a crafted/stale id must not park a
    # dangling id in the assign (the modal render would crash on nil).
    if settings_instance_data(socket.assigns.dashboard, instance_id) do
      {:noreply, assign(socket, :settings_instance, instance_id)}
    else
      {:noreply, socket}
    end
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

  # Placing a widget requires the SAME gate that decides what the catalog
  # offers — a crafted event must not persist a widget whose module the
  # viewer's scope lacks (the placement would outlive a later permission
  # grant and already pollutes the audit log). Unknown keys fall through to
  # the context's {:error, :unknown_widget} flash.
  defp with_offered_widget(socket, key, fun) do
    case Registry.get(key) do
      %Widget{} = widget ->
        if Registry.visible_for_scope?(widget, socket.assigns[:phoenix_kit_current_scope]) do
          fun.(socket)
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("This widget is not available to you.")
           )}
        end

      nil ->
        fun.(socket)
    end
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
    # layout's placement); everything else stays instance-level. `is_binary`
    # guards a crafted non-string `view` (set_layout_view/4 requires a binary).
    socket =
      if grid? and is_binary(params["view"]) and params["view"] != "" do
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

      {:error, :stale} ->
        {:noreply, resync(socket)}

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
  # All refresh-loop state (the latch, the paused flag, the per-widget "last
  # refreshed" map) lives in the PROCESS DICTIONARY, never socket assigns — an
  # assign would dirty the socket every tick and force a full-page re-render
  # (re-running the admin layout's uncached settings query; in dev that can hit
  # a code-reload window → crash). A tick only `send_update`s the due widgets.
  def handle_info(:refresh_tick, socket) do
    cond do
      # Tab hidden (the client paused us): go dormant. Otherwise the server keeps
      # pushing a clock update every second while the tab is backgrounded, the
      # browser buffers them all, and they replay in a burst ("fast-forward") on
      # refocus. `refresh_resume` restarts the loop with an immediate snap-to-now.
      Process.get(:pk_refresh_paused, false) ->
        Process.put(:pk_refresh_scheduled, false)
        {:noreply, socket}

      any_live_widget?(socket.assigns.dashboard) ->
        now = System.monotonic_time(:millisecond)
        scope = socket.assigns[:phoenix_kit_current_scope]

        # Resolve placements once so a refreshed widget's `size` matches what it
        # first rendered with (no size flip on refresh).
        placements =
          socket.assigns.dashboard
          |> Dashboards.resolve_items(socket.assigns.active_layout)
          |> Map.new(fn {item, p} -> {item["id"], p} end)

        socket.assigns.dashboard.layout
        |> Enum.reduce(
          Process.get(:pk_refresh_at, %{}),
          &refresh_due(&1, &2, now, scope, placements)
        )
        |> then(&Process.put(:pk_refresh_at, &1))

        Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
        Process.put(:pk_refresh_scheduled, true)
        # Socket UNCHANGED → no parent re-render; only the send_update'd widgets.
        {:noreply, socket}

      true ->
        # No live widget left — let the loop stop; re-adding one restarts it.
        Process.put(:pk_refresh_scheduled, false)
        {:noreply, socket}
    end
  end

  # LIVE SYNC: another session edited this dashboard — adopt the pushed state
  # (it's the authoritative post-write struct). Re-check access (it may have
  # been re-scoped away), re-validate the active layout (it may have been
  # deleted remotely), and keep the live-refresh loop honest.
  @impl true
  def handle_info({:dashboard_updated, dashboard}, socket) do
    if dashboard.uuid == socket.assigns.dashboard.uuid do
      if viewable_by?(dashboard, socket) do
        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> ensure_active_layout()
         |> maybe_schedule_refresh()}
      else
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("You no longer have access to this dashboard.")
         )
         |> push_navigate(to: Paths.index())}
      end
    else
      {:noreply, socket}
    end
  end

  # LIVE SYNC: the dashboard was deleted out from under this session.
  @impl true
  def handle_info({:dashboard_deleted, uuid}, socket) do
    if uuid == socket.assigns.dashboard.uuid do
      {:noreply,
       socket
       |> put_flash(:info, gettext("This dashboard was deleted."))
       |> push_navigate(to: Paths.index())}
    else
      {:noreply, socket}
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
    if connected?(socket) and not Process.get(:pk_refresh_scheduled, false) and
         not Process.get(:pk_refresh_paused, false) and
         any_live_widget?(socket.assigns.dashboard) do
      Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
      Process.put(:pk_refresh_scheduled, true)
    end

    socket
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
  # the active layout's resolved placement (matching the first render), or the default
  # layout when unavailable.
  defp widget_update_assigns(inst, scope, placement) do
    # Grid mode passes the resolved placement; PIXEL mode derives cells from
    # the real px box (fw/fh ÷ the 25px cell) — falling back to the grid
    # defaults would hand a 100×100px note the size of a 400×200 box and its
    # content-aware type would overflow.
    p = placement || pixel_cells(inst)

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

  defp apply_layout(socket, {:error, :stale}), do: {:noreply, resync(socket)}
  defp apply_layout(socket, {:error, _}), do: {:noreply, socket}

  # Shared add-widget outcome: assign + restart the refresh loop if the new
  # widget is a live one; flash on failure.
  defp added(socket, {:ok, dashboard}) do
    {:noreply, socket |> assign(:dashboard, dashboard) |> maybe_schedule_refresh()}
  end

  defp added(socket, {:error, :stale}), do: {:noreply, resync(socket)}

  defp added(socket, {:error, _}) do
    {:noreply, put_flash(socket, :error, gettext("Could not add widget."))}
  end

  # A concurrent session wrote first (optimistic-lock miss): reload the current
  # state so the user is editing live truth, not their stale snapshot. The
  # PubSub push carries the same state — this just makes the recovery immediate.
  defp resync(socket) do
    case Dashboards.get(socket.assigns.dashboard.uuid) do
      nil ->
        socket
        |> put_flash(:error, gettext("Dashboard not found."))
        |> push_navigate(to: Paths.index())

      dashboard ->
        socket
        |> assign(:dashboard, dashboard)
        |> ensure_active_layout()
        |> put_flash(
          :info,
          gettext("Reloaded — this dashboard was just edited elsewhere.")
        )
    end
  end

  # The Settings modal's size inputs (server-driven resize fallback). Free mode
  # submits px (fw/fh); grid mode submits cell spans (w/h). Blank values leave the
  # size untouched; the context clamps to the widget/px min/max.
  defp maybe_resize(dashboard, id, _bp, %{"fw" => fw, "fh" => fh}) when fw != "" and fh != "" do
    Dashboards.resize_widget_px(dashboard, id, to_i(fw), to_i(fh))
  end

  defp maybe_resize(dashboard, id, layout_id, %{"w" => w, "h" => h}) when w != "" and h != "" do
    Dashboards.resize_widget(dashboard, id, layout_id, to_i(w), to_i(h))
  end

  defp maybe_resize(dashboard, _id, _bp, _params), do: {:ok, dashboard}

  # The Settings modal's grid Column/Row inputs (the no-JS placement fallback).
  # Displayed 1-based; the placement is 0-based cells.
  defp maybe_place(dashboard, id, layout_id, %{"x" => x, "y" => y}) when x != "" and y != "" do
    Dashboards.place_widget_grid(dashboard, id, layout_id, to_i(x) - 1, to_i(y) - 1)
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

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Viewport-bounded (100dvh minus core's h-16 admin header), NOT h-full:
    the admin layout's column is content-sized, so h-full resolves to auto and
    any content growth (a fit-rescale, a widget near the fold) would grow the
    PAGE and pop a window scrollbar — the builder is app-like, its grid/canvas
    panes scroll internally instead. --%>
    <div id="dashboard-builder" phx-hook="DashboardVisibility" class="flex h-[calc(100dvh-4rem)] flex-col">
      <%!-- FULLSCREEN = DISPLAY MODE: the Full-screen button natively
      fullscreens the canvas pane, so the header/layout bar/catalog (outside it)
      already vanish. These rules strip the remaining per-widget EDIT chrome —
      the drag bar, resize grip, guides, and editor caption — so a wall TV shows
      a clean dashboard, not an editor. (Esc exits; edits still flow in live.) --%>
      <style>
        :fullscreen .pk-widget-chrome,
        :fullscreen .pk-resize-handle,
        :fullscreen .pk-grid-caption,
        :fullscreen .pk-empty-hint {
          display: none !important;
        }
        :fullscreen #dashboard-grid {
          background-image: none !important;
        }
        /* Idle-cursor: DashboardFullscreen toggles pk-cursor-idle after a spell
           of no pointer movement — hide the arrow across the whole subtree
           (overriding any child cursor), YouTube-style. */
        :fullscreen.pk-cursor-idle,
        :fullscreen.pk-cursor-idle * {
          cursor: none !important;
        }
      </style>
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
            title={gettext("Dashboard settings")}
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
            title={gettext("Full screen")}
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
            {gettext("Widgets")}
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
        :if={@settings_instance && settings_instance_data(@dashboard, @settings_instance)}
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

  # to_i/1 is the event-param coercion (rounds, default 0) for live drag/resize
  # payloads. (Stored-geometry to_int/clamp moved with the render helpers to
  # BuilderComponents — the events below use to_i.)
  defp to_i(v) when is_integer(v), do: v
  defp to_i(v) when is_float(v), do: round(v)

  defp to_i(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_i(_v), do: 0
end
