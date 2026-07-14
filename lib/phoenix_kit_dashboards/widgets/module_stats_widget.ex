defmodule PhoenixKitDashboards.Widgets.ModuleStatsWidget do
  @moduledoc """
  Built-in "Module stats" widget — renders the `get_config/0` map of any
  discovered PhoenixKit module, selected by its `module_key` setting.

  Demonstrates the widget **view** contract: it renders a key/value table in
  the `"detailed"` view and a single headline count in `"compact"` — the view
  is user-chosen and honored verbatim at any size (content self-fits via
  container-query type scaling). It resolves the module through core's
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
    # The user-set row budget: the detailed table shows exactly this many
    # entries (box divides into slots; nothing scrolls, nothing is silently
    # cut — the "+N more" line says what's beyond the budget).
    items = parse_items(Map.get(settings, "items", 6))

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:module_key, module_key)
     |> assign(:stats, stats)
     |> assign(:items, items)
     |> assign(:view, assigns[:view] || "detailed")}
  end

  # Slot budget bounds: below ~1/40th of the box a row is sub-pixel type
  # anyway, and an unbounded budget would render that many filler divs.
  @max_items 40

  defp parse_items(n) when is_integer(n), do: n |> max(1) |> min(@max_items)

  defp parse_items(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> min(n, @max_items)
      _ -> 6
    end
  end

  defp parse_items(_), do: 6

  @impl true
  def render(assigns) do
    shown = Enum.take(Enum.sort_by(assigns.stats, &elem(&1, 0)), assigns.items)

    assigns =
      assign(assigns,
        shown: shown,
        beyond: max(map_size(assigns.stats) - assigns.items, 0),
        # Empty slots pad the table to the full row budget, so slot height —
        # and therefore type size — depends only on the "items" setting, not
        # on how many stats the module happens to expose.
        filler: max(assigns.items - length(shown), 0)
      )

    ~H"""
    <%!-- Views are honored verbatim (user-chosen). "detailed" is the worked
    example of the N-SLOT pattern: the box divides into the user-set number of
    row slots (settings "items"), each row's type scales to its slot via cq
    units — everything always fits, nothing scrolls. "compact" is the worked
    example of pure cq type scaling (one big count filling the box). --%>
    <div class="card bg-base-100 h-full overflow-hidden [container-type:size]">
      <div class="card-body flex h-full min-h-0 flex-col gap-[2cqmin] overflow-hidden p-[4cqmin]">
        <h3 class="card-title text-[8cqmin] leading-tight">
          {module_label(@module_key)}
        </h3>

        <p :if={@stats == %{}} class="text-[7cqmin] text-base-content/50">
          {Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "No stats — pick a module in this widget's settings."
          )}
        </p>

        <div
          :if={@stats != %{} and @view == "detailed"}
          class="flex min-h-0 flex-1 flex-col"
        >
          <div
            :for={{key, value} <- @shown}
            class="flex min-h-0 flex-1 items-center justify-between gap-2 [container-type:size]"
          >
            <span class="truncate text-[55cqh] leading-none text-base-content/60">{key}</span>
            <span class="shrink-0 font-mono text-[55cqh] leading-none">{inspect(value)}</span>
          </div>
          <div :for={_pad <- 1..@filler//1} class="min-h-0 flex-1"></div>
          <div
            :if={@beyond > 0}
            class="pt-[1cqmin] text-right text-[5cqmin] leading-none text-base-content/40"
          >
            +{@beyond} {Gettext.gettext(PhoenixKitWeb.Gettext, "more")}
          </div>
        </div>

        <div
          :if={@stats != %{} and @view == "compact"}
          class="flex min-h-0 flex-1 flex-col items-center justify-center"
        >
          <span class="font-bold text-[30cqmin] leading-none">
            {map_size(@stats)}
          </span>
          <span class="text-[7cqmin] text-base-content/50">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "stats")}
          </span>
        </div>
      </div>
    </div>
    """
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
