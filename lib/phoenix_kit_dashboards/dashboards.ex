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

  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.RepoHelper
  alias PhoenixKitDashboards.Grid
  alias PhoenixKitDashboards.Lattice
  alias PhoenixKitDashboards.Layout
  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Sizing
  alias PhoenixKitDashboards.Widget

  # Free/pixel-canvas widget bounds (px) — the values live in Lattice, the one
  # home for geometry constants.
  @free_min_px Lattice.free_min_px()
  @free_max_px Lattice.free_max_px()
  @free_max_pos Lattice.free_max_pos()

  # px per lattice unit when seeding a new widget's pixel-canvas geometry from
  # its span (the lattice cell is 25px, so the pixel seed mirrors the grid).
  @pixel_seed_col 25
  @pixel_seed_row 25

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

  @doc "Fetch one dashboard by uuid, or nil (nil too for a malformed id)."
  @spec get(String.t()) :: Dashboard.t() | nil
  def get(uuid) when is_binary(uuid) do
    # A non-UUID id would make `Repo.get` raise `Ecto.Query.CastError` (the PK
    # is UUIDv7) — but every caller treats "not found" as nil, and hostile
    # `/dashboards/<junk>` URLs / crafted `phx-value-uuid` reach here. Validate
    # first so a bad id is a clean nil, not a 500.
    case Ecto.UUID.cast(uuid) do
      {:ok, valid} -> repo().get(Dashboard, valid)
      :error -> nil
    end
  end

  def get(_uuid), do: nil

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
  access. Host-facing helper for a "default dashboard" landing page — the
  built-in module lists dashboards rather than opening one, so nothing in this
  package calls it; it's public API for hosts that want the get-or-create-default
  pattern.
  """
  @spec get_or_create_default(user_uuid :: String.t()) :: Dashboard.t() | nil
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
        case create(
               %{
                 title: "My Dashboard",
                 scope: "personal",
                 owner_user_uuid: user_uuid,
                 is_default: true
               },
               actor_uuid: user_uuid
             ) do
          {:ok, dashboard} ->
            dashboard

          # A create error here is a lost concurrent first-access race (no unique
          # index on is_default) — the winner's row now satisfies the query. A
          # genuine DB failure returns nil rather than raising a MatchError.
          {:error, _} ->
            repo().one(query)
        end

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
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def update(%Dashboard{} = dashboard, attrs, opts \\ []) do
    dashboard
    |> Dashboard.changeset(attrs)
    |> persist()
    |> log_on_ok("dashboard.updated", opts)
  end

  @doc "Delete a dashboard."
  @spec delete(Dashboard.t(), keyword()) :: {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Dashboard{} = dashboard, opts \\ []) do
    result =
      dashboard
      |> repo().delete()
      |> log_on_ok("dashboard.deleted", opts)

    with {:ok, deleted} <- result do
      broadcast(topic(deleted.uuid), {:dashboard_deleted, deleted.uuid})
    end

    result
  end

  @doc "Persist a new full layout (the hot path while editing the grid)."
  @spec save_layout(Dashboard.t(), [map()]) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def save_layout(%Dashboard{} = dashboard, layout) when is_list(layout) do
    dashboard
    |> Dashboard.layout_changeset(layout)
    |> persist()
  end

  @doc """
  Add a widget instance for `widget_key` to a dashboard's layout, seeded with the
  widget type's default size and settings — the grid placement takes the first
  FREE cell on the home layout, the pixel geometry stacks below the existing
  widgets. Returns the updated dashboard.
  """
  @spec add_widget(Dashboard.t(), widget_key :: String.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, term()}
  def add_widget(%Dashboard{} = dashboard, widget_key, opts \\ []) do
    # Unlike add_widget_at/6, this does NOT materialize_grid first: it appends at
    # the first free cell (new_instance) without pinning the other widgets'
    # derived placements. Explicit-cell placement (add_widget_at) needs a stable
    # grid to anchor against, so it materializes; a plain append doesn't disturb
    # anyone, so it skips that write.
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        layout_id = Keyword.get(opts, :layout_id) || first_layout_id(dashboard)

        dashboard
        |> save_layout(dashboard.layout ++ [new_instance(dashboard, widget, layout_id)])
        |> log_on_ok("dashboard.widget_added", opts, %{"widget_key" => widget.key})
    end
  end

  @doc """
  Add a widget at an explicit grid cell on `layout_id` (a catalog drag-out drop) —
  `x`/`y` 0-based, clamped into the layout; a spot overlapping another widget is
  refused with `{:error, :occupied}` (the drag hook only offers free cells).
  Logs `dashboard.widget_added`.
  """
  @spec add_widget_at(
          Dashboard.t(),
          widget_key :: String.t(),
          String.t(),
          integer(),
          integer(),
          keyword()
        ) ::
          {:ok, Dashboard.t()}
          | {:error, :stale | :unknown_widget | :occupied | Ecto.Changeset.t()}
  def add_widget_at(%Dashboard{} = dashboard, widget_key, layout_id, x, y, opts \\ [])
      when is_binary(layout_id) and is_integer(x) and is_integer(y) do
    case Registry.get(widget_key) do
      nil ->
        {:error, :unknown_widget}

      %Widget{} = widget ->
        # Pin the layout first so placing the new widget can't shift others
        # that were still packed-at-render.
        dashboard = materialize_grid(dashboard, layout_id)
        cols = grid_cols(dashboard, layout_id)
        rows = grid_rows(dashboard, layout_id)
        w = min(widget.default_size.w, cols)
        h = min(widget.default_size.h, rows)
        x = clamp(x, 0, max(cols - w, 0))
        y = clamp(y, 0, max(rows - h, 0))
        others = Enum.map(dashboard.layout, &Layout.placement(&1, layout_id))

        if Grid.collides?(x, y, w, h, others) do
          {:error, :occupied}
        else
          instance =
            dashboard
            |> new_instance(widget, layout_id)
            |> Layout.put_placement(layout_id, %{
              "x" => x,
              "y" => y,
              "w" => w,
              "h" => h,
              "hidden" => false,
              "pos" => length(dashboard.layout)
            })

          dashboard
          |> save_pinned(dashboard.layout ++ [instance])
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
        # Same one-screen-past-existing-content bound as place_widget_px — the
        # new instance isn't in dashboard.layout yet, so every existing widget
        # counts.
        max_x = pixel_bound(dashboard, :x)
        max_y = pixel_bound(dashboard, :y)

        instance =
          dashboard
          |> new_instance(widget, first_layout_id(dashboard))
          |> Layout.put_pixel(%{
            "fx" => clamp(fx, 0, max_x),
            "fy" => clamp(fy, 0, max_y)
          })

        dashboard
        |> save_layout(dashboard.layout ++ [instance])
        |> log_on_ok("dashboard.widget_added", opts, %{"widget_key" => widget.key})
    end
  end

  # A fresh widget instance with the default geometry: `pixel` stacked below
  # the existing widgets, and the grid placement seeded at `layout_id`'s first
  # FREE cell. Other layouts pack it first-fit at render (pinned on edit).
  defp new_instance(dashboard, %Widget{} = widget, layout_id) do
    home = layout_id
    cols = grid_cols(dashboard, home)
    w = widget.default_size.w
    h = widget.default_size.h
    seed_w = min(w, cols)
    seed_h = min(h, grid_rows(dashboard, home))

    occupied = dashboard |> resolve_items(home) |> Enum.map(fn {_i, p} -> p end)

    {x, y} = Grid.slot(occupied, seed_w, seed_h, cols, grid_rows(dashboard, home))

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
          "h" => seed_h,
          "hidden" => false,
          "pos" => length(dashboard.layout)
        }
      }
    }
  end

  @doc """
  Re-pack a **layout's** grid to `ordered_ids`: every widget gets the first
  free cell in that order (reflow + compact), so the ids' order becomes the
  reading order. Unknown ids are filtered/deduped; unnamed widgets keep their
  relative order after the named ones. A layout
  tweak — not activity-logged.
  """
  @spec reorder_widgets(Dashboard.t(), String.t(), [String.t()]) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def reorder_widgets(%Dashboard{} = dashboard, layout_id, ordered_ids)
      when is_binary(layout_id) and is_list(ordered_ids) do
    dashboard = materialize_grid(dashboard, layout_id)
    cols = grid_cols(dashboard, layout_id)
    rows = grid_rows(dashboard, layout_id)

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
      |> Enum.map(fn {item, _idx} -> Layout.placement(item, layout_id) end)
      |> Grid.compact(cols, rows)

    placements =
      ranked
      |> Enum.zip(packed)
      |> Enum.with_index()
      |> Map.new(fn {{{item, _idx}, placement}, pos} ->
        {item["id"], Map.put(placement, "pos", pos)}
      end)

    layout =
      Enum.map(dashboard.layout, fn item ->
        Layout.put_placement(item, layout_id, Map.fetch!(placements, item["id"]))
      end)

    save_pinned(dashboard, layout)
  end

  @doc """
  Place a grid widget at an explicit cell — `x` (column) / `y` (row), 0-based —
  on layout `layout_id`. The widget may go anywhere on the
  grid (gaps are fine); `x` is clamped so the span stays within the columns, `y`
  within the layout's rows. A spot overlapping another widget is refused with
  `{:error, :occupied}` (the drag hook never offers one; this guards stale/
  crafted events). A layout tweak — not activity-logged.
  """
  @spec place_widget_grid(
          Dashboard.t(),
          instance_id :: String.t(),
          String.t(),
          integer(),
          integer()
        ) :: {:ok, Dashboard.t()} | {:error, :stale | :occupied | Ecto.Changeset.t()}
  def place_widget_grid(%Dashboard{} = dashboard, instance_id, layout_id, x, y)
      when is_binary(layout_id) and is_integer(x) and is_integer(y) do
    dashboard = materialize_grid(dashboard, layout_id)

    case Enum.find(dashboard.layout, &(&1["id"] == instance_id)) do
      nil -> {:ok, dashboard}
      item -> place_at_cell(dashboard, item, instance_id, layout_id, x, y)
    end
  end

  defp place_at_cell(dashboard, item, instance_id, layout_id, x, y) do
    cols = grid_cols(dashboard, layout_id)
    placement = Layout.placement(item, layout_id)
    w = min(placement["w"], cols)
    h = placement["h"]
    x = clamp(x, 0, max(cols - w, 0))
    y = clamp(y, 0, max(grid_rows(dashboard, layout_id) - h, 0))

    others =
      dashboard.layout
      |> Enum.reject(&(&1["id"] == instance_id))
      |> Enum.map(&Layout.placement(&1, layout_id))

    if Grid.collides?(x, y, w, h, others) do
      {:error, :occupied}
    else
      layout =
        Enum.map(dashboard.layout, fn
          %{"id" => ^instance_id} = inst ->
            Layout.put_placement(inst, layout_id, %{"x" => x, "y" => y, "w" => w})

          inst ->
            inst
        end)

      save_pinned(dashboard, layout)
    end
  end

  @doc """
  Set a grid widget's `w`/`h` span on layout `layout_id`.
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
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def resize_widget(%Dashboard{} = dashboard, instance_id, layout_id, w, h)
      when is_binary(layout_id) do
    dashboard = materialize_grid(dashboard, layout_id)
    cols = grid_cols(dashboard, layout_id)

    others =
      dashboard.layout
      |> Enum.reject(&(&1["id"] == instance_id))
      |> Enum.map(&Layout.placement(&1, layout_id))

    rows = grid_rows(dashboard, layout_id)

    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst ->
          resize_instance(inst, layout_id, w, h, others, cols, rows)

        inst ->
          inst
      end)

    save_pinned(dashboard, layout)
  end

  defp resize_instance(inst, layout_id, w, h, others, cols, rows) do
    bounds = Sizing.bounds(inst, layout_id)
    placement = Layout.placement(inst, layout_id)

    case {placement["x"], placement["y"]} do
      {x, y} when is_integer(x) and is_integer(y) ->
        {w2, h2} = Grid.fit_size(x, y, w, h, placement["h"], others, {cols, rows}, bounds)

        # fit_size floors at the view's min — when even that floor doesn't fit
        # (a raised per-view minimum in a tight corner), keep the current size
        # rather than overlap a neighbour.
        if Grid.collides?(x, y, w2, h2, others) do
          inst
        else
          Layout.put_placement(inst, layout_id, %{"w" => w2, "h" => h2})
        end

      _ ->
        # Unplaced (shouldn't survive materialize_grid; defensive): plain
        # bounds clamp.
        {min, max} = bounds

        Layout.put_placement(inst, layout_id, %{
          "w" => clamp(w, min.w, min(max.w, cols)),
          "h" => clamp(h, min.h, max.h)
        })
    end
  end

  @doc """
  Show/hide a grid widget on `layout_id` (so a layout can drop non-essentials). A layout
  tweak — not activity-logged.

  Host-facing: the render path fully supports hidden widgets (they keep their
  cells and the builder dims them; `resolve_items/3` `visible: true` filters
  them for the runtime), but the built-in builder ships no hide toggle yet — a
  host wires this setter (with `resolve_hidden?/3`) to its own UI.
  """
  @spec hide_widget(Dashboard.t(), instance_id :: String.t(), String.t(), boolean()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def hide_widget(%Dashboard{} = dashboard, instance_id, layout_id, hidden)
      when is_binary(layout_id) and is_boolean(hidden) do
    dashboard = materialize_grid(dashboard, layout_id)

    layout =
      Enum.map(dashboard.layout, fn
        %{"id" => ^instance_id} = inst ->
          Layout.put_placement(inst, layout_id, %{"hidden" => hidden})

        inst ->
          inst
      end)

    save_pinned(dashboard, layout)
  end

  # ── Grid layouts (user-defined named grids) ────────────────────────
  #
  # A grid dashboard is composed of an ordered list of LAYOUTS stored in
  # config["layouts"] = [%{"id","name","cols","rows"}] — each is EXACTLY ONE
  # SCREENFUL on the gapless 25px lattice (see `PhoenixKitDashboards.Lattice`).
  # Widgets are dashboard-level; each widget's geometry is embedded per layout
  # id (item["bp"][layout_id]). A layout without a stored placement for a
  # widget packs it first-fit at render (pinned on first edit).

  # The pure layout-list helpers (reading/normalizing the list, finding an
  # entry, minting the next id/name, the default entry) live in
  # `PhoenixKitDashboards.Layouts`; these delegates keep the long-standing
  # `Dashboards.layouts/1` etc. as the module's public read API.
  @doc """
  The dashboard's grid layouts, ordered. A dashboard that has never persisted
  a layout list gets the default single "Layout 1" (64×36).
  """
  @spec layouts(Dashboard.t()) :: [map()]
  defdelegate layouts(dashboard), to: Layouts

  @doc "One layout entry by id, or nil."
  @spec get_layout(Dashboard.t(), String.t()) :: map() | nil
  defdelegate get_layout(dashboard, id), to: Layouts

  @doc "The id of the first (default/landing) layout."
  @spec first_layout_id(Dashboard.t()) :: String.t()
  defdelegate first_layout_id(dashboard), to: Layouts

  @doc """
  Add a layout: named "Layout N" by default, dimensions copied from the
  `source_id` layout (the active one), placements seeded by reflow+compact of
  the source's resolved placements — so "+" doubles as duplicate-of-active.
  Returns `{:ok, dashboard, new_entry}`.
  """
  @spec add_layout(Dashboard.t(), String.t(), keyword()) ::
          {:ok, Dashboard.t(), map()} | {:error, :stale | Ecto.Changeset.t()}
  def add_layout(%Dashboard{} = dashboard, source_id, opts \\ []) when is_binary(source_id) do
    entries = layouts(dashboard)
    source = Enum.find(entries, hd(entries), &(&1["id"] == source_id))

    entry = %{
      "id" => Layouts.new_layout_id(entries),
      "name" => Keyword.get(opts, :name) || Layouts.next_layout_name(entries),
      "cols" => source["cols"],
      "rows" => source["rows"]
    }

    # Seed: the source layout's resolved placements, compacted into the new
    # grid in reading order (dims match, so this is a straight copy).
    seeded =
      dashboard
      |> resolve_items(source["id"])
      |> Enum.map(fn {_item, p} -> p end)
      |> Grid.compact(entry["cols"], entry["rows"])

    seeds =
      dashboard
      |> resolve_items(source["id"])
      |> Enum.zip(seeded)
      |> Map.new(fn {{item, _}, p} -> {item["id"], p} end)

    layout =
      Enum.map(dashboard.layout, fn item ->
        case seeds[item["id"]] do
          nil -> item
          p -> Layout.put_placement(item, entry["id"], p)
        end
      end)

    config = Map.put(dashboard.config, "layouts", entries ++ [entry])

    dashboard
    |> Ecto.Changeset.change(config: config)
    |> Ecto.Changeset.force_change(:layout, layout)
    |> persist()
    |> case do
      {:ok, updated} -> {:ok, updated, entry}
      error -> error
    end
  end

  @doc "Rename a layout (blank names are ignored). Not activity-logged."
  @spec rename_layout(Dashboard.t(), String.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def rename_layout(%Dashboard{} = dashboard, id, name)
      when is_binary(id) and is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:ok, dashboard}
    else
      entries =
        Enum.map(layouts(dashboard), fn
          %{"id" => ^id} = entry -> Map.put(entry, "name", String.slice(name, 0, 60))
          entry -> entry
        end)

      put_config(dashboard, "layouts", entries)
    end
  end

  @doc """
  Delete a layout and every widget placement stored under its id (widgets are
  dashboard-level — they live on in the other layouts, packing first-fit where
  they had no explicit placement). The last layout can't be deleted
  (`{:error, :last_layout}`).
  """
  @spec delete_layout(Dashboard.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, :last_layout | Ecto.Changeset.t()}
  def delete_layout(%Dashboard{} = dashboard, id) when is_binary(id) do
    entries = layouts(dashboard)

    cond do
      not Enum.any?(entries, &(&1["id"] == id)) ->
        {:ok, dashboard}

      length(entries) <= 1 ->
        {:error, :last_layout}

      true ->
        config =
          Map.put(dashboard.config, "layouts", Enum.reject(entries, &(&1["id"] == id)))

        layout = Enum.map(dashboard.layout, &drop_layout_entry(&1, id))

        dashboard
        |> Ecto.Changeset.change(config: config)
        |> Ecto.Changeset.force_change(:layout, layout)
        |> persist()
    end
  end

  defp drop_layout_entry(%{"bp" => map} = inst, id) when is_map(map),
    do: Map.put(inst, "bp", Map.delete(map, id))

  defp drop_layout_entry(inst, _id), do: inst

  # NOTE: grid_cols/grid_rows read through get_layout → layouts/1, which already
  # clamps cols/rows to the lattice bounds [min_dim, max_dim] (a tampered/huge or
  # non-integer stored dim can't reach design_width/height uncapped). Only the
  # PIXEL read path (BuilderLive.free_geometry, via Layout.pixel) needed a new
  # read-side clamp — Layout.pixel doesn't bound fw/fh.
  @doc "The column count of a layout (default entry's when the id is unknown)."
  @spec grid_cols(Dashboard.t(), String.t()) :: pos_integer()
  def grid_cols(%Dashboard{} = dashboard, layout_id) do
    case get_layout(dashboard, layout_id) do
      %{"cols" => cols} -> cols
      nil -> Layouts.default_layout()["cols"]
    end
  end

  @doc "The row count of a layout (default entry's when the id is unknown)."
  @spec grid_rows(Dashboard.t(), String.t()) :: pos_integer()
  def grid_rows(%Dashboard{} = dashboard, layout_id) do
    case get_layout(dashboard, layout_id) do
      %{"rows" => rows} -> rows
      nil -> Layouts.default_layout()["rows"]
    end
  end

  @doc """
  Set a layout's lattice dimensions (the builder's inputs, steppers, and the
  "Fit this screen" button). Each axis clamps into
  `#{Lattice.min_dim()}..#{Lattice.max_dim()}` and never below the extent
  widgets already occupy (shrinking never cuts into a placed widget — the
  target is raised to fit instead). A layout tweak — not activity-logged.
  """
  @spec set_grid_dims(Dashboard.t(), String.t(), integer(), integer()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def set_grid_dims(%Dashboard{} = dashboard, layout_id, cols, rows)
      when is_binary(layout_id) and is_integer(cols) and is_integer(rows) do
    case get_layout(dashboard, layout_id) do
      nil ->
        {:ok, dashboard}

      _entry ->
        # Pin resolved placements first so a dimension change can't reshuffle
        # not-yet-pinned (packed-at-render) widgets.
        dashboard = materialize_grid(dashboard, layout_id)

        cols =
          cols
          |> clamp(Lattice.min_dim(), Lattice.max_dim())
          |> max(occupied_extent(dashboard, layout_id, :cols))

        rows =
          rows
          |> clamp(Lattice.min_dim(), Lattice.max_dim())
          |> max(occupied_extent(dashboard, layout_id, :rows))

        entries =
          Enum.map(layouts(dashboard), fn
            %{"id" => ^layout_id} = entry ->
              entry |> Map.put("cols", cols) |> Map.put("rows", rows)

            entry ->
              entry
          end)

        config = Map.put(dashboard.config, "layouts", entries)

        dashboard
        |> Ecto.Changeset.change(config: config)
        |> Ecto.Changeset.force_change(:layout, dashboard.layout)
        |> persist()
    end
  end

  @doc "The design-space canvas width for a layout (gapless lattice)."
  @spec design_width(Dashboard.t(), String.t()) :: pos_integer()
  def design_width(%Dashboard{} = dashboard, layout_id) do
    Lattice.design_width(grid_cols(dashboard, layout_id))
  end

  @doc "The design-space canvas height for a layout (gapless lattice)."
  @spec design_height(Dashboard.t(), String.t()) :: pos_integer()
  def design_height(%Dashboard{} = dashboard, layout_id) do
    Lattice.design_height(grid_rows(dashboard, layout_id))
  end

  # The furthest cell (exclusive) widgets occupy on an axis — the shrink floor.
  # (Hidden widgets keep their cells, so they count too.)
  defp occupied_extent(dashboard, layout_id, dim) do
    dashboard
    |> resolve_items(layout_id)
    |> Enum.map(fn {_item, p} ->
      case dim do
        :cols -> if is_integer(p["x"]), do: p["x"] + max(Lattice.to_int(p["w"], 1), 1), else: 0
        :rows -> if is_integer(p["y"]), do: p["y"] + max(Lattice.to_int(p["h"], 1), 1), else: 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  The `{item, placement}` pairs to render for a layout — the single render
  path. Every returned placement carries explicit cells (`x`/`y`) plus
  `w`/`h`/`hidden`: stored cells render verbatim; placements without stored
  cells for this layout (a widget added elsewhere, or pre-cells legacy data)
  pack first-fit into the remaining free cells in `pos` order — pinned on
  their first edit, no migration.

  Ordered by reading order (`y`, then `x`); **hidden widgets are included**
  (the builder dims them and they keep their cells; pass `visible: true` — or
  filter `placement["hidden"]` — for the runtime).
  """
  @spec resolve_items(Dashboard.t(), String.t(), keyword()) :: [{map(), map()}]
  def resolve_items(%Dashboard{} = dashboard, layout_id, opts \\ []) do
    items = resolve_designed(dashboard, layout_id)

    if opts[:visible], do: Enum.reject(items, fn {_i, p} -> p["hidden"] == true end), else: items
  end

  @doc """
  The **resolved** grid placement for one widget on `layout_id` — exactly what
  `resolve_items/3` renders for it, or `nil` if the widget isn't in the layout.
  Use this (not `Layout.placement/2`) anywhere that must match what's on screen —
  e.g. the Settings modal's inputs, so a save doesn't overwrite a derived
  placement with the default.
  """
  @spec resolve_placement(Dashboard.t(), instance_id :: String.t(), String.t()) :: map() | nil
  def resolve_placement(%Dashboard{} = dashboard, id, layout_id) do
    case Enum.find(resolve_items(dashboard, layout_id), fn {item, _p} -> item["id"] == id end) do
      nil -> nil
      {_item, placement} -> placement
    end
  end

  @doc """
  Whether a widget is currently hidden on `layout_id` (stored or derived). The read
  counterpart to `hide_widget/4` — host-facing (see that function's note).
  """
  @spec resolve_hidden?(Dashboard.t(), instance_id :: String.t(), String.t()) :: boolean()
  def resolve_hidden?(%Dashboard{} = dashboard, id, layout_id) do
    case resolve_placement(dashboard, id, layout_id) do
      nil -> false
      placement -> placement["hidden"] == true
    end
  end

  @doc """
  Free/pixel-canvas mode: place a widget at absolute pixels (`fx`, `fy`). Each
  is clamped to `[0, one screen past the furthest OTHER widget]` (capped at the
  absolute `@free_max_pos`): the canvas can grow by a screenful per move, but a
  single crafted `move_widget_to` can't balloon it to 20000px for every viewer
  of a shared dashboard (`free_canvas_dims` sizes the canvas to contain widgets).
  Pixel geometry is embedded so it never disturbs the grid placement. A layout
  tweak — not activity-logged.
  """
  @spec place_widget_px(Dashboard.t(), instance_id :: String.t(), integer(), integer()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def place_widget_px(%Dashboard{} = dashboard, instance_id, fx, fy) do
    max_x = pixel_bound(dashboard, :x)
    max_y = pixel_bound(dashboard, :y)

    update_item(dashboard, instance_id, fn inst ->
      Layout.put_pixel(inst, %{
        "fx" => clamp(fx, 0, max_x),
        "fy" => clamp(fy, 0, max_y)
      })
    end)
  end

  # The furthest a widget may be positioned on an axis: one screen (@free_max_px)
  # past the furthest EXISTING widget edge, capped at @free_max_pos. Includes the
  # widget being moved (its own current edge counts) so a widget already parked
  # far out isn't yanked back when peers move nearer — a micro-drag or a settings
  # re-save that resubmits its current fx/fy keeps it in place. Lets the canvas
  # grow a screenful per move while blocking a single-event balloon.
  defp pixel_bound(dashboard, axis) do
    extent =
      dashboard.layout
      |> Enum.map(fn inst ->
        px = Layout.pixel(inst)

        case axis do
          :x -> int(px["fx"], 0) + int(px["fw"], 0)
          :y -> int(px["fy"], 0) + int(px["fh"], 0)
        end
      end)
      |> Enum.max(fn -> 0 end)

    # Floor the extent at 0 first — a tampered/legacy negative stored fx/fw could
    # make the extent (and so the upper bound) negative, and clamp(fx, 0, neg)
    # would then persist a negative position, violating the >= 0 invariant.
    min(max(extent, 0) + @free_max_px, @free_max_pos)
  end

  @doc """
  Free/pixel-canvas mode: set a widget's absolute pixel size (`fw`, `fh`), each
  clamped to `[@free_min_px, @free_max_px]`. A layout tweak — not activity-logged.
  """
  @spec resize_widget_px(Dashboard.t(), instance_id :: String.t(), integer(), integer()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def resize_widget_px(%Dashboard{} = dashboard, instance_id, fw, fh) do
    update_item(dashboard, instance_id, fn inst ->
      Layout.put_pixel(inst, %{
        "fw" => clamp(fw, @free_min_px, @free_max_px),
        "fh" => clamp(fh, @free_min_px, @free_max_px)
      })
    end)
  end

  @doc """
  Set a widget's view FOR ONE LAYOUT (stored on that layout's placement):
  designing the phone layout means choosing how each widget looks on the
  phone, without touching the other screens. Falls back to the instance
  default (`configure_widget/4`'s `:view`) where no override is stored —
  see `Layout.view/2`. A presentation tweak — not activity-logged.
  """
  @spec set_layout_view(Dashboard.t(), instance_id :: String.t(), String.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def set_layout_view(%Dashboard{} = dashboard, instance_id, layout_id, view)
      when is_binary(layout_id) and is_binary(view) do
    case Enum.find(dashboard.layout, &(&1["id"] == instance_id)) do
      nil ->
        {:ok, dashboard}

      inst ->
        if valid_view?(inst, view) do
          # Store the override, then grow the placement on THIS layout to the
          # new view's minimum (text clock → analog needs more rows) — the
          # same growth configure_widget applies for instance-level switches.
          inst = Layout.put_placement(inst, layout_id, %{"view" => view})
          layout = swap_item(dashboard.layout, instance_id, inst)
          {min, _max} = Sizing.bounds(inst, layout_id)

          layout =
            swap_item(
              layout,
              instance_id,
              grow_on_layout(dashboard, inst, layout_id, min, layout)
            )

          save_layout(dashboard, layout)
        else
          {:ok, dashboard}
        end
    end
  end

  # A view may only be one the widget type declares — a crafted key would
  # otherwise persist and render as a silent fallback forever.
  defp valid_view?(inst, view) do
    case Registry.get(inst["widget_key"]) do
      %Widget{views: views} -> Enum.any?(views, &(&1.key == view))
      _ -> false
    end
  end

  @doc """
  Restack a pixel widget: `"front"` puts it above every other widget's z,
  `"back"` below. Overlap is allowed on the free canvas — z-order makes it
  deliberate. A layout tweak — not activity-logged.
  """
  @spec restack_widget_px(Dashboard.t(), instance_id :: String.t(), String.t()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
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
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
  def remove_widget(%Dashboard{} = dashboard, instance_id, opts \\ []) do
    layout = Enum.reject(dashboard.layout, &(&1["id"] == instance_id))

    dashboard
    |> save_layout(layout)
    |> log_on_ok("dashboard.widget_removed", opts, %{"instance_id" => instance_id})
  end

  @doc """
  Replace a single widget instance's settings map. Thin convenience alias for
  `configure_widget/4` (the canonical config API) — kept as public API so host
  code from earlier releases keeps working.
  """
  @spec update_widget_settings(Dashboard.t(), instance_id :: String.t(), map(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
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
          %{
            optional(:settings) => map(),
            optional(:view) => String.t() | nil,
            optional(:min_override) => boolean()
          },
          keyword()
        ) :: {:ok, Dashboard.t()} | {:error, :stale | Ecto.Changeset.t()}
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

    # Settings values must stay SCALAR: form params are attacker-controlled,
    # and a nested map (settings[body][x]=1) would persist and then crash the
    # widget's render on every later mount — a permanent brick.
    attrs =
      case attrs do
        %{settings: s} -> Map.put(attrs, :settings, scalar_settings(s))
        _ -> attrs
      end

    # A view not declared by the widget type is dropped (nil explicitly
    # clears back to the default view, which stays allowed).
    attrs =
      case attrs do
        %{view: v} when not is_nil(v) ->
          inst = Enum.find(dashboard.layout, &(&1["id"] == instance_id))

          if inst && valid_view?(inst, v), do: attrs, else: Map.delete(attrs, :view)

        _ ->
          attrs
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

  # Keep only JSON-scalar values (and stringify atom keys) — the settings map
  # round-trips into widget renders that expect flat scalars.
  defp scalar_settings(settings) do
    settings
    |> Enum.filter(fn {_k, v} ->
      is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)
    end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp put_attr(inst, attrs, key, string_key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(inst, string_key, value)
      :error -> inst
    end
  end

  # Switching to a view with a larger minimum (e.g. text clock → analog) grows
  # every stored placement of that instance to meet it — per layout, and only
  # where the grid has room: a blocked or edge-tight layout keeps its size (the
  # view still renders, just smaller than its ideal floor).
  defp grow_for_view(dashboard, layout, instance_id) do
    case Enum.find(layout, &(&1["id"] == instance_id)) do
      nil -> layout
      item -> swap_item(layout, instance_id, grow_all_layouts(dashboard, item, layout))
    end
  end

  defp grow_all_layouts(dashboard, item, layout) do
    # Per-layout: each layout may show a different view with its own minimum.
    Enum.reduce(Map.keys(item["bp"] || %{}), item, fn layout_id, item ->
      {min, _max} = Sizing.bounds(item, layout_id)
      grow_on_layout(dashboard, item, layout_id, min, layout)
    end)
  end

  defp swap_item(layout, instance_id, replacement) do
    Enum.map(layout, fn i -> if i["id"] == instance_id, do: replacement, else: i end)
  end

  defp grow_on_layout(dashboard, item, layout_id, min, layout) do
    cols = grid_cols(dashboard, layout_id)
    p = Layout.placement(item, layout_id)
    w = max(p["w"], min(min.w, cols))
    h = max(p["h"], min.h)

    cond do
      w == p["w"] and h == p["h"] ->
        item

      is_integer(p["x"]) and is_integer(p["y"]) ->
        others =
          layout
          |> Enum.reject(&(&1["id"] == item["id"]))
          |> Enum.map(&Layout.placement(&1, layout_id))

        if p["x"] + w <= cols and p["y"] + h <= grid_rows(dashboard, layout_id) and
             not Grid.collides?(p["x"], p["y"], w, h, others) do
          Layout.put_placement(item, layout_id, %{"w" => w, "h" => h})
        else
          item
        end

      true ->
        # Order-only legacy placement — no cells to collide with yet; the packer
        # places the grown span on next render.
        Layout.put_placement(item, layout_id, %{"w" => w, "h" => h})
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

  # Persist a per-layout placement edit. The write is FORCED: materialize_grid
  # pre-mutates the struct in memory, so a plain change/2 would diff against
  # the materialized copy and silently skip persisting it whenever the edit's
  # final values equal the packed ones.
  defp save_pinned(dashboard, layout) do
    dashboard
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:layout, layout)
    |> persist()
  end

  # ── Live sync + optimistic concurrency (the single write choke point) ──
  #
  # `persist/1` is the ONE place a dashboard mutation reaches the database, so
  # it owns two guarantees:
  #
  #   1. LIVE SYNC — on success it broadcasts the new state to every subscribed
  #      session, so a dashboard open on a TV re-renders the instant someone
  #      edits it from their laptop (`subscribe/1` + `{:dashboard_updated, _}`).
  #
  #   2. NO SILENT LOST UPDATES — an optimistic lock on a monotonic
  #      `config["rev"]` counter (compare-and-swap, so NO schema migration): the
  #      write only lands if `rev` is still what we read. A concurrent session
  #      that wrote first bumps `rev`, our CAS matches 0 rows, and we return
  #      `{:error, :stale}` instead of clobbering their edit — the LiveView
  #      re-syncs (and PubSub has already pushed it the winning state anyway).
  @topic_prefix "phoenix_kit_dashboards:"

  @doc "The PubSub topic carrying one dashboard's live updates."
  @spec topic(String.t()) :: String.t()
  def topic(uuid) when is_binary(uuid), do: @topic_prefix <> uuid

  @doc """
  Subscribe the caller to a dashboard's live updates. Delivers
  `{:dashboard_updated, %Dashboard{}}` on every edit and `{:dashboard_deleted,
  uuid}` when it's removed — the spine of live multi-session editing.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(uuid) when is_binary(uuid) do
    PubSubHelper.subscribe(topic(uuid))
  rescue
    # A missing/misconfigured PubSub server (or a test env without one) must
    # not crash the mount — the page just loses live sync, not correctness.
    _ -> {:error, :pubsub_unavailable}
  end

  defp persist(%Ecto.Changeset{} = changeset) do
    with {:ok, _applied} <- Ecto.Changeset.apply_action(changeset, :update) do
      original = changeset.data
      expected = rev(original)

      base_config = Map.get(changeset.changes, :config, original.config || %{})
      new_config = Map.put(base_config, "rev", expected + 1)
      now = DateTime.truncate(DateTime.utc_now(), :second)

      set =
        changeset.changes
        |> Map.put(:config, new_config)
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      {count, _} =
        Dashboard
        |> where([d], d.uuid == ^original.uuid)
        # Guard the ::int cast with a digit-only regex so a tampered/corrupt
        # non-numeric stored rev matches as 0 (like rev/1 treats it) instead of
        # raising an uncaught "invalid input syntax for integer" DB error.
        |> where(
          [d],
          fragment(
            "(case when (?->>'rev') ~ '^[0-9]+$' then (?->>'rev')::int else 0 end)",
            d.config,
            d.config
          ) == ^expected
        )
        |> repo().update_all(set: set)

      if count == 1 do
        updated = Ecto.Changeset.apply_changes(changeset)
        updated = %{updated | config: new_config, updated_at: now}
        broadcast(topic(updated.uuid), {:dashboard_updated, updated})
        {:ok, updated}
      else
        {:error, :stale}
      end
    end
  end

  defp rev(%Dashboard{config: config}) when is_map(config) do
    case Map.get(config, "rev") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp rev(_), do: 0

  # Broadcast never crashes a mutation: a missing/misconfigured PubSub server
  # must not fail the write (the edit still persisted).
  defp broadcast(topic, message) do
    PubSubHelper.broadcast(topic, message)
    :ok
  rescue
    _ -> :ok
  end

  # A designed layout: stored explicit cells render verbatim; order-only
  # placements (pre-cells data, or none at all) pack into the remaining free
  # cells in `pos` order. Reading-order output.
  defp resolve_designed(dashboard, layout_id) do
    cols = grid_cols(dashboard, layout_id)
    rows = grid_rows(dashboard, layout_id)

    entries =
      dashboard.layout
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        placement =
          item
          |> Layout.placement(layout_id)
          |> Map.put_new("pos", idx)
          |> default_span(item, layout_id)

        {item, placement}
      end)

    {placed, unplaced} =
      Enum.split_with(entries, fn {_item, p} -> is_integer(p["x"]) and is_integer(p["y"]) end)

    # Pack the order-only widgets (in `pos` order) around the already-placed
    # ones via the shared Grid primitive, then re-pair each result with its item.
    sorted = Enum.sort_by(unplaced, fn {_item, p} -> p["pos"] end)

    packed =
      sorted
      |> Enum.map(fn {_item, p} -> p end)
      |> Grid.pack(Enum.map(placed, fn {_i, p} -> p end), cols, rows)
      |> then(&Enum.zip(sorted, &1))
      |> Enum.map(fn {{item, _p}, p2} -> {item, p2} end)

    Enum.sort_by(placed ++ packed, fn {_item, p} -> {p["y"], p["x"], p["pos"]} end)
  end

  # A widget with no stored span for this layout packs at its TYPE's default
  # size (layouts are independent — no cross-layout derivation). Layout's own
  # w/h fallback only ever shows for widgets whose module is uninstalled.
  defp default_span(placement, item, layout_id) do
    stored = get_in(item, ["bp", layout_id]) || %{}

    case Registry.get(item["widget_key"]) do
      %Widget{default_size: default} ->
        placement
        |> then(&if Map.has_key?(stored, "w"), do: &1, else: Map.put(&1, "w", default.w))
        |> then(&if Map.has_key?(stored, "h"), do: &1, else: Map.put(&1, "h", default.h))

      nil ->
        placement
    end
  end

  # Before ANY grid edit at `layout_id`, pin every widget's currently-resolved placement
  # (explicit cells included) into that layout — so editing one widget can't
  # shift the others (they're anchored where the user sees them), whether the
  # layout was deriving or holds pre-cells order-only data. No-op once every
  # widget has stored cells.
  defp materialize_grid(%Dashboard{} = dashboard, layout_id) do
    if grid_materialized?(dashboard, layout_id) do
      dashboard
    else
      resolved = Map.new(resolve_items(dashboard, layout_id), fn {item, p} -> {item["id"], p} end)

      %{
        dashboard
        | layout: Enum.map(dashboard.layout, &materialize_item(&1, layout_id, resolved))
      }
    end
  end

  defp grid_materialized?(dashboard, layout_id) do
    Enum.all?(dashboard.layout, fn item ->
      p = get_in(item, ["bp", layout_id])
      is_map(p) and is_integer(p["x"]) and is_integer(p["y"])
    end)
  end

  defp materialize_item(item, layout_id, resolved) do
    case resolved[item["id"]] do
      nil -> item
      placement -> Layout.put_placement(item, layout_id, placement)
    end
  end

  # The first free pixel row below every placed widget, so a new pixel-canvas
  # widget stacks under the others instead of overlapping.
  defp next_pixel_y([]), do: 0

  defp next_pixel_y(layout) do
    layout
    |> Enum.map(fn inst ->
      px = Layout.pixel(inst)
      int(px["fy"], 0) + int(px["fh"], 0)
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(16)
  end

  # Merge one key into the dashboard's config map and persist it.
  defp put_config(dashboard, key, value) do
    dashboard
    |> Dashboard.config_changeset(Map.put(dashboard.config, key, value))
    |> persist()
  end

  # Clamp + integer coercion delegate to the single Lattice implementation (was
  # a divergent local copy — see Sizing / Lattice for the consolidation).
  defp clamp(value, lo, hi), do: Lattice.clamp(value, lo, hi)
  defp int(v, default), do: Lattice.to_int(v, default)

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
