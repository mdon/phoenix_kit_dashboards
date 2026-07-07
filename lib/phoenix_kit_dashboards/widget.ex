defmodule PhoenixKitDashboards.Widget do
  @moduledoc """
  A widget **type** — the catalog entry that describes a kind of widget that can
  be placed on a dashboard.

  Widgets come from two places:

  1. **Built-in widgets** shipped by this module (note, clock, module-stats…).
  2. **Provider widgets** contributed by any other PhoenixKit module.

  ## The provider contract (decoupled by design)

  A provider module exposes widgets by defining a zero-arity
  `phoenix_kit_widgets/0` that returns a list of **plain maps**. It does NOT
  depend on `phoenix_kit_dashboards` at all — the dashboards module normalizes
  the maps into `%Widget{}` structs via `from_map/2`. This keeps the dependency
  arrow pointing one way: data modules know nothing about dashboards.

      # in phoenix_kit_emails.ex
      def phoenix_kit_widgets do
        [
          %{
            key: "emails.deliverability",
            name: "Deliverability",
            description: "Bounce / complaint rates over time",
            icon: "hero-envelope",
            module_key: "emails",
            component: PhoenixKitEmails.Widgets.DeliverabilityLive,
            default_size: %{w: 6, h: 2},
            min_size: %{w: 3, h: 1},
            settings_schema: [
              %{key: "window", type: :select, label: "Window",
                options: ["7d", "30d", "90d"], default: "30d"}
            ]
          }
        ]
      end

  `:component` is a `Phoenix.LiveComponent` module. The dashboard host renders it
  with `<.live_component module={w.component} id={instance_id} settings={...}
  scope={...} />`, so each widget owns its own data loading and refresh lifecycle.

  ## Settings schema

  Each field map drives one input in the generated per-widget settings form:

      %{key: "window", type: :select, label: "Window",
        options: ["7d", "30d", "90d"], default: "30d"}

  Supported `:type` values: `:string`, `:text`, `:number`, `:boolean`, `:select`.
  """

  alias PhoenixKitDashboards.Breakpoints

  @enforce_keys [:key, :name, :component]
  defstruct key: nil,
            name: nil,
            description: nil,
            icon: "hero-square-2-stack",
            module_key: nil,
            component: nil,
            default_size: %{w: 4, h: 2},
            min_size: %{w: 2, h: 1},
            # Width cap = the largest breakpoint tier's columns (16, the TV row);
            # each tier clamps placements to its own column count on top.
            max_size: %{w: 16, h: 8},
            settings_schema: [],
            # Optional named render variants (e.g. detailed vs simple vs color
            # grid). Empty = a single intrinsic view. The selected view key +
            # the instance's size are handed to the component so one widget can
            # render several densities/layouts.
            views: [],
            # Live refresh: when set (milliseconds), the host periodically
            # `send_update/2`s the widget so it re-queries. nil = static.
            refresh_interval: nil,
            category: "General",
            # The provider module that contributed this widget (via its
            # phoenix_kit_widgets/0), set by from_map/2.
            source: nil

  @type size :: %{w: pos_integer(), h: pos_integer()}

  @type view :: %{required(:key) => String.t(), required(:name) => String.t()}

  @type settings_field :: %{
          required(:key) => String.t(),
          required(:type) => :string | :text | :number | :boolean | :select,
          optional(:label) => String.t(),
          optional(:options) => [String.t()],
          optional(:default) => term()
        }

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t() | nil,
          icon: String.t(),
          module_key: String.t() | nil,
          component: module(),
          default_size: size(),
          min_size: size(),
          max_size: size(),
          settings_schema: [settings_field()],
          views: [view()],
          refresh_interval: pos_integer() | nil,
          category: String.t(),
          source: module() | nil
        }

  @doc """
  Normalize a provider-supplied plain map into a `%Widget{}`.

  Returns `{:ok, widget}` or `{:error, reason}`. Invalid widgets are dropped by
  the registry (and logged) rather than crashing discovery.
  """
  @spec from_map(term(), source :: module()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map, source) do
    with {:ok, key} <- fetch(map, :key),
         {:ok, name} <- fetch(map, :name),
         {:ok, component} <- fetch(map, :component),
         true <- is_atom(component) || {:error, {:invalid_component, component}},
         true <- Code.ensure_loaded?(component) || {:error, {:component_not_loaded, component}},
         true <-
           module?(component, Phoenix.LiveComponent) ||
             {:error, {:not_a_live_component, component}} do
      {default_size, min_size, max_size} =
        sanitized_sizes(
          normalize_size(map[:default_size], %{w: 4, h: 2}),
          normalize_size(map[:min_size], %{w: 2, h: 1}),
          normalize_size(map[:max_size], %{w: Breakpoints.max_cols(), h: 8})
        )

      {:ok,
       %__MODULE__{
         key: to_string(key),
         name: to_string(name),
         description: map[:description],
         icon: map[:icon] || "hero-square-2-stack",
         module_key: map[:module_key] && to_string(map[:module_key]),
         component: component,
         default_size: default_size,
         min_size: min_size,
         max_size: max_size,
         settings_schema: normalize_settings_schema(map[:settings_schema]),
         views: normalize_views(map[:views]),
         refresh_interval: normalize_interval(map[:refresh_interval]),
         category: map[:category] || "General",
         source: source
       }}
    else
      {:error, _} = err -> err
      false -> {:error, :invalid_component}
    end
  end

  # A provider list can contain non-map junk; drop it rather than crash discovery.
  def from_map(_other, _source), do: {:error, :not_a_map}

  # Does `module` implement `behaviour`? Guarded so a component that isn't a
  # LiveComponent is dropped at discovery, not at render time.
  defp module?(module, behaviour) do
    behaviours = module.module_info(:attributes) |> Keyword.get(:behaviour, [])
    behaviour in behaviours
  rescue
    _ -> false
  end

  @doc "Default settings map derived from a widget type's `settings_schema`."
  @spec default_settings(t()) :: map()
  def default_settings(%__MODULE__{settings_schema: schema}) do
    Map.new(schema, fn field -> {field.key, field[:default]} end)
  end

  @doc """
  The default view key for a widget type: the first declared view, or `nil` when
  the widget has a single intrinsic view.
  """
  @spec default_view(t()) :: String.t() | nil
  def default_view(%__MODULE__{views: [%{key: key} | _]}), do: key
  def default_view(%__MODULE__{}), do: nil

  # Normalize provider-supplied `:views` (plain maps with :key/:name) into
  # `[%{key: String, name: String}]`, dropping malformed entries.
  defp normalize_views(views) when is_list(views) do
    for v <- views, is_map(v), v[:key] || v["key"] do
      key = v[:key] || v["key"]
      name = v[:name] || v["name"] || to_string(key)
      %{key: to_string(key), name: to_string(name)}
    end
  end

  defp normalize_views(_), do: []

  @valid_field_types [:string, :text, :number, :boolean, :select]

  # Validate provider-supplied settings_schema: each field must be a map with a
  # `:key` and a supported `:type`. Malformed fields are dropped, and every kept
  # field is normalized to atom keys — so the generated settings form and
  # `default_settings/1` can never crash on a bad provider field.
  defp normalize_settings_schema(schema) when is_list(schema) do
    for field <- schema,
        is_map(field),
        key = field[:key] || field["key"],
        key not in [nil, ""],
        is_binary(key) or is_atom(key) do
      %{
        key: to_string(key),
        type: field_type(field[:type] || field["type"]),
        label: field[:label] || field["label"],
        options: List.wrap(field[:options] || field["options"]),
        default: Map.get(field, :default, Map.get(field, "default"))
      }
    end
  end

  defp normalize_settings_schema(_), do: []

  defp field_type(t) when t in @valid_field_types, do: t
  defp field_type(_), do: :string

  # Refresh interval is clamped to a 1s floor so a provider can't accidentally
  # pin the host into a tight re-query loop.
  defp normalize_interval(ms) when is_integer(ms) and ms > 0, do: max(ms, 1000)
  defp normalize_interval(_), do: nil

  defp fetch(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp normalize_size(%{w: w, h: h}, _default) when is_integer(w) and is_integer(h),
    do: %{w: w, h: h}

  defp normalize_size(_, default), do: default

  # Keep the size bounds coherent — min <= default <= max, width within the
  # LARGEST breakpoint tier's columns (16, the TV row; each tier clamps
  # placements to its own count), every dimension >= 1 — so a malformed provider
  # (e.g. `min_w > max_w`) can't make the resize hook's client-side limits
  # disagree with what the server clamps to and renders.
  defp sanitized_sizes(default, min, max) do
    cap = Breakpoints.max_cols()
    row_cap = PhoenixKitDashboards.Grid.max_rows()
    min_w = clamp(min.w, 1, cap)
    max_w = clamp(max.w, min_w, cap)
    min_h = clamp(min.h, 1, row_cap)
    max_h = clamp(max.h, min_h, row_cap)

    {
      %{w: clamp(default.w, min_w, max_w), h: clamp(default.h, min_h, max_h)},
      %{w: min_w, h: min_h},
      %{w: max_w, h: max_h}
    }
  end

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
