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

  @enforce_keys [:key, :name, :component]
  defstruct key: nil,
            name: nil,
            description: nil,
            icon: "hero-square-2-stack",
            module_key: nil,
            component: nil,
            default_size: %{w: 4, h: 2},
            min_size: %{w: 2, h: 1},
            max_size: %{w: 12, h: 8},
            settings_schema: [],
            category: "General",
            # :builtin or the provider module that contributed it
            source: :builtin

  @type size :: %{w: pos_integer(), h: pos_integer()}

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
          category: String.t(),
          source: :builtin | module()
        }

  @doc """
  Normalize a provider-supplied plain map into a `%Widget{}`.

  Returns `{:ok, widget}` or `{:error, reason}`. Invalid widgets are dropped by
  the registry (and logged) rather than crashing discovery.
  """
  @spec from_map(map(), source :: :builtin | module()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map, source) do
    with {:ok, key} <- fetch(map, :key),
         {:ok, name} <- fetch(map, :name),
         {:ok, component} <- fetch(map, :component),
         true <- Code.ensure_loaded?(component) || {:error, {:component_not_loaded, component}} do
      {:ok,
       %__MODULE__{
         key: to_string(key),
         name: to_string(name),
         description: map[:description],
         icon: map[:icon] || "hero-square-2-stack",
         module_key: map[:module_key] && to_string(map[:module_key]),
         component: component,
         default_size: normalize_size(map[:default_size], %{w: 4, h: 2}),
         min_size: normalize_size(map[:min_size], %{w: 2, h: 1}),
         max_size: normalize_size(map[:max_size], %{w: 12, h: 8}),
         settings_schema: List.wrap(map[:settings_schema]),
         category: map[:category] || "General",
         source: source
       }}
    else
      {:error, _} = err -> err
      false -> {:error, :invalid_component}
    end
  end

  @doc "Default settings map derived from a widget type's `settings_schema`."
  @spec default_settings(t()) :: map()
  def default_settings(%__MODULE__{settings_schema: schema}) do
    Map.new(schema, fn field -> {field.key, field[:default]} end)
  end

  defp fetch(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp normalize_size(%{w: w, h: h}, _default) when is_integer(w) and is_integer(h),
    do: %{w: w, h: h}

  defp normalize_size(_, default), do: default
end
