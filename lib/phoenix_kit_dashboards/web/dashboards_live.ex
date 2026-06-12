defmodule PhoenixKitDashboards.Web.DashboardsLive do
  @moduledoc """
  Manage page — lists the current user's personal dashboards plus all shared
  (system) dashboards, and lets them create, open, or delete dashboards.

  Admin layout, sidebar, and the `@phoenix_kit_current_user` / `_scope` assigns
  are injected by PhoenixKit's on_mount hooks.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboards")
     |> load_dashboards()}
  end

  @impl true
  def handle_event("create", %{"title" => title}, socket) do
    attrs = %{
      title: blank_to_default(title, "Untitled Dashboard"),
      scope: "personal",
      owner_user_uuid: user_uuid(socket)
    }

    case Dashboards.create(attrs) do
      {:ok, dashboard} ->
        {:noreply, push_navigate(socket, to: Paths.builder(dashboard.uuid))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create dashboard.")}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %{} = dashboard <- Dashboards.get(uuid),
         true <- owns?(dashboard, socket),
         {:ok, _} <- Dashboards.delete(dashboard) do
      {:noreply, socket |> put_flash(:info, "Dashboard deleted.") |> load_dashboards()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete dashboard.")}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Dashboards] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_dashboards(socket) do
    dashboards = Dashboards.list_for_user(user_uuid(socket))
    assign(socket, :dashboards, dashboards)
  end

  defp owns?(dashboard, socket), do: dashboard.owner_user_uuid == user_uuid(socket)

  defp user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{Gettext.gettext(PhoenixKitWeb.Gettext, "Dashboards")}</h1>
        <form phx-submit="create" class="flex items-center gap-2">
          <input
            type="text"
            name="title"
            placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "New dashboard title")}
            class="input input-bordered input-sm"
          />
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Create")}
          </button>
        </form>
      </div>

      <div :if={@dashboards == []} class="card bg-base-100 shadow">
        <div class="card-body items-center text-center text-base-content/60">
          <.icon name="hero-squares-2x2" class="w-10 h-10" />
          <p>{Gettext.gettext(PhoenixKitWeb.Gettext, "No dashboards yet. Create your first one above.")}</p>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={dashboard <- @dashboards} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-start justify-between gap-2">
              <h2 class="card-title text-base">{dashboard.title}</h2>
              <span class={[
                "badge badge-sm",
                if(dashboard.scope == "system", do: "badge-info", else: "badge-ghost")
              ]}>
                {dashboard.scope}
              </span>
            </div>
            <p class="text-xs text-base-content/50">
              {length(dashboard.layout)} {Gettext.gettext(PhoenixKitWeb.Gettext, "widgets")}
            </p>
            <div class="card-actions justify-end mt-2">
              <.link navigate={Paths.builder(dashboard.uuid)} class="btn btn-outline btn-xs">
                <.icon name="hero-pencil-square" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Open")}
              </.link>
              <button
                :if={dashboard.scope == "personal"}
                type="button"
                phx-click="delete"
                phx-value-uuid={dashboard.uuid}
                data-confirm={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete this dashboard?")}
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
end
