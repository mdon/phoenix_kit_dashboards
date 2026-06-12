defmodule PhoenixKitDashboards.Widgets.ModuleStatsWidget do
  @moduledoc """
  Built-in "Module stats" widget — renders the `get_config/0` map of any
  discovered PhoenixKit module, selected by its `module_key` setting.

  Demonstrates a widget that pulls live data from the host at render time. It
  resolves the module through core's `PhoenixKit.ModuleRegistry` and degrades
  gracefully when core isn't loaded or the key is unknown.
  """
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}
    module_key = Map.get(settings, "module_key", "")

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:module_key, module_key)
     |> assign(:stats, load_stats(module_key))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class="card-body p-4">
        <h3 class="card-title text-sm">
          {if @module_key == "", do: "Module stats", else: @module_key}
        </h3>
        <dl :if={@stats != %{}} class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm mt-1">
          <%= for {key, value} <- @stats do %>
            <dt class="text-base-content/60">{key}</dt>
            <dd class="font-mono text-right">{inspect(value)}</dd>
          <% end %>
        </dl>
        <p :if={@stats == %{}} class="text-sm text-base-content/50">
          No stats — set a valid module key in this widget's settings.
        </p>
      </div>
    </div>
    """
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
