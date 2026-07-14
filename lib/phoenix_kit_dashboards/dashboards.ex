defmodule PhoenixKitDashboards.Dashboards do
  @moduledoc """
  Context for dashboard pages and their widget layouts.

  Persistence follows the `phoenix_kit_crm` precedent: the dashboard row holds a
  JSONB `layout` list of widget instances, read and written whole. The host app's
  repo is reached via `PhoenixKit.RepoHelper.repo/0` — this module never owns a
  repo of its own.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitDashboards.Breakpoints
  alias PhoenixKitDashboards.Grid
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  # Free/pixel-canvas widget size bounds (px).
  @free_min_px 60
  @free_max_px 4000
  # Per-dashboard grid dimension bounds. Columns cap above the largest tier
  # default (16) for finer granularity; rows cap at the hard placement bound.
  @max_grid_cols 24
  # px per grid col/row when seeding a new widget's pixel geometry from its span.
  @pixel_seed_col 120
  @pixel_seed_row 140

  @doc """
  Dashboards visible to a user: their own personal ones, all shared/system ones,
  and any `role`-scoped ones whose `role_uuid` is in `role_uuids` (the user's
  roles — empty by default, so `/1` keeps the personal + system behaviour).
  """
  @spec list_for_user(user_uuid :: String.t(), role_uuids :: [String.t()]) :: [Dashboard.t()]
  def list_for_user(user_uuid, role_uuids \\ [])
      when is_binary(user_uuid) and is_list(role_uuids) do
    query =
      from(d in Dashboard,
        where:
          d.owner_user_uuid == ^user_uuid or d.scope == "system" or
            (d.scope == "role" and d.role_uuid in ^role_uuids),
        order_by: [asc: d.position, asc: d.inserted_at]
      )

    repo().all(query)
  end

  @doc "Fetch one dashboard by uuid, or nil."
  @spec get(String.t()) :: Dashboard.t() | nil
  def get(uuid) when is_binary(uuid), do: repo().get(Dashboard, uuid)

  @doc """
  Whether a dashboard is visible to a user — the single scope-visibility rule,
  mirroring `list_for_user/2`'s WHERE clause. Both LiveViews use this so the list
  page and the builder never disagree about access.
  """
  @spec visible_to?(Dashboard.t(), user_uuid :: String.t() | nil, role_uuids :: [String.t()]) ::
          boolean()
  def visible_to?(%Dashboard{} = dashboard, user_uuid, role_uuids \\ []) do
    dashboard.scope == "system" or
      (dashboard.scope == "role" and dashboard.role_uuid in role_uuids) or
      (is_binary(user_uuid) and dashboard.owner_user_uuid == user_uuid)
  end

  @doc """
  Return the user's default personal dashboard, creating an empty one on first
  access. This is the page shown at the module's landing route.
  """
  @spec get_or_create_default(user_uuid :: String.t()) :: Dashboard.t()
  def get_or_create_default(user_uuid) when is_binary(user_uuid) do
    # Ordered so a duplicate default (a rare concurrent-first-access race — no
    # unique index guards is_default) resolves to the SAME row on every read.
    query =
      from(d in Dashboard,
        where: d.owner_user_uuid == ^user_uuid and d.is_default == true,
        order_by: [asc: d.inserted_at, asc: d.uuid],
        limit: 1
      )

    case repo().one(query) do
      nil ->
        {:ok, dashboard} =
          create(
            %{
              title: "My Dashboard",
              scope: "personal",
              owner_user_uuid: user_uuid,
              is_default: true
            },
            actor_uuid: user_uuid
          )

        dashboard

      dashboard ->
        dashboard
    end
  end

  # Most `-N` suffixes tried before giving up on a unique slug (a runaway guard;
  # a real user never has this many same-titled dashboards).
  @max_slug_attempts 50

  @doc """
  Create a dashboard. The slug (derived from the title) is auto-uniquified per
  owner — a blank or repeated title gets a `-2`, `-3`, … suffix instead of failing
  the `[owner_user_uuid, slug]` unique constraint. A free slug is picked by query
  (so nil-owner/system dashboards uniquify too, where Postgres treats NULLs as
  distinct) and a constraint clash under concurrency is retried.
  """
  @spec create(map(), keyword()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs, opts \\ []) do
    base = attrs |> attr(:title) |> Kernel.||("") |> Dashboard.slugify()
    insert_unique(attrs, base, attr(attrs, :owner_user_uuid), 0, opts)
  end

  defp insert_unique(attrs, base, owner, attempt, opts) do
    result =
      %Dashboard{}
      |> Dashboard.changeset(put_slug(attrs, free_slug(base, owner)))
      |> repo().insert()

    case result do
      {:error, %Ecto.Changeset{errors: errors}} ->
        # Lost the slug to a concurrent insert between the query and ours — retry.
        if attempt < @max_slug_attempts and Keyword.has_key?(errors, :slug),
          do: insert_unique(attrs, base, owner, attempt + 1, opts),
          else: result

      {:ok, _dashboard} ->
        log_on_ok(result, "dashboard.created", opts)
    end
  end

  # `base`, or the first `base-2`/`base-3`/… not already taken by this owner.
  defp free_slug(base, owner) do
    taken = owner_slugs(base, owner)

    if MapSet.member?(taken, base) do
      2
      |> Stream.iterate(&(&1 + 1))
      |> Stream.map(&"#{base}-#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  defp owner_slugs(base, owner) do
    query = from(d in Dashboard, where: ilike(d.slug, ^"#{base}%"), select: d.slug)

    query =
      if is_nil(owner),
        do: where(query, [d], is_nil(d.owner_user_uuid)),
        else: where(query, [d], d.owner_user_uuid == ^owner)

    query |> repo().all() |> MapSet.new()
  end

  # Read an attr by atom key, tolerating a string-keyed map.
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  # Inject the slug with the SAME key style as `attrs` — Ecto's `cast/4` rejects a
  # map with mixed atom+string keys, so a string-keyed attrs map must get "slug".
  defp put_slug(attrs, slug) do
    if attrs == %{} or Enum.any?(attrs, fn {k, _} -> is_atom(k) end),
      do: Map.put(attrs, :slug, slug),
      else: Map.put(attrs, "slug", slug)
  end

  @doc """
  Clone a dashboard into a new **personal** dashboard owned by `user_uuid` —
  copies the layout (with fresh instance ids) and config. Lets a user take a
  private, editable copy of a shared/system dashboard.
  """
  @spec clone(Dashboard.t(), user_uuid :: String.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def clone(%Dashboard{} = source, user_uuid, opts \\ []) when is_binary(user_uuid) do
    layout = Enum.map(source.layout, fn inst -> Map.put(inst, "id", UUIDv7.generate()) end)

    create(
      %{
        title: "#{source.title} (copy)",
        scope: "personal",
        owner_user_uuid: user_uuid,
        layout: layout,
        config: source.config
      },
      # A clone logs as dashboard.created like any create, but stays
      # distinguishable in the audit trail via the source pointer.
      Keyword.put(opts, :log_extra, %{"cloned_from" => source.uuid})
    )
  end

  @doc "Update a dashboard's metadata."
  @spec update(Dashboard.t(), map(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def update(%Dashboard{} = dashboard, attrs, opts \\ []) do
    dashboard
    |> Dashboard.changeset(attrs)
    |> repo().update()
    |> log_on_ok("dashboard.updated", opts)
  end

  @doc "Delete a dashboard."
  @spec delete(Dashboard.t(), keyword()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Dashboard{} = dashboard, opts \\ []) do
    dashboard
    |> repo().delete()
    |> log_on_ok("dashboard.deleted", opts)
  end

  @doc "Persist a new full layout (the hot path while editing the grid)."
  @spec save_layout(Dashboard.t(), [map()]) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def save_layout(%Dashboard{} = dashboard, layout) when is_list(layout) do
    dashboard
    |> Dashboard.layout_changeset(layout)
    |> repo().update()
  end

  @doc """
  Add a widget instance for `widget_key` to a dashboard's layout, seeded with the
  widget type's default size and settings — the grid placement takes the first
  FREE cell on the home tier, the pixel geometry stacks below the existing
  widgets. Returns the updated dashboard.
  """
  @spec add_widget(Dashboard.t(), widget_key :: String.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, term()}
  def add_widget(%Dashboard{} = dashboard, widget_key, opts \\ []) do
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        dashboard
        |> save_layout(dashboard.layout ++ [new_instance(dashboard, widget)])
        |> log_on_ok("dashboard.widget_added", opts, %{"widget_key" => widget.key})
    end
  end

  @doc """
  Add a widget at an explicit grid cell on `bp` (a catalog drag-out drop) —
  `x`/`y` 0-based, clamped into the tier; a spot overlapping another widget is
  refused with `{:error, :occupied}` (the drag hook only offers free cells).
  Marks the breakpoint customized. Logs `dashboard.widget_added`.
  """
  @spec add_widget_at(
          Dashboard.t(),
          widget_key :: String.t(),
          String.t(),
          integer(),
          integer(),
          keyword()
        ) :: {:ok, Dashboard.t()} | {:error, :unknown_widget | :occupied | Ecto.Changeset.t()}
  def add_widget_at(%Dashboard{} = dashboard, widget_key, bp, x, y, opts \\ [])
      when is_binary(bp) and is_integer(x) and is_integer(y) do
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        # Pin the tier first so placing the new widget can't shift the others.
        dashboard = materialize_grid(dashboard, bp)
        cols = grid_cols(dashboard, bp)
        w = min(widget.default_size.w, cols)
        h = widget.default_size.h
        x = clamp(x, 0, max(cols - w, 0))
        y = clamp(y, 0, max(grid_rows(dashboard, bp) - h, 0))
        others = Enum.map(dashboard.layout, &Layout.placement(&1, bp))

        if Grid.collides?(x, y, w, h, others) do
          {:error, :occupied}
        else
          instance =
            dashboard
            |> new_instance(widget)
            |> Layout.put_placement(bp, %{
              "x" => x,
              "y" => y,
              "w" => w,
              "h" => h,
              "hidden" => false,
              "pos" => length(dashboard.layout)
            })

          dashboard
          |> save_customized(dashboard.layout ++ [instance], bp)
          |> log_on_ok("dashboard.widget_added", opts, %{"widget_key" => widget.key})
        end
    end
  end

  @doc """
  Add a widget at an explicit pixel position on the free canvas (a catalog
  drag-out drop) — `fx`/`fy` clamped to the top-left; size is the widget type's
  default seed. Logs `dashboard.widget_added`.
  """
  @spec add_widget_px(Dashboard.t(), widget_key :: String.t(), integer(), integer(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, :unknown_widget | Ecto.Changeset.t()}
  def add_widget_px(%Dashboard{} = dashboard, widget_key, fx, fy, opts \\ [])
      when is_integer(fx) and is_integer(fy) do
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        instance =
          dashboard
          |> new_instance(widget)
          |> Layout.put_pixel(%{"fx" => max(fx, 0), "fy" => max(fy, 0)})

        dashboard
        |> save_layout(dashboard.layout ++ [instance])
        |> log_on_ok("dashboard.widget_added", opts, %{"widget_key" => widget.key})
    end
  end

  # A fresh widget instance with the default geometry: `pixel` stacked below the
  # existing widgets, and the grid placement seeded at the home tier's first FREE
  # cell (the home tier is designed — its stored placement renders verbatim, so
  # the seed span must already fit its columns).
  defp new_instance(dashboard, %Widget{} = widget) do
    home = home_bp(dashboard)
    cols = grid_cols(dashboard, home)
    w = widget.default_size.w
    h = widget.default_size.h
    seed_w = min(w, cols)

    occupied = dashboard |> resolve_items(home) |> Enum.map(fn {_i, p} -> p end)
    {x, y} = Grid.first_free(occupied, seed_w, h, cols) || {0, Grid.below_all(occupied)}

    %{
      "id" => UUIDv7.generate(),
      "widget_key" => widget.key,
      "view" => Widget.default_view(widget),
      "settings" => Widget.default_settings(widget),
      "pixel" => %{
        "fx" => 0,
        "fy" => next_pixel_y(dashboard.layout),
        "fw" => w * @pixel_seed_col,
        "fh" => h * @pixel_seed_row
      },
      "bp" => %{
        home => %{
          "x" => x,
          "y" => y,
          "w" => seed_w,
          "h" => h,
          "hidden" => false,
          "pos" => length(dashboard.layout)
        }
      }
    }
  end

  @doc """
  Re-pack a **breakpoint's** grid to `ordered_ids`: every widget gets the first
  free cell in that order (reflow + compact), so the ids' order becomes the
  reading order. Unknown ids are filtered/deduped; unnamed widgets keep their
  relative order after the named ones. Marks the breakpoint customized. A layout
  tweak — not activity-logged.
  """
  @spec reorder_widgets(Dashboard.t(), String.t(), [String.t()]) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def reorder_widgets(%Dashboard{} = dashboard, bp, ordered_ids)
      when is_binary(bp) and is_list(ordered_ids) do
    dashboard = materialize_grid(dashboard, bp)
    cols = grid_cols(dashboard, bp)

    order =
      ordered_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.with_index() |> Map.new()

    ranked =
      dashboard.layout
      |> Enum.with_index()
      |> Enum.sort_by(fn {item, idx} ->
        {Map.get(order, item["id"], map_size(order) + idx), idx}
      end)

    packed =
      ranked
      |> Enum.map(fn {item, _idx} -> Layout.placement(item, bp) end)
      |> Grid.compact(cols)

    placements =
      ranked
      |> Enum.zip(packed)
      |> Enum.with_index()
      |> Map.new(fn {{{item, _idx}, placement}, pos} ->
        {item["id"], Map.put(placement, "pos", pos)}
      end)

    layout =
      Enum.map(dashboard.layout, fn item ->
        Layout.put_placement(item, bp, Map.fetch!(placements, item["id"]))
      end)

    save_customized(dashboard, layout, bp)
  end

  @doc """
  Place a grid widget at an explicit cell — `x` (column) / `y` (row), 0-based —
  on `bp`, marking that breakpoint customized. The widget may go anywhere on the
  grid (gaps are fine); `x` is clamped so the span stays within the columns, `y`
  within `Grid.max_rows/0`. A spot overlapping another widget is refused with
  `{:error, :occupied}` (the drag hook never offers one; this guards stale/
  crafted events). A layout tweak — not activity-logged.
  """
  @spec place_widget_grid(
          Dashboard.t(),
          instance_id :: String.t(),
          String.t(),
          integer(),
          integer()
        ) :: {:ok, Dashboard.t()} | {:error, :occupied | Ecto.Changeset.t()}
  def place_widget_grid(%Dashboard{} = dashboard, instance_id, bp, x, y)
      when is_binary(bp) and is_integer(x) and is_integer(y) do
    dashboard = materialize_grid(dashboard, bp)

    case Enum.find(dashboard.layout, &(&1["id"] == instance_id)) do
      nil -> {:ok, dashboard}
      item -> place_at_cell(dashboard, item, instance_id, bp, x, y)
    end
  end

  defp place_at_cell(dashboard, item, instance_id, bp, x, y) do
    cols = grid_cols(dashboard, bp)
    placement = Layout.placement(item, bp)
    w = min(placement["w"], cols)
    h = placement["h"]
    x = clamp(x, 0, max(cols - w, 0))
    y = clamp(y, 0, max(grid_rows(dashboard, bp) - h, 0))

    others =
      dashboard.layout
      |> Enum.reject(&(&1["id"] == instance_id))
      |> Enum.map(&Layout.placement(&1, bp))

    if Grid.collides?(x, y, w, h, others) do
      {:error, :occupied}
    else
      layout =
        Enum.map(dashboard.layout, fn
          %{"id" => ^instance_id} = inst ->
            Layout.put_placement(inst, bp, %{"x" => x, "y" => y, "w" => w})

          inst ->
            inst
        end)

      save_customized(dashboard, layout, bp)
    end
  end

  @doc """
  Set a grid widget's `w`/`h` span for `bp`, marking that breakpoint customized.
  Clamped to the widget type's min/max — and to what actually FITS at the
  widget's cell: it grows until blocked by a neighbouring widget or the grid
  edge (`Grid.fit_size/8`), never onto another widget. A layout tweak — not
  activity-logged.
  """
  @spec resize_widget(
          Dashboard.t(),
          instance_id :: String.t(),
          String.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def resize_widget(%Dashboard{} = dashboard, instance_id, bp, w, h) when is_binary(bp) do
    dashboard = materialize_grid(dashboard, bp)
    cols = grid_cols(dashboard, bp)

    others =
      dashboard.layout
      |> Enum.reject(&(&1["id"] == instance_id))
      |> Enum.map(&Layout.placement(&1, bp))

    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst -> resize_instance(inst, bp, w, h, others, cols)
        inst -> inst
      end)

    save_customized(dashboard, layout, bp)
  end

  defp resize_instance(inst, bp, w, h, others, cols) do
    bounds = size_bounds(inst)
    placement = Layout.placement(inst, bp)

    case {placement["x"], placement["y"]} do
      {x, y} when is_integer(x) and is_integer(y) ->
        {w2, h2} = Grid.fit_size(x, y, w, h, placement["h"], others, cols, bounds)

        # fit_size floors at the view's min — when even that floor doesn't fit
        # (a raised per-view minimum in a tight corner), keep the current size
        # rather than overlap a neighbour.
        if Grid.collides?(x, y, w2, h2, others) do
          inst
        else
          Layout.put_placement(inst, bp, %{"w" => w2, "h" => h2})
        end

      _ ->
        # Unplaced (shouldn't survive materialize_grid; defensive): plain
        # bounds clamp.
        {min, max} = bounds

        Layout.put_placement(inst, bp, %{
          "w" => clamp(w, min.w, min(max.w, cols)),
          "h" => clamp(h, min.h, max.h)
        })
    end
  end

  @doc """
  Show/hide a grid widget on `bp` (so smaller screens can drop non-essentials),
  marking that breakpoint customized. A layout tweak — not activity-logged.
  """
  @spec hide_widget(Dashboard.t(), instance_id :: String.t(), String.t(), boolean()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def hide_widget(%Dashboard{} = dashboard, instance_id, bp, hidden)
      when is_binary(bp) and is_boolean(hidden) do
    dashboard = materialize_grid(dashboard, bp)

    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst -> Layout.put_placement(inst, bp, %{"hidden" => hidden})
        inst -> inst
      end)

    save_customized(dashboard, layout, bp)
  end

  @doc """
  The grid column count for a dashboard at `bp` — the per-dashboard override
  (`config["breakpoints"][bp]["cols"]`, set by the builder's +/- controls) or
  the tier default. All placement math and rendering go through this so a
  resized grid stays consistent everywhere.
  """
  @spec grid_cols(Dashboard.t(), String.t()) :: pos_integer()
  def grid_cols(%Dashboard{} = dashboard, bp) do
    dim_override(dashboard, bp, "cols", 1, @max_grid_cols) || Breakpoints.cols(bp)
  end

  @doc """
  The designable grid rows for a dashboard at `bp` — the per-dashboard override
  (`config["breakpoints"][bp]["rows"]`) or the tier default. Rows only bound
  MANUAL placement and the rendered surface; the pane scrolls vertically.
  """
  @spec grid_rows(Dashboard.t(), String.t()) :: pos_integer()
  def grid_rows(%Dashboard{} = dashboard, bp) do
    dim_override(dashboard, bp, "rows", 1, Grid.max_rows()) || Breakpoints.max_rows(bp)
  end

  defp dim_override(dashboard, bp, key, lo, hi) do
    case get_in(dashboard.config, ["breakpoints", bp, key]) do
      n when is_integer(n) and n >= lo and n <= hi -> n
      _ -> nil
    end
  end

  @doc """
  Grow/shrink the grid by one column or row on `bp` (the builder's +/- header
  controls). Shrinking is refused with `{:error, :occupied}` while any widget
  occupies the column/row being removed — move the widget first. Columns are
  bounded to `1..#{@max_grid_cols}`, rows to `1..#{Grid.max_rows()}` (the hard
  placement bound). Marks the breakpoint customized (a grid dimension is a
  design decision for that tier). A layout tweak — not activity-logged.
  """
  @spec resize_grid(Dashboard.t(), String.t(), :cols | :rows, integer()) ::
          {:ok, Dashboard.t()} | {:error, :occupied | Ecto.Changeset.t()}
  def resize_grid(%Dashboard{} = dashboard, bp, dim, delta)
      when is_binary(bp) and dim in [:cols, :rows] and delta in [-1, 1] do
    {current, hi} =
      case dim do
        :cols -> {grid_cols(dashboard, bp), @max_grid_cols}
        :rows -> {grid_rows(dashboard, bp), Grid.max_rows()}
      end

    target = clamp(current + delta, 1, hi)

    cond do
      target == current ->
        {:ok, dashboard}

      delta < 0 and dim_occupied?(dashboard, bp, dim, target) ->
        {:error, :occupied}

      true ->
        # Pin resolved placements first so a dimension change can't reshuffle
        # widgets (a shrunken derived tier would otherwise re-derive).
        dashboard = materialize_grid(dashboard, bp)
        key = if dim == :cols, do: "cols", else: "rows"
        bps = Map.get(dashboard.config, "breakpoints", %{})
        bp_map = bps |> Map.get(bp, %{}) |> Map.put(key, target) |> Map.put("state", "custom")
        config = Map.put(dashboard.config, "breakpoints", Map.put(bps, bp, bp_map))

        dashboard
        |> Ecto.Changeset.change(config: config)
        |> Ecto.Changeset.force_change(:layout, dashboard.layout)
        |> repo().update()
    end
  end

  # Would shrinking to `target` cols/rows cut into any resolved placement?
  # (Hidden widgets keep their cells, so they count too.)
  defp dim_occupied?(dashboard, bp, dim, target) do
    dashboard
    |> resolve_items(bp)
    |> Enum.any?(fn {_item, p} ->
      case dim do
        :cols -> is_integer(p["x"]) and p["x"] + (p["w"] || 1) > target
        :rows -> is_integer(p["y"]) and p["y"] + (p["h"] || 1) > target
      end
    end)
  end

  @doc """
  Reset a breakpoint to auto — drops its stored per-widget placements + custom
  flag (and any grid dimension overrides) so it re-derives from the home tier.
  The home tier (the design anchor) can't be reset. Not activity-logged.
  """
  @spec reset_breakpoint(Dashboard.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def reset_breakpoint(%Dashboard{} = dashboard, bp) when is_binary(bp) do
    if bp == home_bp(dashboard) do
      {:ok, dashboard}
    else
      layout = Enum.map(dashboard.layout, &drop_bp(&1, bp))
      bps = Map.get(dashboard.config, "breakpoints", %{})
      config = Map.put(dashboard.config, "breakpoints", Map.delete(bps, bp))
      dashboard |> Ecto.Changeset.change(layout: layout, config: config) |> repo().update()
    end
  end

  defp drop_bp(%{"bp" => bps} = inst, bp) when is_map(bps),
    do: Map.put(inst, "bp", Map.delete(bps, bp))

  defp drop_bp(inst, _bp), do: inst

  @doc """
  The `{item, placement}` pairs to render at `bp` — the single render path shared
  by the builder (explicit breakpoint) and the runtime (viewport-matched), so
  preview and runtime never diverge. Every returned placement carries explicit
  cells (`x`/`y`) plus `w`/`h`/`hidden`:

    * a **designed** breakpoint renders its stored cells verbatim; stored
      placements that predate explicit cells (order-only) are packed into the
      remaining free cells in `pos` order, so old layouts keep their arrangement
      without a migration (their first edit persists the cells);
    * an **un-designed** breakpoint is derived from the nearest designed tier by
      reflow + compact: its widgets in reading order, spans clamped to the
      target's columns, packed first-fit.

  Ordered by reading order (`y`, then `x`); **hidden widgets are included** (the
  builder dims them and they keep their cells; pass `visible: true` — or filter
  `placement["hidden"]` — for the runtime).
  """
  @spec resolve_items(Dashboard.t(), String.t(), keyword()) :: [{map(), map()}]
  def resolve_items(%Dashboard{} = dashboard, bp, opts \\ []) do
    items =
      if customized?(dashboard, bp),
        do: resolve_designed(dashboard, bp),
        else: derive_tier(dashboard, bp)

    if opts[:visible], do: Enum.reject(items, fn {_i, p} -> p["hidden"] == true end), else: items
  end

  @doc """
  The **resolved** grid placement for one widget on `bp` — exactly what
  `resolve_items/3` renders for it, or `nil` if the widget isn't in the layout.
  Use this (not `Layout.placement/2`) anywhere that must match what's on screen —
  e.g. the Settings modal's inputs, so a save doesn't overwrite a derived
  placement with the default.
  """
  @spec resolve_placement(Dashboard.t(), instance_id :: String.t(), String.t()) :: map() | nil
  def resolve_placement(%Dashboard{} = dashboard, id, bp) do
    case Enum.find(resolve_items(dashboard, bp), fn {item, _p} -> item["id"] == id end) do
      nil -> nil
      {_item, placement} -> placement
    end
  end

  @doc "Whether a widget is currently hidden on `bp` (stored or derived)."
  @spec resolve_hidden?(Dashboard.t(), instance_id :: String.t(), String.t()) :: boolean()
  def resolve_hidden?(%Dashboard{} = dashboard, id, bp) do
    case resolve_placement(dashboard, id, bp) do
      nil -> false
      placement -> placement["hidden"] == true
    end
  end

  @doc """
  The dashboard's **home** breakpoint — the size it was designed at (seeded into,
  and the anchor other tiers derive from). Set from the creator's screen on first
  open; `config["home_bp"]`, defaulting to the module default (desktop) for
  dashboards created before the home concept (their widgets were seeded there).
  """
  @spec home_bp(Dashboard.t()) :: String.t()
  def home_bp(%Dashboard{config: config}) do
    case config do
      %{"home_bp" => bp} when is_binary(bp) ->
        if Breakpoints.valid?(bp), do: bp, else: Breakpoints.default()

      _ ->
        Breakpoints.default()
    end
  end

  @doc """
  Record the dashboard's home breakpoint — only when it's still unset AND the
  dashboard is empty (a brand-new one on first open); otherwise a no-op, so an
  existing dashboard's home never moves under a different viewer's screen.
  """
  @spec put_home_bp(Dashboard.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def put_home_bp(%Dashboard{} = dashboard, bp) when is_binary(bp) do
    fresh? = is_nil(get_in(dashboard.config, ["home_bp"])) and dashboard.layout == []

    if fresh? and Breakpoints.valid?(bp) do
      config = Map.put(dashboard.config, "home_bp", bp)
      dashboard |> Ecto.Changeset.change(config: config) |> repo().update()
    else
      {:ok, dashboard}
    end
  end

  @doc """
  The **designed** breakpoint to display for a viewer whose screen best fits
  `screen_bp` — that tier if it's designed, else the nearest designed tier (which
  the caller scales to fit). Never a freshly-derived tier: on open we only ever
  show views someone actually made.
  """
  @spec display_bp(Dashboard.t(), String.t()) :: String.t()
  def display_bp(%Dashboard{} = dashboard, screen_bp) when is_binary(screen_bp) do
    if customized?(dashboard, screen_bp),
      do: screen_bp,
      else: derivation_source(dashboard, screen_bp)
  end

  @doc """
  Whether a breakpoint is a **designed** view: hand-customized, or the home tier
  (always designed — it's the seed + derivation anchor).
  """
  @spec customized?(Dashboard.t(), String.t()) :: boolean()
  def customized?(%Dashboard{} = dashboard, bp) do
    get_in(dashboard.config, ["breakpoints", bp, "state"]) == "custom" or
      bp == home_bp(dashboard)
  end

  @doc """
  Free/pixel-canvas mode: place a widget at absolute pixels (`fx`, `fy`), each
  clamped to `>= 0` (top-left of the canvas). Pixel geometry is embedded so it
  never disturbs the grid placement. A layout tweak — not activity-logged.
  """
  @spec place_widget_px(Dashboard.t(), instance_id :: String.t(), integer(), integer()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def place_widget_px(%Dashboard{} = dashboard, instance_id, fx, fy) do
    update_item(dashboard, instance_id, fn inst ->
      Layout.put_pixel(inst, %{"fx" => max(fx, 0), "fy" => max(fy, 0)})
    end)
  end

  @doc """
  Free/pixel-canvas mode: set a widget's absolute pixel size (`fw`, `fh`), each
  clamped to `[@free_min_px, @free_max_px]`. A layout tweak — not activity-logged.
  """
  @spec resize_widget_px(Dashboard.t(), instance_id :: String.t(), integer(), integer()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def resize_widget_px(%Dashboard{} = dashboard, instance_id, fw, fh) do
    update_item(dashboard, instance_id, fn inst ->
      Layout.put_pixel(inst, %{
        "fw" => clamp(fw, @free_min_px, @free_max_px),
        "fh" => clamp(fh, @free_min_px, @free_max_px)
      })
    end)
  end

  @doc """
  Set the dashboard's layout mode (`"grid"` or `"free"`). Invalid values are
  ignored. A presentation tweak — not activity-logged.
  """
  @spec set_layout_mode(Dashboard.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def set_layout_mode(%Dashboard{} = dashboard, mode) do
    if mode in Dashboard.layout_modes() do
      put_config(dashboard, "mode", mode)
    else
      {:ok, dashboard}
    end
  end

  @doc """
  Restack a pixel widget: `"front"` puts it above every other widget's z,
  `"back"` below. Overlap is allowed on the free canvas — z-order makes it
  deliberate. A layout tweak — not activity-logged.
  """
  @spec restack_widget_px(Dashboard.t(), instance_id :: String.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def restack_widget_px(%Dashboard{} = dashboard, instance_id, dir)
      when dir in ["front", "back"] do
    others =
      for inst <- dashboard.layout, inst["id"] != instance_id do
        pixel_z(inst)
      end

    z =
      case {dir, others} do
        {_, []} -> 0
        {"front", zs} -> Enum.max(zs) + 1
        {"back", zs} -> Enum.min(zs) - 1
      end

    update_item(dashboard, instance_id, &Layout.put_pixel(&1, %{"z" => z}))
  end

  defp pixel_z(inst) do
    case Layout.pixel(inst)["z"] do
      z when is_integer(z) -> z
      _ -> 0
    end
  end

  @doc "Remove a widget instance by its instance id."
  @spec remove_widget(Dashboard.t(), instance_id :: String.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def remove_widget(%Dashboard{} = dashboard, instance_id, opts \\ []) do
    layout = Enum.reject(dashboard.layout, &(&1["id"] == instance_id))

    dashboard
    |> save_layout(layout)
    |> log_on_ok("dashboard.widget_removed", opts, %{"instance_id" => instance_id})
  end

  @doc "Replace the settings map of a single widget instance."
  @spec update_widget_settings(Dashboard.t(), instance_id :: String.t(), map(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def update_widget_settings(%Dashboard{} = dashboard, instance_id, settings, opts \\ []) do
    configure_widget(dashboard, instance_id, %{settings: settings}, opts)
  end

  @doc """
  Update a single widget instance's config — its `:settings` map, its selected
  `:view`, and/or its `:min_override` flag (opt out of the recommended minimum
  size: the resize floor drops to 1x1 and view-switch growth is skipped) — in
  one write. Logs a `dashboard.widget_configured` activity.
  """
  @spec configure_widget(
          Dashboard.t(),
          instance_id :: String.t(),
          %{optional(:settings) => map(), optional(:view) => String.t() | nil},
          keyword()
        ) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def configure_widget(%Dashboard{} = dashboard, instance_id, attrs, opts \\ [])
      when is_map(attrs) do
    # Guard `settings` to a real map: a hostile scalar would be stored and later
    # crash the widget's `update/2` (BadMapError) on every render — a permanent
    # brick. A non-map settings value is coerced to an empty map.
    attrs =
      case attrs do
        %{settings: s} when not is_map(s) -> Map.put(attrs, :settings, %{})
        _ -> attrs
      end

    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst ->
          inst
          |> put_attr(attrs, :settings, "settings")
          |> put_attr(attrs, :view, "view")
          |> put_attr(attrs, :min_override, "min_override")

        inst ->
          inst
      end)

    layout =
      if Map.has_key?(attrs, :view),
        do: grow_for_view(dashboard, layout, instance_id),
        else: layout

    dashboard
    |> save_layout(layout)
    |> log_on_ok("dashboard.widget_configured", opts, %{"instance_id" => instance_id})
  end

  defp put_attr(inst, attrs, key, string_key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(inst, string_key, value)
      :error -> inst
    end
  end

  # Switching to a view with a larger minimum (e.g. text clock → analog) grows
  # every stored placement of that instance to meet it — per tier, and only
  # where the grid has room: a blocked or edge-tight tier keeps its size (the
  # view still renders, just smaller than its ideal floor).
  defp grow_for_view(dashboard, layout, instance_id) do
    case Enum.find(layout, &(&1["id"] == instance_id)) do
      nil -> layout
      item -> swap_item(layout, instance_id, grow_all_tiers(dashboard, item, layout))
    end
  end

  defp grow_all_tiers(dashboard, item, layout) do
    {min, _max} = size_bounds(item)

    Enum.reduce(
      Map.keys(item["bp"] || %{}),
      item,
      &grow_on_tier(dashboard, &2, &1, min, layout)
    )
  end

  defp swap_item(layout, instance_id, replacement) do
    Enum.map(layout, fn i -> if i["id"] == instance_id, do: replacement, else: i end)
  end

  defp grow_on_tier(dashboard, item, bp, min, layout) do
    cols = grid_cols(dashboard, bp)
    p = Layout.placement(item, bp)
    w = max(p["w"], min(min.w, cols))
    h = max(p["h"], min.h)

    cond do
      w == p["w"] and h == p["h"] ->
        item

      is_integer(p["x"]) and is_integer(p["y"]) ->
        others =
          layout
          |> Enum.reject(&(&1["id"] == item["id"]))
          |> Enum.map(&Layout.placement(&1, bp))

        if p["x"] + w <= cols and p["y"] + h <= grid_rows(dashboard, bp) and
             not Grid.collides?(p["x"], p["y"], w, h, others) do
          Layout.put_placement(item, bp, %{"w" => w, "h" => h})
        else
          item
        end

      true ->
        # Order-only legacy placement — no cells to collide with yet; the packer
        # places the grown span on next render.
        Layout.put_placement(item, bp, %{"w" => w, "h" => h})
    end
  end

  # Map `fun` over the instance with `instance_id`, then persist. The shared shape
  # for every geometry write, so a widget's placement is only ever touched in one
  # place (embedded per widget → no cross-map desync).
  defp update_item(dashboard, instance_id, fun) do
    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst -> fun.(inst)
        inst -> inst
      end)

    save_layout(dashboard, layout)
  end

  # Persist a per-breakpoint edit: the new layout + mark the breakpoint customized
  # (in one write, so the two can't diverge). The layout write is FORCED:
  # materialize_grid pre-mutates the struct in memory, so a plain change/2 would
  # diff against the materialized copy and silently skip persisting it whenever
  # the edit's final values equal the derived ones (e.g. resizing a derived tier
  # to the size it already shows) — the DB row would keep the un-materialized
  # layout while the config already says "custom".
  defp save_customized(dashboard, layout, bp) do
    config = mark_customized(dashboard.config, bp)

    dashboard
    |> Ecto.Changeset.change(config: config)
    |> Ecto.Changeset.force_change(:layout, layout)
    |> repo().update()
  end

  # Merge (not replace) the tier map: it may carry "cols"/"rows" overrides that
  # a plain %{"state" => "custom"} write would wipe.
  defp mark_customized(config, bp) do
    bps = Map.get(config, "breakpoints", %{})
    bp_map = bps |> Map.get(bp, %{}) |> Map.put("state", "custom")
    Map.put(config, "breakpoints", Map.put(bps, bp, bp_map))
  end

  # A designed breakpoint: stored explicit cells render verbatim; order-only
  # placements (pre-cells data, or none at all) pack into the remaining free
  # cells in `pos` order. Reading-order output.
  defp resolve_designed(dashboard, bp) do
    cols = grid_cols(dashboard, bp)

    entries =
      dashboard.layout
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        {item, Map.put_new(Layout.placement(item, bp), "pos", idx)}
      end)

    {placed, unplaced} =
      Enum.split_with(entries, fn {_item, p} -> is_integer(p["x"]) and is_integer(p["y"]) end)

    {packed, _occupied} =
      unplaced
      |> Enum.sort_by(fn {_item, p} -> p["pos"] end)
      |> Enum.map_reduce(Enum.map(placed, fn {_i, p} -> p end), fn {item, p}, occupied ->
        w = p["w"] |> max(1) |> min(cols)
        h = max(p["h"], 1)
        {x, y} = Grid.first_free(occupied, w, h, cols) || {0, Grid.below_all(occupied)}
        p2 = Map.merge(p, %{"x" => x, "y" => y, "w" => w})
        {{item, p2}, [p2 | occupied]}
      end)

    Enum.sort_by(placed ++ packed, fn {_item, p} -> {p["y"], p["x"], p["pos"]} end)
  end

  # An un-designed breakpoint derives from the nearest designed tier by
  # reflow + compact: that tier's widgets in reading order, spans clamped to this
  # tier's columns, packed first-fit (heights/hidden kept).
  defp derive_tier(dashboard, bp) do
    source_items = resolve_items(dashboard, derivation_source(dashboard, bp))

    packed =
      source_items |> Enum.map(fn {_item, p} -> p end) |> Grid.compact(grid_cols(dashboard, bp))

    source_items
    |> Enum.zip(packed)
    |> Enum.map(fn {{item, _src}, p} -> {item, p} end)
    |> Enum.sort_by(fn {_item, p} -> {p["y"], p["x"], p["pos"]} end)
  end

  # Before ANY grid edit at `bp`, pin every widget's currently-resolved placement
  # (explicit cells included) into that breakpoint — so editing one widget can't
  # shift the others (they're anchored where the user sees them), whether the
  # tier was deriving or holds pre-cells order-only data. No-op once every
  # widget has stored cells.
  defp materialize_grid(%Dashboard{} = dashboard, bp) do
    if grid_materialized?(dashboard, bp) do
      dashboard
    else
      resolved = Map.new(resolve_items(dashboard, bp), fn {item, p} -> {item["id"], p} end)
      %{dashboard | layout: Enum.map(dashboard.layout, &materialize_item(&1, bp, resolved))}
    end
  end

  defp grid_materialized?(dashboard, bp) do
    customized?(dashboard, bp) and
      Enum.all?(dashboard.layout, fn item ->
        p = get_in(item, ["bp", bp])
        is_map(p) and is_integer(p["x"]) and is_integer(p["y"])
      end)
  end

  defp materialize_item(item, bp, resolved) do
    case resolved[item["id"]] do
      nil -> item
      placement -> Layout.put_placement(item, bp, placement)
    end
  end

  # The breakpoint to derive a fresh `bp` from: nearest LARGER customized, then
  # nearest smaller customized, then the home tier (the always-designed anchor).
  defp derivation_source(dashboard, bp) do
    chain = Breakpoints.larger_than(bp) ++ Breakpoints.smaller_than(bp)
    Enum.find(chain, home_bp(dashboard), &customized?(dashboard, &1))
  end

  # The first free pixel row below every placed widget, so a new pixel-canvas
  # widget stacks under the others instead of overlapping.
  defp next_pixel_y([]), do: 0

  defp next_pixel_y(layout) do
    layout
    |> Enum.map(fn inst ->
      px = Layout.pixel(inst)
      px["fy"] + px["fh"]
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(16)
  end

  # Merge one key into the dashboard's config map and persist it.
  defp put_config(dashboard, key, value) do
    dashboard
    |> Dashboard.config_changeset(Map.put(dashboard.config, key, value))
    |> repo().update()
  end

  # Min/max span bounds for an INSTANCE — the min comes from its selected view
  # when that view declares one (`Widget.min_size_for/2`; an analog clock has a
  # squarer floor than a text one). The per-instance `min_override` drops the
  # floor to 1x1: minimums are RECOMMENDATIONS (content renders degraded below
  # them), and a user cramming a dense dashboard may opt out. Falls back to
  # sane defaults when the type is unknown (a stale instance whose provider was
  # uninstalled).
  defp size_bounds(item) do
    case Registry.get(item["widget_key"]) do
      %Widget{} = widget -> {instance_min(item, widget), widget.max_size}
      _ -> {%{w: 1, h: 1}, %{w: Breakpoints.max_cols(), h: 8}}
    end
  end

  defp instance_min(%{"min_override" => true}, _widget), do: %{w: 1, h: 1}
  defp instance_min(item, widget), do: Widget.min_size_for(widget, item["view"])

  defp clamp(value, lo, hi) when is_integer(value), do: value |> max(lo) |> min(hi)
  defp clamp(_value, lo, _hi), do: lo

  # Log a business-level activity on the {:ok, dashboard} branch only, passing
  # through the original result. Guarded + rescued so a logging failure never
  # crashes the mutation (workspace convention). save_layout/2 stays unlogged —
  # it is the drag/resize hot path.
  defp log_on_ok(result, action, opts, extra_metadata \\ %{})

  defp log_on_ok({:ok, %Dashboard{} = dashboard} = result, action, opts, extra_metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      metadata =
        %{"title" => dashboard.title, "scope" => dashboard.scope}
        |> Map.merge(extra_metadata)
        |> Map.merge(Keyword.get(opts, :log_extra, %{}))

      PhoenixKit.Activity.log(%{
        action: action,
        module: "dashboards",
        mode: "manual",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "dashboard",
        resource_uuid: dashboard.uuid,
        metadata: metadata
      })
    end

    result
  rescue
    e ->
      Logger.warning("[Dashboards] Activity logging error: #{Exception.message(e)}")
      result
  catch
    :exit, reason ->
      Logger.warning("[Dashboards] Activity logging exit: #{inspect(reason)}")
      result
  end

  defp log_on_ok(result, _action, _opts, _extra_metadata), do: result

  defp repo, do: RepoHelper.repo()
end
