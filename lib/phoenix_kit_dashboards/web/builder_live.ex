defmodule PhoenixKitDashboards.Web.BuilderLive do
  @moduledoc """
  The dashboard builder — a free-form 2D grid (gridstack-style) where widgets are
  dragged, resized, added from the catalog, configured, and removed.

  ## Client/server split

  The grid is driven by a JS hook (`DashboardGrid`) registered on
  `window.PhoenixKitHooks`. External modules cannot inject into the host JS
  build, so the hook + the gridstack library load via an inline `<script>` (the
  PhoenixKit convention). The hook:

  - initializes gridstack over the server-rendered grid items,
  - serializes `{id, x, y, w, h}` on drag/resize and pushes `layout_changed`,
  - re-applies gridstack to newly server-rendered items in `updated()`.

  The server owns the canonical layout (the JSONB `layout` list) and the widget
  list; the client owns interaction. Saved positions round-trip via the
  `gs-x/gs-y/gs-w/gs-h` attributes on the next render.

  > The inline gridstack-from-CDN load is the scaffold default. For production,
  > vendor gridstack into the host's asset pipeline instead.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Registry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:catalog, Registry.list_for_scope(socket.assigns[:phoenix_kit_current_scope]))
     |> assign(:show_catalog, true)
     |> assign(:settings_instance, nil)}
  end

  @impl true
  def handle_params(%{"uuid" => uuid}, _uri, socket) do
    case Dashboards.get(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Dashboard not found.")
         |> push_navigate(to: Paths.index())}

      dashboard ->
        if can_view?(dashboard, socket) do
          {:noreply,
           socket
           |> assign(:dashboard, dashboard)
           |> assign(:page_title, dashboard.title)}
        else
          {:noreply,
           socket
           |> put_flash(:error, "You do not have access to this dashboard.")
           |> push_navigate(to: Paths.index())}
        end
    end
  end

  @impl true
  def handle_event("toggle_catalog", _params, socket) do
    {:noreply, update(socket, :show_catalog, &(!&1))}
  end

  @impl true
  def handle_event("add_widget", %{"key" => key}, socket) do
    case Dashboards.add_widget(socket.assigns.dashboard, key) do
      {:ok, dashboard} -> {:noreply, assign(socket, :dashboard, dashboard)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add widget.")}
    end
  end

  @impl true
  def handle_event("remove_widget", %{"id" => instance_id}, socket) do
    {:ok, dashboard} = Dashboards.remove_widget(socket.assigns.dashboard, instance_id)
    {:noreply, assign(socket, :dashboard, dashboard)}
  end

  # Pushed by the JS hook after a drag/resize. `nodes` is a list of
  # %{"id" => ..., "x" => .., "y" => .., "w" => .., "h" => ..}.
  @impl true
  def handle_event("layout_changed", %{"nodes" => nodes}, socket) do
    layout = merge_positions(socket.assigns.dashboard.layout, nodes)

    case Dashboards.save_layout(socket.assigns.dashboard, layout) do
      {:ok, dashboard} -> {:noreply, assign(socket, :dashboard, dashboard)}
      {:error, _} -> {:noreply, socket}
    end
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
  def handle_event("save_settings", %{"settings" => settings}, socket) do
    instance_id = socket.assigns.settings_instance

    {:ok, dashboard} =
      Dashboards.update_widget_settings(socket.assigns.dashboard, instance_id, settings)

    {:noreply, socket |> assign(:dashboard, dashboard) |> assign(:settings_instance, nil)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Dashboards] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Apply the new x/y/w/h from the client onto the matching layout instances.
  defp merge_positions(layout, nodes) do
    by_id = Map.new(nodes, fn n -> {n["id"], n} end)

    Enum.map(layout, fn inst ->
      case by_id[inst["id"]] do
        nil ->
          inst

        node ->
          inst
          |> Map.put("x", node["x"])
          |> Map.put("y", node["y"])
          |> Map.put("w", node["w"])
          |> Map.put("h", node["h"])
      end
    end)
  end

  defp can_view?(dashboard, socket) do
    dashboard.scope == "system" or dashboard.owner_user_uuid == user_uuid(socket)
  end

  defp user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp settings_instance_data(dashboard, instance_id) do
    Enum.find(dashboard.layout, &(&1["id"] == instance_id))
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
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

      <div class="flex flex-1 min-h-0">
        <.grid dashboard={@dashboard} scope={@phoenix_kit_current_scope} />
        <.catalog_drawer :if={@show_catalog} catalog={@catalog} />
      </div>

      <.settings_modal
        :if={@settings_instance}
        instance={settings_instance_data(@dashboard, @settings_instance)}
      />
    </div>
    """
  end

  # The gridstack grid. Each layout instance becomes a grid-stack item whose
  # content is the widget's LiveComponent.
  attr(:dashboard, :map, required: true)
  attr(:scope, :any, required: true)

  defp grid(assigns) do
    ~H"""
    <div class="flex-1 overflow-auto p-4 bg-base-200">
      <div
        :if={@dashboard.layout == []}
        class="flex flex-col items-center justify-center h-full text-base-content/40"
      >
        <.icon name="hero-squares-plus" class="w-12 h-12" />
        <p class="mt-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Add widgets from the panel on the right.")}</p>
      </div>

      <div id="dashboard-grid" phx-hook="DashboardGrid" phx-update="ignore" class="grid-stack">
        <div
          :for={inst <- @dashboard.layout}
          class="grid-stack-item"
          gs-id={inst["id"]}
          gs-x={inst["x"]}
          gs-y={inst["y"]}
          gs-w={inst["w"]}
          gs-h={inst["h"]}
        >
          <div class="grid-stack-item-content">
            <div class="relative h-full">
              <div class="absolute top-1 right-1 z-10 flex gap-1">
                <button
                  type="button"
                  phx-click="open_settings"
                  phx-value-id={inst["id"]}
                  class="btn btn-ghost btn-xs btn-circle"
                  title={Gettext.gettext(PhoenixKitWeb.Gettext, "Settings")}
                >
                  <.icon name="hero-cog-6-tooth" class="w-3 h-3" />
                </button>
                <button
                  type="button"
                  phx-click="remove_widget"
                  phx-value-id={inst["id"]}
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  title={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </div>
              <.widget_body inst={inst} scope={@scope} />
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- Inline gridstack + hook. The scaffold default; vendor gridstack for production. --%>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/gridstack@10/dist/gridstack.min.css" />
    <script src="https://cdn.jsdelivr.net/npm/gridstack@10/dist/gridstack-all.js">
    </script>
    <script>
      window.PhoenixKitHooks = window.PhoenixKitHooks || {};
      window.PhoenixKitHooks.DashboardGrid = {
        mounted() { this.init(); },
        updated() { this.sync(); },
        destroyed() { if (this.grid) this.grid.destroy(false); },
        init() {
          const start = () => {
            if (!window.GridStack) { return setTimeout(start, 50); }
            this.grid = GridStack.init({ column: 12, cellHeight: 90, margin: 8 }, this.el);
            const push = () => {
              const nodes = this.grid.save(false).map(n => ({
                id: n.id, x: n.x, y: n.y, w: n.w, h: n.h
              }));
              this.pushEvent("layout_changed", { nodes });
            };
            this.grid.on("change", push);
          };
          start();
        },
        // Re-register any server-added items that gridstack isn't tracking yet.
        sync() {
          if (!this.grid) { return this.init(); }
          this.el.querySelectorAll(".grid-stack-item").forEach(el => {
            if (!el.gridstackNode) { this.grid.makeWidget(el); }
          });
        }
      };
    </script>
    """
  end

  # Resolve the widget type for an instance and render its LiveComponent.
  attr(:inst, :map, required: true)
  attr(:scope, :any, required: true)

  defp widget_body(assigns) do
    assigns = assign(assigns, :widget, Registry.get(assigns.inst["widget_key"]))

    ~H"""
    <div :if={is_nil(@widget)} class="card bg-base-100 h-full">
      <div class="card-body p-4 text-sm text-base-content/50">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Unknown widget")}: {@inst["widget_key"]}
      </div>
    </div>
    <.live_component
      :if={@widget}
      module={@widget.component}
      id={@inst["id"]}
      settings={@inst["settings"] || %{}}
      scope={@scope}
    />
    """
  end

  attr(:catalog, :list, required: true)

  defp catalog_drawer(assigns) do
    ~H"""
    <div class="w-72 shrink-0 border-l border-base-300 bg-base-100 overflow-auto">
      <div class="p-3 border-b border-base-300 text-sm font-semibold">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget catalog")}
      </div>
      <div class="p-2 flex flex-col gap-2">
        <button
          :for={widget <- @catalog}
          type="button"
          phx-click="add_widget"
          phx-value-key={widget.key}
          class="text-left p-2 rounded hover:bg-base-200 flex gap-2 items-start"
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

  defp settings_modal(assigns) do
    widget = Registry.get(assigns.instance["widget_key"])
    assigns = assign(assigns, :widget, widget)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-semibold text-lg mb-3">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Widget settings")}
          <span :if={@widget} class="text-base-content/50 text-sm">— {@widget.name}</span>
        </h3>

        <form phx-submit="save_settings" class="flex flex-col gap-3">
          <.settings_field
            :for={field <- (@widget && @widget.settings_schema) || []}
            field={field}
            value={Map.get(@instance["settings"] || %{}, field.key)}
          />
          <div class="modal-action">
            <button type="button" phx-click="close_settings" class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Save")}
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_settings"></div>
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:value, :any, required: true)

  defp settings_field(%{field: %{type: :text}} = assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text">{@field[:label] || @field.key}</span>
      <textarea name={"settings[#{@field.key}]"} class="textarea textarea-bordered">{@value}</textarea>
    </label>
    """
  end

  defp settings_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <label class="label cursor-pointer justify-start gap-2">
      <input type="hidden" name={"settings[#{@field.key}]"} value="false" />
      <input
        type="checkbox"
        name={"settings[#{@field.key}]"}
        value="true"
        checked={@value in [true, "true"]}
        class="checkbox checkbox-sm"
      />
      <span class="label-text">{@field[:label] || @field.key}</span>
    </label>
    """
  end

  defp settings_field(%{field: %{type: :select}} = assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text">{@field[:label] || @field.key}</span>
      <select name={"settings[#{@field.key}]"} class="select select-bordered">
        <option :for={opt <- @field[:options] || []} value={opt} selected={to_string(@value) == opt}>
          {opt}
        </option>
      </select>
    </label>
    """
  end

  defp settings_field(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text">{@field[:label] || @field.key}</span>
      <input
        type={if @field.type == :number, do: "number", else: "text"}
        name={"settings[#{@field.key}]"}
        value={@value}
        class="input input-bordered"
      />
    </label>
    """
  end
end
