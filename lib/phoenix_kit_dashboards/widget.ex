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
  view={...} size={%{w: w, h: h}} scope={...} />` — the selected view key and the
  instance's current span ride along, so one widget can render several
  densities/layouts. Each widget owns its own data loading and refresh
  lifecycle.

  ## Settings schema

  Each field map drives one input in the generated per-widget settings form:

      %{key: "window", type: :select, label: "Window",
        options: ["7d", "30d", "90d"], default: "30d"}

  Supported `:type` values: `:string`, `:text`, `:number`, `:boolean`, `:select`.
  Select `options` may be plain strings or `{label, value}` tuples (the label is
  translated at render when a translation exists).
  """

  alias PhoenixKitDashboards.Lattice

  @enforce_keys [:key, :name, :component]
  defstruct key: nil,
            name: nil,
            description: nil,
            icon: "hero-square-2-stack",
            module_key: nil,
            component: nil,
            # Sizes are in LATTICE units (25px nominal square cells).
            default_size: %{w: 16, h: 8},
            min_size: %{w: 8, h: 4},
            # Width cap = the max per-layout lattice dimension (160); each
            # layout clamps placements to its own dimensions on top.
            max_size: %{w: 160, h: 160},
            settings_schema: [],
            # Optional named render variants (e.g. detailed vs simple vs color
            # grid). Empty = a single intrinsic view. The selected view key +
            # the instance's size are handed to the component so one widget can
            # render several densities/layouts. A view may declare its own
            # `min_size` (an analog clock needs a squarer floor than a text
            # one) — resolved via `min_size_for/2`.
            views: [],
            # Live refresh: when set (milliseconds, floored to 1000 so a
            # provider can't pin the host into a tight loop), the host
            # periodically `send_update/2`s the widget so it re-queries.
            # nil = static.
            refresh_interval: nil,
            category: "General",
            # The provider module that contributed this widget (via its
            # phoenix_kit_widgets/0), set by from_map/2.
            source: nil

  @type size :: %{w: pos_integer(), h: pos_integer()}

  @type view :: %{
          required(:key) => String.t(),
          required(:name) => String.t(),
          optional(:min_size) => size()
        }

  @type settings_field :: %{
          required(:key) => String.t(),
          required(:type) => :string | :text | :number | :boolean | :select,
          optional(:label) => String.t(),
          optional(:options) => [String.t() | {String.t(), String.t()}],
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
    # The contract is "plain maps" — accept atom OR string keys throughout.
    map = Map.new(map, fn {k, v} -> {to_atom_key(k), v} end)

    with {:ok, key} <- fetch(map, :key),
         true <- is_binary(key) or is_atom(key) or {:error, {:invalid_key, key}},
         {:ok, name} <- fetch(map, :name),
         true <- is_binary(name) or is_atom(name) or {:error, {:invalid_name, name}},
         {:ok, component} <- fetch(map, :component),
         true <- is_atom(component) || {:error, {:invalid_component, component}},
         true <- Code.ensure_loaded?(component) || {:error, {:component_not_loaded, component}},
         true <-
           module?(component, Phoenix.LiveComponent) ||
             {:error, {:not_a_live_component, component}} do
      # Declared :max_size is deliberately IGNORED: on the screenful lattice
      # the USER owns the box size and content self-fits, so a provider max
      # cap serves nobody (it's a relic of the old auto-flow grid).
      {default_size, min_size, max_size} =
        sanitized_sizes(
          normalize_size(map[:default_size], %{w: 16, h: 8}),
          normalize_size(map[:min_size], %{w: 8, h: 4}),
          %{w: Lattice.max_dim(), h: Lattice.max_dim()}
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
         views: normalize_views(map[:views], max_size),
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

  @doc """
  The minimum size for an instance showing `view_key` — the view's own
  `min_size` when it declares one (an analog clock needs more room than a text
  one), else the widget type's. `nil` resolves through the default view, so
  instances created before a widget declared views get the right floor too.
  """
  @spec min_size_for(t(), String.t() | nil) :: size()
  def min_size_for(%__MODULE__{} = widget, nil) do
    case default_view(widget) do
      nil -> widget.min_size
      key -> min_size_for(widget, key)
    end
  end

  def min_size_for(%__MODULE__{} = widget, view_key) do
    case Enum.find(widget.views, &(&1.key == view_key)) do
      %{min_size: min} -> min
      _ -> widget.min_size
    end
  end

  # Normalize provider-supplied `:views` (plain maps with :key/:name and an
  # optional per-view :min_size) into `[%{key: String, name: String[, min_size:
  # size]}]`, dropping malformed entries. A view's min is clamped into
  # [1, the widget's max] per dimension so the resize limits stay coherent.
  defp normalize_views(views, max_size) when is_list(views) do
    for v <- views, is_map(v), v[:key] || v["key"] do
      key = v[:key] || v["key"]
      name = v[:name] || v["name"] || to_string(key)
      put_view_min(%{key: to_string(key), name: to_string(name)}, v, max_size)
    end
  end

  defp normalize_views(_, _max_size), do: []

  defp put_view_min(view, raw, max_size) do
    case raw[:min_size] || raw["min_size"] do
      %{w: w, h: h} when is_integer(w) and is_integer(h) ->
        Map.put(view, :min_size, %{w: clamp(w, 1, max_size.w), h: clamp(h, 1, max_size.h)})

      _ ->
        view
    end
  end

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
        is_binary(key) or is_atom(key),
        # `]`/`[` in a form-field name breaks Phoenix param nesting (the value
        # would come back as a nested map the widget can't read).
        Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, to_string(key)) do
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

  # Only WELL-KNOWN string keys convert (String.to_existing_atom would still
  # let a provider grow the atom table with arbitrary map keys via except).
  @known_keys ~w(key name description icon module_key component default_size min_size max_size
                 settings_schema views refresh_interval category)
  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k) and k in @known_keys, do: String.to_atom(k)
  defp to_atom_key(k), do: k

  defp normalize_size(%{w: w, h: h}, _default) when is_integer(w) and is_integer(h),
    do: %{w: w, h: h}

  defp normalize_size(_, default), do: default

  # Keep the size bounds coherent — min <= default <= max, both dimensions
  # within the lattice bound (160; each layout clamps placements to its own
  # dimensions), every dimension >= 1 — so a malformed provider (e.g.
  # `min_w > max_w`) can't make the resize hook's client-side limits disagree
  # with what the server clamps to and renders.
  defp sanitized_sizes(default, min, max) do
    cap = Lattice.max_dim()
    row_cap = Lattice.max_dim()
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
