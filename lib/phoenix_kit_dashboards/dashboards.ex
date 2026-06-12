defmodule PhoenixKitDashboards.Dashboards do
  @moduledoc """
  Context for dashboard pages and their widget layouts.

  Persistence follows the `phoenix_kit_crm` precedent: the dashboard row holds a
  JSONB `layout` list of widget instances, read and written whole. The host app's
  repo is reached via `PhoenixKit.RepoHelper.repo/0` — this module never owns a
  repo of its own.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  @doc "Dashboards visible to a user: their personal ones plus all shared/system ones."
  @spec list_for_user(user_uuid :: String.t()) :: [Dashboard.t()]
  def list_for_user(user_uuid) when is_binary(user_uuid) do
    query =
      from(d in Dashboard,
        where: d.owner_user_uuid == ^user_uuid or d.scope == "system",
        order_by: [asc: d.position, asc: d.inserted_at]
      )

    repo().all(query)
  end

  @doc "All system/shared dashboards (admin-managed)."
  @spec list_system() :: [Dashboard.t()]
  def list_system do
    query = from(d in Dashboard, where: d.scope == "system", order_by: [asc: d.position])
    repo().all(query)
  end

  @doc "Fetch one dashboard by uuid, or nil."
  @spec get(String.t()) :: Dashboard.t() | nil
  def get(uuid) when is_binary(uuid), do: repo().get(Dashboard, uuid)

  @doc """
  Return the user's default personal dashboard, creating an empty one on first
  access. This is the page shown at the module's landing route.
  """
  @spec get_or_create_default(user_uuid :: String.t()) :: Dashboard.t()
  def get_or_create_default(user_uuid) when is_binary(user_uuid) do
    query =
      from(d in Dashboard,
        where: d.owner_user_uuid == ^user_uuid and d.is_default == true,
        limit: 1
      )

    case repo().one(query) do
      nil ->
        {:ok, dashboard} =
          create(%{
            title: "My Dashboard",
            scope: "personal",
            owner_user_uuid: user_uuid,
            is_default: true
          })

        dashboard

      dashboard ->
        dashboard
    end
  end

  @doc "Create a dashboard."
  @spec create(map()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Dashboard{}
    |> Dashboard.changeset(attrs)
    |> repo().insert()
  end

  @doc "Update a dashboard's metadata."
  @spec update(Dashboard.t(), map()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def update(%Dashboard{} = dashboard, attrs) do
    dashboard
    |> Dashboard.changeset(attrs)
    |> repo().update()
  end

  @doc "Delete a dashboard."
  @spec delete(Dashboard.t()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Dashboard{} = dashboard), do: repo().delete(dashboard)

  @doc "Persist a new full layout (the hot path while editing the grid)."
  @spec save_layout(Dashboard.t(), [map()]) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def save_layout(%Dashboard{} = dashboard, layout) when is_list(layout) do
    dashboard
    |> Dashboard.layout_changeset(layout)
    |> repo().update()
  end

  @doc """
  Add a widget instance for `widget_key` to a dashboard's layout, seeded with the
  widget type's default size and settings. Returns the updated dashboard.
  """
  @spec add_widget(Dashboard.t(), widget_key :: String.t()) ::
          {:ok, Dashboard.t()} | {:error, term()}
  def add_widget(%Dashboard{} = dashboard, widget_key) do
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        instance = %{
          "id" => UUIDv7.generate(),
          "widget_key" => widget.key,
          "x" => 0,
          "y" => next_row(dashboard.layout),
          "w" => widget.default_size.w,
          "h" => widget.default_size.h,
          "settings" => Widget.default_settings(widget)
        }

        save_layout(dashboard, dashboard.layout ++ [instance])
    end
  end

  @doc "Remove a widget instance by its instance id."
  @spec remove_widget(Dashboard.t(), instance_id :: String.t()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def remove_widget(%Dashboard{} = dashboard, instance_id) do
    layout = Enum.reject(dashboard.layout, &(&1["id"] == instance_id))
    save_layout(dashboard, layout)
  end

  @doc "Replace the settings map of a single widget instance."
  @spec update_widget_settings(Dashboard.t(), instance_id :: String.t(), map()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def update_widget_settings(%Dashboard{} = dashboard, instance_id, settings) do
    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst -> Map.put(inst, "settings", settings)
        inst -> inst
      end)

    save_layout(dashboard, layout)
  end

  # Place a new widget below everything currently on the grid.
  defp next_row([]), do: 0

  defp next_row(layout) do
    layout
    |> Enum.map(fn inst -> (inst["y"] || 0) + (inst["h"] || 1) end)
    |> Enum.max(fn -> 0 end)
  end

  defp repo, do: RepoHelper.repo()
end
