defmodule PhoenixKitDashboards.Web.DashboardsLive do
  @moduledoc """
  Manage page — lists the current user's personal dashboards, all shared
  (system) dashboards, and any `role`-scoped dashboards for the user's roles.
  Admins can create a **personal**, **shared** (system), or **by-role** dashboard,
  **clone** any visible dashboard into a private editable copy, open the builder,
  or delete (own personal ones + shared/role ones).

  Admin layout, sidebar, and the `@phoenix_kit_current_user` / `_scope` assigns
  are injected by PhoenixKit's on_mount hooks.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [actor_uuid: 1, actor_opts: 1, user_role_uuids: 1]

  alias PhoenixKit.Users.Roles
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Schemas.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboards")
     |> assign(:roles, list_roles())
     |> assign(:show_create, false)
     |> load_dashboards()}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply, assign(socket, :show_create, true)}
  end

  @impl true
  def handle_event("close_create", _params, socket) do
    {:noreply, assign(socket, :show_create, false)}
  end

  @impl true
  def handle_event("create", %{"title" => title} = params, socket) do
    # Type is fixed at creation ("grid" | "pixel"); it cannot be changed later.
    type = if params["type"] == "pixel", do: "pixel", else: "grid"

    attrs =
      %{title: blank_to_default(title, "Untitled Dashboard"), config: %{"type" => type}}
      |> Map.merge(scope_attrs(params, socket))

    case Dashboards.create(attrs, actor_opts(socket)) do
      {:ok, dashboard} ->
        {:noreply, push_navigate(socket, to: Paths.builder(dashboard.uuid))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not create dashboard.")
         )}
    end
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

  # The scope + scope-specific attrs to create with, from the form params.
  defp scope_attrs(%{"scope" => "system"}, _socket), do: %{scope: "system"}

  defp scope_attrs(%{"scope" => "role", "role_uuid" => uuid}, _socket)
       when is_binary(uuid) and uuid != "",
       do: %{scope: "role", role_uuid: uuid}

  defp scope_attrs(_params, socket),
    do: %{scope: "personal", owner_user_uuid: actor_uuid(socket)}

  # All roles for the create picker (empty when the roles API is unavailable).
  defp list_roles do
    if Code.ensure_loaded?(Roles), do: Roles.list_roles(), else: []
  rescue
    _ -> []
  end

  # Role-scoped dashboards aren't exposed in the create modal for now — but the
  # context, visibility rules, and list still support them, so re-enabling is a
  # one-liner: return `roles != []`.
  defp offer_role_scope?(_roles), do: false

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

  defp scope_label("personal"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "personal")
  defp scope_label("system"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "shared")
  defp scope_label("role"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "role")
  defp scope_label(other), do: other

  # Counters daisyUI's modal-open `scrollbar-gutter: stable` — see BuilderLive.
  defp gutter_fix_style do
    Phoenix.HTML.raw("<style>:root:has(.modal-open){scrollbar-gutter:auto}</style>")
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Counter daisyUI's modal-open scrollbar-gutter reservation — see the
      builder's comment (the create modal here has the same phantom right-edge
      strip on pages without a scrollbar). --%>
      {gutter_fix_style()}
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboards")}</h1>
        <button type="button" phx-click="open_create" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Create dashboard")}
        </button>
      </div>

      <.create_modal :if={@show_create} roles={@roles} />

      <.empty_state
        :if={@dashboards == []}
        variant="featured"
        icon="hero-squares-2x2"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "No dashboards yet.")}
      >
        <button type="button" phx-click="open_create" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Create your first dashboard")}
        </button>
      </.empty_state>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={dashboard <- @dashboards} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-start justify-between gap-2">
              <h2 class="card-title text-base">{dashboard.title}</h2>
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
            <div class="card-actions justify-end mt-2">
              <.link navigate={Paths.builder(dashboard.uuid)} class="btn btn-outline btn-xs">
                <.icon name="hero-pencil-square" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Open")}
              </.link>
              <button
                type="button"
                phx-click="clone"
                phx-value-uuid={dashboard.uuid}
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Cloning…")}
                class="btn btn-ghost btn-xs"
                title={Gettext.gettext(PhoenixKitWeb.Gettext, "Make a personal copy")}
              >
                <.icon name="hero-document-duplicate" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Clone")}
              </button>
              <button
                :if={deletable?(dashboard, @current_user_uuid)}
                type="button"
                phx-click="delete"
                phx-value-uuid={dashboard.uuid}
                data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete this dashboard?")}
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash" class="w-3 h-3" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The "New dashboard" modal — title, layout type (fixed at creation), visibility.
  attr(:roles, :list, required: true)

  defp create_modal(assigns) do
    ~H"""
    <div class="modal modal-open" phx-window-keydown="close_create" phx-key="Escape">
      <div class="modal-box">
        <h3 class="font-semibold text-lg mb-4">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard")}
        </h3>

        <form phx-submit="create" class="flex flex-col gap-3">
          <.input
            type="text"
            name="title"
            value=""
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Title")}
            placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard title")}
            autofocus
          />

          <div>
            <.select
              name="type"
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Layout type")}
              value="grid"
              options={[
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Grid (responsive)"), "grid"},
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Pixel (free canvas)"), "pixel"}
              ]}
            />
            <p class="mt-1 text-xs text-base-content/50">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Fixed once the dashboard is created.")}
            </p>
          </div>

          <.select
            name="scope"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Visibility")}
            value="personal"
            options={
              [
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Personal"), "personal"},
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Shared"), "system"}
              ] ++
                if(offer_role_scope?(@roles),
                  do: [{Gettext.gettext(PhoenixKitWeb.Gettext, "By role"), "role"}],
                  else: []
                )
            }
          />

          <.select
            :if={offer_role_scope?(@roles)}
            name="role_uuid"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Role")}
            value={nil}
            options={Enum.map(@roles, &{&1.name, &1.uuid})}
          />

          <div class="modal-action">
            <button type="button" phx-click="close_create" class="btn btn-ghost">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
            </button>
            <button
              type="submit"
              phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Creating…")}
              class="btn btn-primary"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Create")}
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_create"></div>
    </div>
    """
  end
end
