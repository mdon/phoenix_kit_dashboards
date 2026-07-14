defmodule PhoenixKitDashboards.Web.DashboardsLive do
  @moduledoc """
  Manage page — lists the current user's personal dashboards, all shared
  (system) dashboards, and any `role`-scoped dashboards for the user's roles.
  Creating and editing metadata happens on the dedicated form page
  (`DashboardFormLive`); from here admins open the builder, **clone** any
  visible dashboard into a private editable copy, edit, or delete (own
  personal ones + shared/role ones).

  Admin layout, sidebar, and the `@phoenix_kit_current_user` / `_scope` assigns
  are injected by PhoenixKit's on_mount hooks.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [
      actor_uuid: 1,
      actor_opts: 1,
      user_role_uuids: 1,
      scope_label: 1
    ]

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Schemas.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboards"))
     |> load_dashboards()}
  end

  @impl true
  def handle_event("clone", %{"uuid" => uuid}, socket) do
    with %{} = dashboard <- Dashboards.get(uuid),
         true <- can_view?(dashboard, socket),
         {:ok, clone} <- Dashboards.clone(dashboard, actor_uuid(socket), actor_opts(socket)) do
      {:noreply, push_navigate(socket, to: Paths.builder(clone.uuid))}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not clone dashboard.")
         )}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %{} = dashboard <- Dashboards.get(uuid),
         true <- can_delete?(dashboard, socket),
         {:ok, _} <- Dashboards.delete(dashboard, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard deleted."))
       |> load_dashboards()}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not delete dashboard.")
         )}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Dashboards] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_dashboards(socket) do
    dashboards = Dashboards.list_for_user(actor_uuid(socket), user_role_uuids(socket))

    socket
    |> assign(:dashboards, dashboards)
    |> assign(:current_user_uuid, actor_uuid(socket))
  end

  # View: own personal · any shared/system · role dashboards for the user's roles.
  # Shared with the builder via the context so the two never disagree.
  defp can_view?(dashboard, socket) do
    Dashboards.visible_to?(dashboard, actor_uuid(socket), user_role_uuids(socket))
  end

  # Delete: own personal ones; any admin on this page can delete shared/role
  # ones (the admin section is already owner/admin-gated).
  defp can_delete?(%{scope: "personal"} = dashboard, socket),
    do: dashboard.owner_user_uuid == actor_uuid(socket)

  defp can_delete?(_dashboard, _socket), do: true

  # Render-side mirror of can_delete?/2 (takes the uuid, not the socket).
  defp deletable?(%{scope: "personal"} = dashboard, uuid), do: dashboard.owner_user_uuid == uuid
  defp deletable?(_dashboard, _uuid), do: true

  # Translated label for a scope enum (the raw value renders as a badge).
  defp type_icon(dashboard) do
    case Dashboard.type(dashboard) do
      "pixel" -> "hero-arrows-pointing-out"
      _ -> "hero-squares-2x2"
    end
  end

  defp type_label(dashboard) do
    case Dashboard.type(dashboard) do
      "pixel" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Pixel")
      _ -> Gettext.gettext(PhoenixKitWeb.Gettext, "Grid")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- No in-page <h1>: the admin header breadcrumb already shows the page
      title (@page_title), so the page reclaims the space (workspace canon). --%>
      <div class="flex items-center justify-end">
        <.link navigate={Paths.new()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Create dashboard")}
        </.link>
      </div>

      <.empty_state
        :if={@dashboards == []}
        variant="featured"
        icon="hero-squares-2x2"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "No dashboards yet.")}
      >
        <.link navigate={Paths.new()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Create your first dashboard")}
        </.link>
      </.empty_state>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={dashboard <- @dashboards} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-start justify-between gap-2">
              <.link
                navigate={Paths.builder(dashboard.uuid)}
                class="card-title text-base hover:text-primary transition-colors min-w-0 truncate"
              >
                {dashboard.title}
              </.link>
              <span class={[
                "badge badge-sm",
                if(dashboard.scope == "system", do: "badge-info", else: "badge-ghost")
              ]}>
                {scope_label(dashboard.scope)}
              </span>
            </div>
            <p class="flex items-center gap-1.5 text-xs text-base-content/50">
              <.icon name={type_icon(dashboard)} class="w-3.5 h-3.5" />
              <span>{type_label(dashboard)}</span>
              <span aria-hidden="true">·</span>
              <span>
                {Gettext.ngettext(
                  PhoenixKitWeb.Gettext,
                  "%{count} widget",
                  "%{count} widgets",
                  length(dashboard.layout)
                )}
              </span>
            </p>
            <%!-- Primary action stays a visible button; secondary actions live
            in the canonical <.table_row_menu> kebab (staff/entities pattern). --%>
            <div class="card-actions items-center justify-end mt-2">
              <.link navigate={Paths.builder(dashboard.uuid)} class="btn btn-outline btn-xs">
                <.icon name="hero-pencil-square" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Open")}
              </.link>
              <.table_row_menu
                id={"dashboard-menu-#{dashboard.uuid}"}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}
              >
                <.table_row_menu_link
                  :if={deletable?(dashboard, @current_user_uuid)}
                  navigate={Paths.edit(dashboard.uuid)}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                />
                <.table_row_menu_button
                  phx-click="clone"
                  phx-value-uuid={dashboard.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Cloning…")}
                  icon="hero-document-duplicate"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Clone")}
                />
                <.table_row_menu_divider :if={deletable?(dashboard, @current_user_uuid)} />
                <.table_row_menu_button
                  :if={deletable?(dashboard, @current_user_uuid)}
                  phx-click="delete"
                  phx-value-uuid={dashboard.uuid}
                  data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete this dashboard?")}
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
