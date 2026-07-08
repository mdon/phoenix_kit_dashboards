defmodule PhoenixKitDashboards.Widgets.ModuleStatsWidget do
  @moduledoc """
  Built-in "Module stats" widget — renders the `get_config/0` map of any
  discovered PhoenixKit module, selected by its `module_key` setting.

  Demonstrates the widget **view + size** contract: it renders a full key/value
  table in the `"detailed"` view and a single headline count in `"compact"`, and
  it falls back to compact automatically when the instance is sized too small for
  a table (`size.w < 3` or `size.h < 2`). It resolves the module through core's
  `PhoenixKit.ModuleRegistry` and degrades gracefully when core isn't loaded or
  the key is unknown. The settings form offers the installed modules as a
  SELECT (`module_options/0`) — nobody should have to know registry keys.
  """
  use Phoenix.LiveComponent

  @doc """
  The installed modules that expose a `get_config/0` map, as `{label, key}`
  select options (sorted by display name). Evaluated when the widget catalog is
  built, so a newly installed module appears after a registry refresh.
  """
  @spec module_options() :: [{String.t(), String.t()}]
  def module_options do
    prompt = {Gettext.gettext(PhoenixKitWeb.Gettext, "Select a module…"), ""}

    options =
      if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
        for mod <- PhoenixKit.ModuleRegistry.all_modules(),
            Code.ensure_loaded?(mod),
            function_exported?(mod, :get_config, 0),
            function_exported?(mod, :module_key, 0),
            function_exported?(mod, :module_name, 0) do
          {mod.module_name(), mod.module_key()}
        end
      else
        []
      end

    [prompt | Enum.sort_by(options, fn {name, _} -> name end)]
  end

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}
    module_key = Map.get(settings, "module_key", "")
    stats = load_stats(module_key)

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:module_key, module_key)
     |> assign(:stats, stats)
     |> assign(:effective_view, effective_view(assigns[:view], assigns[:size], stats))
     # A single-row instance renders dense so the headline count FITS the
     # minimum box instead of growing a scrollbar.
     |> assign(:compact, compact?(assigns[:size]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class={["card-body", if(@compact, do: "gap-0.5 p-2", else: "p-4")]}>
        <h3 class={["card-title", if(@compact, do: "text-xs", else: "text-sm")]}>
          {module_label(@module_key)}
        </h3>

        <p :if={@stats == %{}} class="text-sm text-base-content/50">
          {Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "No stats — pick a module in this widget's settings."
          )}
        </p>

        <dl
          :if={@stats != %{} and @effective_view == "detailed"}
          class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm mt-1"
        >
          <%= for {key, value} <- @stats do %>
            <dt class="text-base-content/60">{key}</dt>
            <dd class="font-mono text-right">{inspect(value)}</dd>
          <% end %>
        </dl>

        <div
          :if={@stats != %{} and @effective_view == "compact"}
          class="flex flex-1 flex-col items-center justify-center"
        >
          <span class={["font-bold", if(@compact, do: "text-2xl", else: "text-3xl")]}>
            {map_size(@stats)}
          </span>
          <span class="text-xs text-base-content/50">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "stats")}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp compact?(%{h: h}) when is_integer(h), do: h < 2
  defp compact?(_), do: false

  # Honor the selected view, but degrade to compact when the widget is too small
  # for a table (or when a single stat makes a table pointless).
  defp effective_view(view, size, stats) do
    too_small? = match?(%{w: w} when w < 3, size) or match?(%{h: h} when h < 2, size)

    cond do
      view == "compact" -> "compact"
      too_small? -> "compact"
      map_size(stats) <= 1 -> "compact"
      true -> "detailed"
    end
  end

  # The module's human name for the card title (falls back to the raw key for
  # an uninstalled/unknown module).
  defp module_label(""), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Module stats")

  defp module_label(module_key) do
    with true <- Code.ensure_loaded?(PhoenixKit.ModuleRegistry),
         mod when not is_nil(mod) <- PhoenixKit.ModuleRegistry.get_by_key(module_key),
         true <- function_exported?(mod, :module_name, 0) do
      mod.module_name()
    else
      _ -> module_key
    end
  rescue
    _ -> module_key
  end

  defp load_stats(""), do: %{}

  defp load_stats(module_key) do
    with true <- Code.ensure_loaded?(PhoenixKit.ModuleRegistry),
         module when not is_nil(module) <- PhoenixKit.ModuleRegistry.get_by_key(module_key),
         true <- function_exported?(module, :get_config, 0) do
      module.get_config() |> stringify()
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify(_), do: %{}
end
