defmodule PhoenixKitDashboards.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers shared by the Dashboards LiveViews.

  `actor_opts/1` is the canonical way to thread the acting user's uuid into
  context mutations that accept a trailing `opts \\ []` (for activity logging).
  """

  alias PhoenixKit.Users.Roles

  @doc """
  Counter for daisyUI 5.0.x's modal/drawer-open `scrollbar-gutter: stable` (the
  layered zero-specificity original loses to this unlayered rule). The same
  rule ships in core's admin layout now — delete this helper once the core pin
  includes it.
  """
  @spec gutter_fix_style() :: Phoenix.HTML.safe()
  def gutter_fix_style do
    Phoenix.HTML.raw(
      "<style>:root:has(.modal-open, .modal[open], .modal:target, .modal-toggle:checked)" <>
        "{scrollbar-gutter:auto}</style>"
    )
  end

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

  @doc """
  Translated label for a breakpoint tier. Literal-call clauses on purpose: the
  gettext extractor only sees literal arguments, so rendering
  `Breakpoints.get(key).label` through a variable would never localize.
  """
  @spec bp_label(String.t()) :: String.t()
  def bp_label("tv"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "TV")
  def bp_label("desktop"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Desktop")
  def bp_label("ipad"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "iPad")
  def bp_label("phone"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Phone")
  def bp_label(other), do: other

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

  @doc "All roles (for pickers); `[]` when the roles API is unavailable."
  @spec list_roles() :: [struct()]
  def list_roles do
    if Code.ensure_loaded?(Roles), do: Roles.list_roles(), else: []
  rescue
    _ -> []
  end
end
