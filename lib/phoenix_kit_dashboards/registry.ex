defmodule PhoenixKitDashboards.Registry do
  @moduledoc """
  Discovers and caches the widget catalog.

  The catalog is the union of:

  - **Built-in widgets** shipped by this module (`PhoenixKitDashboards.Widgets`).
  - **Provider widgets** from any discovered PhoenixKit module that defines
    `phoenix_kit_widgets/0` (see `PhoenixKitDashboards.Widget` for the contract).

  Discovery is convention-based — it queries `PhoenixKit.ModuleRegistry` at
  runtime and calls `phoenix_kit_widgets/0` on any module that exports it. No new
  core `PhoenixKit.Module` callback is required, so this ships independently of a
  core release. (If the contract proves load-bearing, it can later be promoted
  into the `PhoenixKit.Module` behaviour.)

  The result is memoized in `:persistent_term`, mirroring how core's
  `ModuleRegistry` caches tabs and permissions. Call `refresh/0` after modules
  are toggled to rebuild.
  """

  require Logger

  alias PhoenixKitDashboards.Widget
  alias PhoenixKitDashboards.Widgets

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
    Enum.filter(list(), &visible?(&1, scope))
  end

  @doc "Look up a single widget type by key."
  @spec get(String.t()) :: Widget.t() | nil
  def get(key) when is_binary(key), do: Map.get(catalog(), key)

  @doc "Rebuild the catalog from built-ins + discovered providers and re-cache it."
  @spec refresh() :: %{String.t() => Widget.t()}
  def refresh do
    widgets = builtin_widgets() ++ provider_widgets()

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

  defp builtin_widgets do
    Widgets.builtin()
    |> Enum.flat_map(&normalize(&1, :builtin))
  end

  defp provider_widgets do
    provider_modules()
    |> Enum.flat_map(fn module ->
      module
      |> safe_widgets()
      |> Enum.flat_map(&normalize(&1, module))
    end)
  end

  # Ask core's ModuleRegistry for every discovered module, keep those that opt
  # into the widget contract. Degrades gracefully if core isn't loaded.
  defp provider_modules do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      PhoenixKit.ModuleRegistry.all_modules()
      |> Enum.filter(&function_exported?(&1, @provider_callback, 0))
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Dashboards] Provider discovery failed: #{Exception.message(e)}")
      []
  end

  defp safe_widgets(module) do
    List.wrap(apply(module, @provider_callback, []))
  rescue
    e ->
      Logger.warning(
        "[Dashboards] #{inspect(module)}.#{@provider_callback}/0 raised: #{Exception.message(e)}"
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
  end

  # ── Visibility ─────────────────────────────────────────────────────

  defp visible?(%Widget{module_key: nil}, _scope), do: true

  defp visible?(%Widget{module_key: key}, scope) do
    module_enabled?(key) and has_access?(scope, key)
  end

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
    if Code.ensure_loaded?(PhoenixKit.Users.Auth.Scope) do
      PhoenixKit.Users.Auth.Scope.has_module_access?(scope, key)
    else
      true
    end
  rescue
    _ -> true
  end
end
