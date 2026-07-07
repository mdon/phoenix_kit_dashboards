defmodule PhoenixKitDashboards.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers shared by the Dashboards LiveViews.

  `actor_opts/1` is the canonical way to thread the acting user's uuid into
  context mutations that accept a trailing `opts \\ []` (for activity logging).
  """

  alias PhoenixKit.Users.Roles

  @doc "The current user's uuid from socket assigns, or `nil`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Keyword opts threading the acting user's uuid into context mutations.

  Returns `[actor_uuid: uuid]`, or `[]` when there is no current user (so the
  context call is unaffected).
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def actor_opts(socket) do
    case actor_uuid(socket) do
      nil -> []
      uuid -> [actor_uuid: uuid]
    end
  end

  @doc """
  The current user's role uuids, mapped from the scope's cached role names — used
  by both LiveViews to resolve `role`-scoped dashboard visibility. Reuses a
  `@roles` assign if present, else queries core once. `[]` when roles are
  unavailable.
  """
  @spec user_role_uuids(Phoenix.LiveView.Socket.t()) :: [String.t()]
  def user_role_uuids(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{cached_roles: names} when is_list(names) and names != [] ->
        roles = socket.assigns[:roles] || list_roles()
        for role <- roles, role.name in names, do: role.uuid

      _ ->
        []
    end
  end

  defp list_roles do
    if Code.ensure_loaded?(Roles), do: Roles.list_roles(), else: []
  rescue
    _ -> []
  end
end
