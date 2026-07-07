defmodule PhoenixKitDashboards.Widgets.ModuleStatsWidget do
  @moduledoc """
  Built-in "Module stats" widget — renders the `get_config/0` map of any
  discovered PhoenixKit module, selected by its `module_key` setting.

  Demonstrates the widget **view + size** contract: it renders a full key/value
  table in the `"detailed"` view and a single headline count in `"compact"`, and
  it falls back to compact automatically when the instance is sized too small for
  a table (`size.w < 3` or `size.h < 2`). It resolves the module through core's
  `PhoenixKit.ModuleRegistry` and degrades gracefully when core isn't loaded or
  the key is unknown.
  """
  use Phoenix.LiveComponent

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
     |> assign(:effective_view, effective_view(assigns[:view], assigns[:size], stats))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class="card-body p-4">
        <h3 class="card-title text-sm">
          {if @module_key == "",
            do: Gettext.gettext(PhoenixKitWeb.Gettext, "Module stats"),
            else: @module_key}
        </h3>

        <p :if={@stats == %{}} class="text-sm text-base-content/50">
          {Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "No stats — set a valid module key in this widget's settings."
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
          <span class="text-3xl font-bold">{map_size(@stats)}</span>
          <span class="text-xs text-base-content/50">{Gettext.gettext(PhoenixKitWeb.Gettext, "stats")}</span>
        </div>
      </div>
    </div>
    """
  end

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
