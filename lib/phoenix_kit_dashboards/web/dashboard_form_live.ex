defmodule PhoenixKitDashboards.Web.DashboardFormLive do
  @moduledoc """
  Dedicated create/edit page for a dashboard's metadata (title, layout type,
  visibility). Replaces the old create modal.

  - `:new` — title + type + visibility; creating navigates straight into the
    new dashboard's builder.
  - `:edit` — title + visibility are editable; the **type is fixed at creation**
    (shown locked). Saving returns to the manage page.

  Widgets and placement are edited in the builder, not here.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [actor_uuid: 1, actor_opts: 1, list_roles: 0]

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Schemas.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :roles, list_roles())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply,
         socket
         |> assign(:dashboard, nil)
         |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard"))}

      :edit ->
        load_dashboard(socket, params["uuid"])
    end
  end

  defp load_dashboard(socket, uuid) do
    with %Dashboard{} = dashboard <- uuid && Dashboards.get(uuid),
         true <- can_manage?(dashboard, socket) do
      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> assign(
         :page_title,
         Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard settings")
       )}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard not found."))
         |> push_navigate(to: Paths.index())}
    end
  end

  @impl true
  def handle_event("save", %{"title" => title} = params, socket) do
    case socket.assigns.dashboard do
      nil -> create(socket, title, params)
      dashboard -> update(socket, dashboard, title, params)
    end
  end

  # Ignore any malformed / unexpected event rather than crashing the page.
  @impl true
  def handle_event(event, _params, socket) do
    Logger.debug("[Dashboards] Unhandled event: #{inspect(event)}")
    {:noreply, socket}
  end

  defp create(socket, title, params) do
    # Type is fixed at creation ("grid" | "pixel"); it cannot be changed later.
    type = if params["type"] == "pixel", do: "pixel", else: "grid"

    attrs =
      %{
        title:
          blank_to_default(title, Gettext.gettext(PhoenixKitWeb.Gettext, "Untitled Dashboard")),
        config: %{"type" => type}
      }
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

  defp update(socket, dashboard, title, params) do
    attrs =
      %{
        title:
          blank_to_default(title, Gettext.gettext(PhoenixKitWeb.Gettext, "Untitled Dashboard"))
      }
      |> Map.merge(scope_attrs(params, socket))

    # Re-fetch + re-check on save: the load-time gate isn't enough — another
    # admin may have re-scoped the dashboard (e.g. to their personal) while
    # this form sat open; fail closed like a fresh load would.
    fresh = Dashboards.get(dashboard.uuid)

    if is_nil(fresh) or not can_manage?(fresh, socket) do
      {:noreply,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard not found."))
       |> push_navigate(to: Paths.index())}
    else
      do_update(socket, fresh, attrs)
    end
  end

  defp do_update(socket, dashboard, attrs) do
    case Dashboards.update(dashboard, attrs, actor_opts(socket)) do
      {:ok, _dashboard} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard updated."))
         |> push_navigate(to: Paths.index())}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitWeb.Gettext,
             "This dashboard was just edited elsewhere — please try again."
           )
         )
         |> push_navigate(to: Paths.index())}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not update dashboard.")
         )}
    end
  end

  # The scope + scope-specific attrs from the form params. Switching an
  # existing dashboard to "personal" makes the editor its owner (a scope must
  # always point at its audience — the changeset enforces it).
  defp scope_attrs(%{"scope" => "system"}, _socket),
    do: %{scope: "system", owner_user_uuid: nil, role_uuid: nil}

  defp scope_attrs(%{"scope" => "role", "role_uuid" => uuid}, _socket)
       when is_binary(uuid) and uuid != "",
       do: %{scope: "role", role_uuid: uuid, owner_user_uuid: nil}

  defp scope_attrs(_params, socket),
    do: %{scope: "personal", owner_user_uuid: actor_uuid(socket), role_uuid: nil}

  # Manage rule shared with the list page: own personal dashboards; any admin
  # here can manage shared/role ones (the admin section is already gated).
  defp can_manage?(%{scope: "personal"} = dashboard, socket),
    do: dashboard.owner_user_uuid == actor_uuid(socket)

  defp can_manage?(_dashboard, _socket), do: true

  # Role-scoped dashboards are HIDDEN for now (they were briefly offered in the
  # old create modal, 2026-07-08). The backend keeps full support — existing
  # role dashboards stay visible to their members — but the UI doesn't offer
  # creating them. An already-role-scoped dashboard is grandfathered on edit so
  # saving can't silently convert it to personal.
  defp role_scope_visible?(dashboard, _roles), do: match?(%{scope: "role"}, dashboard)

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp type_options do
    [
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Grid (responsive)"), "grid"},
      {Gettext.gettext(PhoenixKitWeb.Gettext, "Pixel (free canvas)"), "pixel"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-6">
      <div class="flex items-center gap-3">
        <.link navigate={Paths.index()} class="btn btn-ghost btn-sm btn-square">
          <.icon name="hero-arrow-left" class="w-4 h-4" />
        </.link>
        <h1 class="text-2xl font-semibold">
          {if @dashboard,
            do: Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboard settings"),
            else: Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard")}
        </h1>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <form id="dashboard-form" phx-submit="save" class="flex flex-col gap-4">
            <.input
              type="text"
              name="title"
              value={(@dashboard && @dashboard.title) || ""}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Title")}
              placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard title")}
              autofocus
            />

            <div>
              <.select
                :if={is_nil(@dashboard)}
                name="type"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Layout type")}
                value="grid"
                options={type_options()}
              />
              <%!-- Type is fixed at creation — show it locked on edit (no name
              attr, so it never submits). --%>
              <.select
                :if={@dashboard}
                name="type_locked"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Layout type")}
                value={Dashboard.type(@dashboard)}
                options={type_options()}
                disabled
              />
              <p class="mt-1 text-xs text-base-content/50">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Fixed once the dashboard is created.")}
              </p>
            </div>

            <.select
              name="scope"
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Visibility")}
              value={(@dashboard && @dashboard.scope) || "personal"}
              options={
                [
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Personal"), "personal"},
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Shared"), "system"}
                ] ++
                  if(role_scope_visible?(@dashboard, @roles),
                    do: [{Gettext.gettext(PhoenixKitWeb.Gettext, "By role"), "role"}],
                    else: []
                  )
              }
            />

            <.select
              :if={role_scope_visible?(@dashboard, @roles)}
              name="role_uuid"
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Role")}
              value={@dashboard && @dashboard.role_uuid}
              options={Enum.map(@roles, &{&1.name, &1.uuid})}
            />

            <div class="flex justify-end gap-2 pt-2">
              <.link navigate={Paths.index()} class="btn btn-ghost">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
              </.link>
              <button
                type="submit"
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
                class="btn btn-primary"
              >
                <.icon :if={is_nil(@dashboard)} name="hero-plus" class="w-4 h-4" />
                {if @dashboard,
                  do: Gettext.gettext(PhoenixKitWeb.Gettext, "Save"),
                  else: Gettext.gettext(PhoenixKitWeb.Gettext, "Create")}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
