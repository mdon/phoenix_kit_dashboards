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
  use Gettext, backend: PhoenixKitDashboards.Gettext

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [actor_uuid: 1, actor_opts: 1, list_roles: 0, manageable_by?: 2, viewable_by?: 2]

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Slot

  @impl true
  def mount(_params, _session, socket) do
    # Trail: Admin Panel / Dashboards / New dashboard, or
    # / Dashboards / <dashboard> / Edit; title and crumbs land in handle_params.
    {:ok,
     socket
     |> assign(:roles, list_roles())
     |> assign(:page_section, gettext("Dashboards"))
     |> assign(:page_section_path, Paths.index())
     |> assign(:page_crumbs, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply,
         socket
         |> assign(:dashboard, nil)
         |> assign(:placed_in, [])
         |> assign(:page_crumbs, [])
         |> assign(:page_title, gettext("New dashboard"))}

      :edit ->
        load_dashboard(socket, params["uuid"])
    end
  end

  defp load_dashboard(socket, uuid) do
    with %Dashboard{} = dashboard <- uuid && Dashboards.get(uuid),
         true <- editable_by?(dashboard, socket) do
      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> assign(:placed_in, placed_in(dashboard))
       |> assign(:page_crumbs, [%{label: dashboard.title, path: Paths.builder(dashboard.uuid)}])
       |> assign(:page_title, gettext("Edit"))}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Dashboard not found."))
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
        title: blank_to_default(title, gettext("Untitled Dashboard")),
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
           gettext("Could not create dashboard.")
         )}
    end
  end

  defp update(socket, dashboard, title, params) do
    attrs =
      %{
        title: blank_to_default(title, gettext("Untitled Dashboard"))
      }
      |> Map.merge(scope_attrs(params, socket))

    # Re-fetch + re-check on save: the load-time gate isn't enough — another
    # admin may have re-scoped the dashboard (e.g. to their personal) while
    # this form sat open; fail closed like a fresh load would.
    fresh = Dashboards.get(dashboard.uuid)

    if is_nil(fresh) or not editable_by?(fresh, socket) do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Dashboard not found."))
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
         |> put_flash(:info, gettext("Dashboard updated."))
         |> push_navigate(to: Paths.index())}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("This dashboard was just edited elsewhere — please try again.")
         )
         |> push_navigate(to: Paths.index())}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not update dashboard.")
         )}
    end
  end

  # BOTH gates, the way the manage page and the builder pair them.
  # `manageable_by?/2` only restricts PERSONAL dashboards — it answers true for
  # every role-scoped one, for any actor. On its own it let a holder of the
  # dashboards permission open a role dashboard they are not a member of and
  # save it as `scope: "personal"`, which makes the editor its owner: the board
  # leaves the role and the role's members lose it. Seeing it is the missing
  # half, exactly as the delete path already spells out.
  defp editable_by?(dashboard, socket) do
    viewable_by?(dashboard, socket) and manageable_by?(dashboard, actor_uuid(socket))
  end

  # The scope + scope-specific attrs from the form params. Switching an
  # existing dashboard to "personal" makes the editor its owner (a scope must
  # always point at its audience — the changeset enforces it).
  defp scope_attrs(%{"scope" => "system"}, _socket),
    do: %{scope: "system", owner_user_uuid: nil, role_uuid: nil}

  # The role picker is hidden unless the dashboard is ALREADY role-scoped, but
  # the handler still has to check: the value arrives from the wire, and an
  # unchecked one either publishes the board to a role the sender picked or —
  # if it names no role at all — creates a row nobody can ever see, since the
  # changeset only checks that a role uuid is present.
  defp scope_attrs(%{"scope" => "role", "role_uuid" => uuid}, socket)
       when is_binary(uuid) and uuid != "" do
    if Enum.any?(list_roles(), &(&1.uuid == uuid)) do
      %{scope: "role", role_uuid: uuid, owner_user_uuid: nil}
    else
      personal_attrs(socket)
    end
  end

  defp scope_attrs(_params, socket), do: personal_attrs(socket)

  defp personal_attrs(socket),
    do: %{scope: "personal", owner_user_uuid: actor_uuid(socket), role_uuid: nil}

  # Role-scoped dashboards are HIDDEN for now (they were briefly offered in the
  # old create modal, 2026-07-08). The backend keeps full support — existing
  # role dashboards stay visible to their members — but the UI doesn't offer
  # creating them. An already-role-scoped dashboard is grandfathered on edit so
  # saving can't silently convert it to personal.
  defp role_scope_visible?(dashboard), do: match?(%{scope: "role"}, dashboard)

  # The places this dashboard currently fills, named the way the viewer sees
  # them — so "making it personal" states its actual consequence rather than
  # leaving it to be discovered when a page goes blank.
  defp placed_in(%Dashboard{uuid: uuid}) do
    uuid
    |> Placements.places_for()
    |> Enum.reject(&(&1.audience == "personal"))
    |> Enum.map(fn
      %{slot: %Slot{} = slot} -> Slot.localized_name(slot)
      %{slot_key: key} -> key
    end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp type_options do
    [
      {gettext("Grid (responsive)"), "grid"},
      {gettext("Pixel (free canvas)"), "pixel"}
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
            do: gettext("Dashboard settings"),
            else: gettext("New dashboard")}
        </h1>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <form id="dashboard-form" phx-submit="save" class="flex flex-col gap-4">
            <.input
              type="text"
              name="title"
              value={(@dashboard && @dashboard.title) || ""}
              label={gettext("Title")}
              placeholder={gettext("New dashboard title")}
              autofocus
            />

            <div>
              <.select
                :if={is_nil(@dashboard)}
                name="type"
                label={gettext("Layout type")}
                value="grid"
                options={type_options()}
              />
              <%!-- Type is fixed at creation — show it locked on edit (no name
              attr, so it never submits). --%>
              <.select
                :if={@dashboard}
                name="type_locked"
                label={gettext("Layout type")}
                value={Dashboard.type(@dashboard)}
                options={type_options()}
                disabled
              />
              <p class="mt-1 text-xs text-base-content/50">
                {gettext("Fixed once the dashboard is created.")}
              </p>
            </div>

            <.select
              name="scope"
              label={gettext("Visibility")}
              value={(@dashboard && @dashboard.scope) || "personal"}
              options={
                [
                  {gettext("Personal"), "personal"},
                  {gettext("Shared"), "system"}
                ] ++
                  if(role_scope_visible?(@dashboard),
                    do: [{gettext("By role"), "role"}],
                    else: []
                  )
              }
            />

            <%!-- Visibility is not just who can open it: only a SHARED dashboard
            may be placed. Someone who picks Personal and then cannot find their
            board in Places has been told nothing — so say it here. --%>
            <p class="-mt-1 text-xs text-base-content/60">
              {gettext("Only shared dashboards can be shown in a place. A personal one is yours alone.")}
            </p>

            <div :if={@placed_in != []} class="alert alert-warning py-2 text-sm">
              {gettext("This dashboard is shown in %{places}. Making it personal removes it from there.",
                places: Enum.join(@placed_in, ", ")
              )}
            </div>

            <.select
              :if={role_scope_visible?(@dashboard)}
              name="role_uuid"
              label={gettext("Role")}
              value={@dashboard && @dashboard.role_uuid}
              options={Enum.map(@roles, &{&1.name, &1.uuid})}
            />

            <div class="flex justify-end gap-2 pt-2">
              <.button variant="ghost" navigate={Paths.index()}>
                {gettext("Cancel")}
              </.button>
              <.button type="submit" phx-disable-with={gettext("Saving…")}>
                <.icon :if={is_nil(@dashboard)} name="hero-plus" class="w-4 h-4" />
                {if @dashboard,
                  do: gettext("Save"),
                  else: gettext("Create")}
              </.button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
