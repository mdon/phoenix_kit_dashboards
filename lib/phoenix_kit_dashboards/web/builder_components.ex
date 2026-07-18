defmodule PhoenixKitDashboards.Web.BuilderComponents do
  @moduledoc """
  Presentational function components + their render-only helpers for the
  dashboard builder — extracted verbatim from `Web.BuilderLive` (review #4) so
  the LiveView keeps the mount/event/refresh logic and this module owns the
  ~900 lines of HEEx. `BuilderLive` `import`s this module, so its `render/1`
  resolves `<.grid>` / `<.catalog_drawer>` / `<.settings_modal>` here.

  No behavior change: the moved helpers call `Lattice.to_int/2` / `Lattice.clamp/3`
  directly (BuilderLive keeps its own `to_i/1`, an unrelated event-param
  rounder for live drag/resize payloads — not a `Lattice` wrapper — avoiding a
  mutual import).
  """
  use PhoenixKitWeb, :html

  import PhoenixKitDashboards.Web.Helpers, only: [translate_catalog: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Sizing
  alias PhoenixKitDashboards.Widget

  # Pixel-canvas widget size bounds (px) — sourced from Lattice, matching
  # BuilderLive (the moved render helpers reference these).
  @free_min_px Lattice.free_min_px()
  @free_max_px Lattice.free_max_px()

  # Mode-aware grid. "grid" is explicit cell placement (x/y anchor + w/h span,
  # DashboardGridDrag); "free" is exact-px placement (DashboardFreeDrag,
  # z-order restack).
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:active_layout, :string, required: true)
  attr(:renaming_layout, :string, default: nil)
  attr(:show_grid_lines, :boolean, required: true)

  def grid(assigns) do
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
          class="pk-empty-hint flex flex-1 flex-col items-center justify-center bg-base-200 text-base-content/40"
        >
          <.icon name="hero-squares-plus" class="w-12 h-12" />
          <p class="mt-2">{gettext("Add widgets from the panel on the right.")}</p>
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
  def layout_bar(assigns) do
    assigns = assign(assigns, :entries, Dashboards.layouts(assigns.dashboard))

    ~H"""
    <div class="flex items-center gap-2 border-b border-base-300 bg-base-100 px-4 py-1.5">
      <%!-- overflow-y-hidden: overflow-x-auto forces the OTHER axis to compute
      as auto too, so daisyUI's .btn:active 0.5px press-shift would otherwise
      pop a scrollbar for as long as a tab is held down. --%>
      <div
        role="tablist"
        aria-label={gettext("Dashboard layouts")}
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
          title={gettext("Add a layout (copies the current one)")}
          aria-label={gettext("Add layout")}
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
          title={gettext("Layout settings")}
          aria-label={gettext("Layout settings")}
        >
          <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
        </button>
        <div tabindex="0" class="dropdown-content z-30 w-64 rounded-box bg-base-100 p-2 shadow">
          <ul class="menu p-0">
            <li>
              <button type="button" phx-click="start_rename_layout" phx-value-id={@active_layout}>
                <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                {gettext("Rename")}
              </button>
            </li>
            <li :if={length(@entries) > 1}>
              <button
                type="button"
                phx-click="delete_layout"
                phx-value-id={@active_layout}
                data-confirm={
                  gettext("Delete this layout? Its placements are removed; the widgets stay available in the other layouts."
                  )
                }
                class="text-error"
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
                {gettext("Delete")}
              </button>
            </li>
          </ul>

          <div class="divider my-1"></div>

          <div class="px-1 pb-1.5 text-xs font-medium text-base-content/50">
            {gettext("Grid size (columns × rows)")}
          </div>
          <form id="grid-dims" phx-change="set_dims" class="flex items-center gap-2 px-1">
            <input
              type="number"
              name="cols"
              value={Dashboards.grid_cols(@dashboard, @active_layout)}
              min={Lattice.min_dim()}
              max={Lattice.max_dim()}
              class="input input-sm w-20 text-center tabular-nums"
              aria-label={gettext("Columns")}
            />
            <span class="text-base-content/40">×</span>
            <input
              type="number"
              name="rows"
              value={Dashboards.grid_rows(@dashboard, @active_layout)}
              min={Lattice.min_dim()}
              max={Lattice.max_dim()}
              class="input input-sm w-20 text-center tabular-nums"
              aria-label={gettext("Rows")}
            />
          </form>
          <button
            id="dashboard-fit-screen"
            type="button"
            phx-hook="DashboardFitScreen"
            class="btn btn-ghost btn-sm mt-1.5 w-full justify-start gap-2"
            title={
              gettext("Resize this layout's grid to match the screen you're viewing on"
              )
            }
          >
            <.icon name="hero-viewfinder-circle" class="w-4 h-4" />
            {gettext("Fit this screen")}
          </button>
        </div>
      </div>

      <div class="ml-auto flex items-center gap-3">
        <label class="flex cursor-pointer items-center gap-1.5">
          <span class="text-xs font-medium text-base-content/50">
            {gettext("Show grid")}
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

  def grid_mode(assigns) do
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
          class="pk-empty-hint pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center text-base-content/40"
        >
          <.icon name="hero-squares-plus" class="w-12 h-12" />
          <p class="mt-2">
            {gettext("Add widgets from the panel on the right.")}
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

  def free_mode(assigns) do
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

  def widget_card(assigns) do
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
          "pk-widget-chrome flex cursor-grab touch-none select-none items-center justify-between gap-1",
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
            title={gettext("Bring to front")}
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
            title={gettext("Send to back")}
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
            title={"#{gettext("View")}: #{@view_name} — #{gettext("click to cycle")}"}
          >
            <.icon name="hero-eye" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="open_settings"
            phx-value-id={@inst["id"]}
            class="btn btn-ghost btn-xs btn-square"
            title={gettext("Settings")}
          >
            <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="remove_widget"
            phx-value-id={@inst["id"]}
            phx-disable-with="…"
            data-confirm={gettext("Remove this widget?")}
            class="btn btn-ghost btn-xs btn-square text-error"
            title={gettext("Remove")}
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
        title={gettext("Drag to resize")}
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
  # columns. Pixel: the default-layout_id span (unused by the pixel resize, which uses px).
  defp card_limits(%{mode: "grid", inst: inst, placement: placement, cols: cols} = assigns) do
    {min, max} = Sizing.bounds(inst, assigns.active_layout)
    cols = cols || 12
    p = placement || %{}

    %{
      w: p["w"] |> Lattice.to_int(4),
      h: p["h"] |> Lattice.to_int(2),
      # Both bounds clamp to the layout's columns — a widget whose global min_w
      # exceeds them (legal, the cap is the largest layout) must not hand the
      # resize hook min > max, or the client would snap to a span the server
      # then rejects down to the column count.
      min_w: min(min.w, cols),
      max_w: min(max.w, cols),
      min_h: min.h,
      max_h: max.h
    }
  end

  defp card_limits(%{inst: inst}), do: size_limits(inst)

  # Span limits for an instance on a layout, clamped to that layout's column
  # count — the settings modal passes the active layout (and its
  # dashboard-resolved column count) so its W input allows a full row there. The
  # default layout_id is only reached from the pixel-mode fallback above, where
  # grid placement is inert: no layout has that id, so Layout.placement/2 falls
  # back to the widget's legacy flat span (pixel resize uses px, not these).
  defp size_limits(inst, layout_id \\ "_pixel_fallback", cols \\ nil) do
    cols = cols || 12
    p = Layout.placement(inst, layout_id)
    w = p["w"] |> Lattice.to_int(4) |> Lattice.clamp(1, cols)
    h = p["h"] |> Lattice.to_int(2) |> max(1)
    {min, max} = Sizing.bounds(inst, layout_id)

    %{w: w, h: h, min_w: min(min.w, cols), max_w: min(max.w, cols), min_h: min.h, max_h: max.h}
  end

  # Grid mode: explicit cell placement — `x`/`y` (0-based, from the resolved
  # placement, which always carries them) anchor the card, spanning `w`×`h`.
  # Span-only fallback (auto flow) kept for a defensive nil placement.
  defp grid_area_style(placement) do
    p = placement || %{}
    w = p["w"] |> Lattice.to_int(4) |> max(1)
    h = p["h"] |> Lattice.to_int(2) |> max(1)

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

  defp grip_title(_mode), do: gettext("Drag to move")

  # Free/pixel canvas: absolute px placement — no grid, no snap. `z` orders
  # deliberately-overlapping widgets (restack_widget).
  defp free_placement_style(inst) do
    {fx, fy, fw, fh} = free_geometry(inst)
    z = Layout.pixel(inst)["z"] |> Lattice.to_int(0)

    "position: absolute; left: #{fx}px; top: #{fy}px; width: #{fw}px; height: #{fh}px; z-index: #{z};"
  end

  # A widget's free-canvas geometry in px, read from its embedded `pixel` map
  # (seeded on add). `Layout.pixel/1` also falls back to legacy flat keys.
  # Values are clamped on READ (not just on the write paths): a tampered/legacy
  # huge stored coord — now that Lattice.to_int also parses numeric strings —
  # must not size a canvas the fit hook can't render (positions cap at
  # @free_max_pos, sizes at @free_max_px).
  defp free_geometry(inst) do
    px = Layout.pixel(inst)
    fx = px["fx"] |> Lattice.to_int(0) |> Lattice.clamp(0, Lattice.free_max_pos())
    fy = px["fy"] |> Lattice.to_int(0) |> Lattice.clamp(0, Lattice.free_max_pos())
    fw = px["fw"] |> Lattice.to_int(@free_min_px) |> Lattice.clamp(@free_min_px, @free_max_px)
    fh = px["fh"] |> Lattice.to_int(@free_min_px) |> Lattice.clamp(@free_min_px, @free_max_px)
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

  # Resolve the widget type for an instance and render its LiveComponent. The
  # widget's `size` is the placement for the layout being viewed (so density-aware
  # widgets adapt), falling back to the default layout when none is given (pixel mode).
  # A placed widget is re-gated by the same visibility rule as the catalog
  # (module enabled + scope permission) — so DISABLING a module immediately
  # stops its widgets rendering/querying (a fresh ModuleRegistry lookup). A
  # scope PERMISSION revocation uses the mount-time scope, so it takes effect
  # on the next remount, not mid-session. The card chrome stays, so the
  # instance can still be removed or moved while unavailable.
  attr(:inst, :map, required: true)
  attr(:scope, :any, required: true)
  attr(:placement, :map, default: nil)

  def widget_body(assigns) do
    # PIXEL mode has no grid placement — derive cells from the real px box so
    # size-aware widgets (the note's content-aware type) see their true box.
    placement = assigns.placement || pixel_cells(assigns.inst)
    widget = Registry.get(assigns.inst["widget_key"])

    assigns =
      assigns
      |> assign(:widget, widget)
      |> assign(:placement, placement)
      |> assign(:available, widget && Registry.visible_for_scope?(widget, assigns.scope))

    ~H"""
    <div :if={is_nil(@widget)} class="card bg-base-100 h-full">
      <div class="card-body p-4 text-sm text-base-content/50">
        {gettext("Unknown widget")}: {@inst["widget_key"]}
      </div>
    </div>
    <div :if={@widget && !@available} class="card bg-base-100 h-full">
      <div class="card-body p-4 items-center justify-center text-center text-sm text-base-content/50">
        <.icon name="hero-lock-closed" class="w-5 h-5" />
        <span>
          {@widget.name} — {gettext("unavailable (module disabled or access restricted)."
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
  def catalog_drawer(assigns) do
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
          {gettext("Widget catalog")}
        </span>
        <button
          type="button"
          phx-click={JS.hide(to: "#dashboard-catalog")}
          class="btn btn-ghost btn-xs btn-square"
          title={gettext("Close")}
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
            title={gettext("Click to add, or drag onto the dashboard")}
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

  defp builtin_label, do: gettext("Built-in")

  # Settings form generated from the widget type's settings_schema.
  attr(:instance, :map, required: true)
  attr(:mode, :string, required: true)
  attr(:active_layout, :string, required: true)
  attr(:grid_placement, :map, default: nil)
  attr(:cols, :integer, required: true)
  attr(:max_rows, :integer, required: true)

  def settings_modal(assigns) do
    widget = Registry.get(assigns.instance["widget_key"])
    {fx, fy, fw, fh} = free_geometry(assigns.instance)

    # Show the RESOLVED size for the layout being edited (matches what's on screen, incl.
    # derived layouts) so saving doesn't overwrite a derived size with the default.
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
        {gettext("Widget settings")}
        <span :if={@widget} class="text-base-content/50 text-sm">
          — {translate_catalog(@widget.name)}
        </span>
      </:title>

      <form id="widget-settings-form" phx-submit="save_settings" class="flex flex-col gap-3">
          <.select
            :if={@widget && @widget.views != []}
            name="view"
            label={gettext("View")}
            value={(@grid_placement || %{})["view"] || @instance["view"]}
            options={Enum.map(@widget.views, fn v -> {translate_catalog(v.name), v.key} end)}
          />
          <div :if={@widget}>
            <span class="label-text text-sm">
              {if @free?,
                do: gettext("Size & position (px)"),
                else: gettext("Size")}
            </span>
            <div :if={@free?} class="grid grid-cols-4 items-end gap-2">
              <.input
                type="number"
                name="fw"
                value={@fw}
                min={@free_min_px}
                max={@free_max_px}
                label={gettext("Width")}
              />
              <.input
                type="number"
                name="fh"
                value={@fh}
                min={@free_min_px}
                max={@free_max_px}
                label={gettext("Height")}
              />
              <.input
                type="number"
                name="fx"
                value={@fx}
                min="0"
                label={gettext("X")}
              />
              <.input
                type="number"
                name="fy"
                value={@fy}
                min="0"
                label={gettext("Y")}
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
                label={gettext("Width")}
              />
              <.input
                type="number"
                name="h"
                value={@grid_h}
                min="1"
                max={@limits.max_h}
                label={gettext("Height")}
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
                label={gettext("Column")}
              />
              <.input
                type="number"
                name="y"
                value={@grid_y}
                min="1"
                max={@max_rows}
                label={gettext("Row")}
              />
            </div>
            <div :if={!@free?} class="mt-2">
              <.checkbox
                name="min_override"
                label={gettext("Allow smaller than recommended")}
                checked={@instance["min_override"] == true}
              />
              <p class="mt-0.5 text-xs text-base-content/50">
                {gettext("Drops this widget's minimum size to 1×1 — it may render cramped below the recommended size."
                )}
              </p>
            </div>
            <p class="mt-1 text-xs text-base-content/50">
              {if @free?,
                do: gettext("Tip: drag the bottom-right corner to resize."),
                else:
                  gettext("Tip: drag the widget by its grip to any cell; drag the bottom-right corner to resize."
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
          {gettext("Cancel")}
        </button>
        <button
          type="submit"
          form="widget-settings-form"
          phx-disable-with={gettext("Saving…")}
          class="btn btn-primary btn-sm"
        >
          {gettext("Save")}
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

  def settings_field(%{field: %{type: :text}} = assigns) do
    ~H"""
    <.textarea name={"settings[#{@field.key}]"} label={translate_catalog(@field[:label]) || @field.key} value={@value} />
    """
  end

  def settings_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <.checkbox
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      checked={@value in [true, "true"]}
    />
    """
  end

  def settings_field(%{field: %{type: :select}} = assigns) do
    ~H"""
    <.select
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      value={@value}
      options={@field[:options] || []}
    />
    """
  end

  def settings_field(assigns) do
    ~H"""
    <.input
      type={if @field.type == :number, do: "number", else: "text"}
      name={"settings[#{@field.key}]"}
      label={translate_catalog(@field[:label]) || @field.key}
      value={@value}
    />
    """
  end

  def pixel_cells(inst) do
    px = Layout.pixel(inst)

    %{
      "w" => max(round(Lattice.to_int(px["fw"], 0) / Lattice.cell()), 1),
      "h" => max(round(Lattice.to_int(px["fh"], 0) / Lattice.cell()), 1)
    }
  end

  def settings_instance_data(dashboard, instance_id) do
    Enum.find(dashboard.layout, &(&1["id"] == instance_id))
  end
end
