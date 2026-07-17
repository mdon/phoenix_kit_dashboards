defmodule PhoenixKitDashboards.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers shared by the Dashboards LiveViews.

  `actor_opts/1` is the canonical way to thread the acting user's uuid into
  context mutations that accept a trailing `opts \\ []` (for activity logging).
  """

  alias PhoenixKit.Users.Roles
  alias PhoenixKitDashboards.Dashboards

  @doc """
  Dynamic translation for catalog DATA (widget names, descriptions, view names,
  settings labels — plain strings from the provider contract). Falls back to
  the input when no translation exists, so provider strings pass through.
  """
  @spec translate_catalog(String.t() | nil) :: String.t() | nil
  def translate_catalog(nil), do: nil

  def translate_catalog(string) when is_binary(string) do
    Gettext.gettext(PhoenixKitWeb.Gettext, string)
  end

  @doc "Translated label for a dashboard scope enum value."
  @spec scope_label(String.t()) :: String.t()
  def scope_label("personal"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "personal")
  def scope_label("system"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "shared")
  def scope_label("role"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "role")
  def scope_label(other), do: other

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

  @doc """
  Whether `dashboard` is viewable by the socket's user (own personal · any
  shared/system · role dashboards for the user's roles). The single view rule,
  shared by the list page and the builder so the two never disagree.
  """
  @spec viewable_by?(map(), Phoenix.LiveView.Socket.t()) :: boolean()
  def viewable_by?(dashboard, socket) do
    Dashboards.visible_to?(dashboard, actor_uuid(socket), user_role_uuids(socket))
  end

  @doc """
  Whether `actor_uuid` may manage (edit/delete) `dashboard`: own personal ones,
  or any shared/role one (the admin section is already owner/admin-gated). Takes
  the actor uuid so socket callers (`actor_uuid(socket)`) and render-side
  callers (the current-user uuid) share one rule — replacing the former
  `can_delete?` / `deletable?` / `can_manage?` triplet.
  """
  @spec manageable_by?(map(), String.t() | nil) :: boolean()
  def manageable_by?(%{scope: "personal"} = dashboard, actor_uuid),
    do: dashboard.owner_user_uuid == actor_uuid

  def manageable_by?(_dashboard, _actor_uuid), do: true

  @doc "All roles (for pickers); `[]` when the roles API is unavailable."
  @spec list_roles() :: [struct()]
  def list_roles do
    if Code.ensure_loaded?(Roles), do: Roles.list_roles(), else: []
  rescue
    _ -> []
  end
end
