defmodule PhoenixKitDashboards.Registry do
  @moduledoc """
  Discovers and caches the widget catalog.

  The catalog is the union of every PhoenixKit module that defines
  `phoenix_kit_widgets/0` (see `PhoenixKitDashboards.Widget` for the contract).
  **This module is one such provider** — its built-in widgets (note, clock,
  module-stats) are exposed through the same `phoenix_kit_widgets/0` entry point
  as any other module, so there is no special-cased "built-in" path.

  Discovery is convention-based — it queries `PhoenixKit.ModuleRegistry` at
  runtime and calls `phoenix_kit_widgets/0` on any module that exports it (always
  including `PhoenixKitDashboards` itself, so the built-ins are available even
  before/without ModuleRegistry discovery). No new core `PhoenixKit.Module`
  callback is required, so this ships independently of a core release. (If the
  contract proves load-bearing, it can later be promoted into the
  `PhoenixKit.Module` behaviour.)

  The HOST app contributes widgets the same way without being a PhoenixKit
  module: declare provider modules in config —

      config :phoenix_kit_dashboards, widget_providers: [MyAppWeb.Widgets]

  — each exporting `phoenix_kit_widgets/0` in the same plain-map contract. A
  host widget without a `module_key` is always offered; set one to gate the
  widget on that module's enablement + permission like any module widget.

  The result is memoized in `:persistent_term`, mirroring how core's
  `ModuleRegistry` caches tabs and permissions.

  ## Cache freshness — what's live vs memoized

  Module **enablement** and scope **permission** are re-checked LIVE on every
  read (`visible_for_scope?/2` calls `module_enabled?/1`), so toggling a module
  shows/hides its widgets immediately — no refresh needed.

  The cached catalog's STRUCTURE is memoized, so these need `refresh/0` (or a
  BEAM restart) to update:

    * a **new provider** installed into the running system, or a provider whose
      widget **definitions** change (`views` / `settings_schema` /
      `refresh_interval`);
    * **computed catalog options** built at discovery time — the Module-stats
      widget's installed-modules picker (`ModuleStatsWidget.module_options/0`)
      and providers' data-driven selects (e.g. `phoenix_kit_projects`' project
      picker), which won't reflect a module toggled on or a row created at
      runtime until rebuilt.

  Core exposes no module-toggle event to hook, so `refresh/0` is host/provider
  driven: this module refreshes on its own enable, and a provider that changes
  computed options at runtime should call `PhoenixKitDashboards.Registry.refresh/0`.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitDashboards.Widget

  @pt_key {__MODULE__, :catalog}
  @provider_callback :phoenix_kit_widgets

  @doc """
  The full widget catalog, keyed by widget key.

  Memoized in `:persistent_term`; first call builds it.
  """
  @spec catalog() :: %{String.t() => Widget.t()}
  def catalog do
    case :persistent_term.get(@pt_key, :miss) do
      :miss -> refresh()
      catalog -> catalog
    end
  end

  @doc "List all catalog widgets, sorted by category then name."
  @spec list() :: [Widget.t()]
  def list do
    catalog()
    |> Map.values()
    |> Enum.sort_by(&{&1.category, &1.name})
  end

  @doc """
  Catalog widgets visible to a given scope.

  Filters out widgets whose owning module is disabled or whose `module_key`
  permission the scope lacks. Built-in widgets (no `module_key`) are always
  visible. Pass `nil` to skip filtering (e.g. system/internal callers).
  """
  @spec list_for_scope(scope :: term() | nil) :: [Widget.t()]
  def list_for_scope(nil), do: list()

  def list_for_scope(scope) do
    Enum.filter(list(), &visible_for_scope?(&1, scope))
  end

  @doc """
  Whether one widget type is visible to a scope — the same gate `list_for_scope/1`
  applies to the catalog. The render path uses it too, so a **placed** widget stops
  rendering (and refreshing) when its module is disabled or the viewer's scope
  lacks the module permission — placing a widget must not outlive the gate that
  offered it. `nil` scope skips the permission half (module enablement still
  applies); a widget with no `module_key` is always visible.
  """
  @spec visible_for_scope?(Widget.t(), scope :: term() | nil) :: boolean()
  def visible_for_scope?(%Widget{module_key: nil}, _scope), do: true

  def visible_for_scope?(%Widget{module_key: key}, scope) do
    module_enabled?(key) and (is_nil(scope) or has_access?(scope, key))
  end

  @doc "Look up a single widget type by key."
  @spec get(String.t()) :: Widget.t() | nil
  def get(key) when is_binary(key), do: Map.get(catalog(), key)

  @doc "Rebuild the catalog from every discovered widget provider and re-cache it."
  @spec refresh() :: %{String.t() => Widget.t()}
  def refresh do
    widgets = provider_widgets()

    catalog =
      widgets
      |> Enum.reduce(%{}, fn widget, acc ->
        if Map.has_key?(acc, widget.key) do
          Logger.warning(
            "[Dashboards] Duplicate widget key #{inspect(widget.key)} from " <>
              "#{inspect(widget.source)} — keeping the first registered one."
          )

          acc
        else
          Map.put(acc, widget.key, widget)
        end
      end)

    :persistent_term.put(@pt_key, catalog)
    catalog
  end

  # ── Discovery ──────────────────────────────────────────────────────

  defp provider_widgets do
    provider_modules()
    |> Enum.flat_map(fn module ->
      module
      |> safe_widgets()
      |> Enum.flat_map(&normalize(&1, module))
    end)
  end

  # Every module that opts into the widget contract. This module is always first
  # in the list (it's guaranteed loaded and provides the built-in widgets the same
  # way any other module does), then core's discovered modules — deduped so it is
  # queried once. Degrades gracefully if core's ModuleRegistry isn't loaded.
  defp provider_modules do
    discovered =
      if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
        PhoenixKit.ModuleRegistry.all_modules()
      else
        []
      end

    ([PhoenixKitDashboards | discovered] ++ config_providers())
    |> Enum.uniq()
    |> Enum.filter(&function_exported?(&1, @provider_callback, 0))
  rescue
    e ->
      Logger.warning("[Dashboards] Provider discovery failed: #{Exception.message(e)}")
      [PhoenixKitDashboards]
  end

  # Host-app providers from config (see the moduledoc): plain modules, no
  # PhoenixKit registration needed. ensure_loaded so function_exported?/3
  # sees them even before their first call in dev; junk entries are dropped
  # (the shared exported-callback filter catches modules without the contract).
  defp config_providers do
    :phoenix_kit_dashboards
    |> Application.get_env(:widget_providers, [])
    |> List.wrap()
    |> Enum.filter(&(is_atom(&1) and Code.ensure_loaded?(&1)))
  end

  defp safe_widgets(module) do
    List.wrap(apply(module, @provider_callback, []))
  rescue
    e ->
      Logger.warning(
        "[Dashboards] #{inspect(module)}.#{@provider_callback}/0 raised: #{Exception.message(e)}"
      )

      []
  catch
    kind, reason ->
      Logger.warning(
        "[Dashboards] #{inspect(module)}.#{@provider_callback}/0 #{kind}: #{inspect(reason)}"
      )

      []
  end

  defp normalize(map, source) do
    case Widget.from_map(map, source) do
      {:ok, widget} ->
        [widget]

      {:error, reason} ->
        Logger.warning(
          "[Dashboards] Dropping invalid widget from #{inspect(source)}: #{inspect(reason)}"
        )

        []
    end
  rescue
    # One malformed provider entry (e.g. a non-stringable key) must be dropped,
    # never abort the whole catalog build — that would take down every mount.
    e ->
      Logger.warning(
        "[Dashboards] Dropping widget from #{inspect(source)} (normalize raised: #{Exception.message(e)})"
      )

      []
  end

  # ── Visibility ─────────────────────────────────────────────────────

  defp module_enabled?(key) do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      case PhoenixKit.ModuleRegistry.get_by_key(key) do
        nil -> true
        module -> safe_enabled?(module)
      end
    else
      true
    end
  rescue
    _ -> true
  end

  defp safe_enabled?(module) do
    not function_exported?(module, :enabled?, 0) or module.enabled?()
  rescue
    _ -> false
  end

  defp has_access?(scope, key) do
    if Code.ensure_loaded?(Scope) do
      Scope.has_module_access?(scope, key)
    else
      # No Scope module → can't evaluate a permission; allow (the widget's
      # module_key still gates on enablement).
      true
    end
  rescue
    # An error evaluating access fails CLOSED — don't leak a permissioned widget.
    _ -> false
  end
end
