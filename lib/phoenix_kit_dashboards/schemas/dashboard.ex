defmodule PhoenixKitDashboards.Schemas.Dashboard do
  @moduledoc """
  A dashboard page: an ordered set of placed widgets owned by a user (personal)
  or by the system / a role (shared).

  The `layout` field is a JSONB list of **widget instances** — read-whole,
  write-whole, mirroring `phoenix_kit_crm`'s per-user `view_config` precedent.
  **Geometry is embedded per widget** (see `PhoenixKitDashboards.Layout`) so
  add/remove is atomic. Each instance is a map:

      %{
        "id"         => "<uuid>",                  # instance id (unique within the dashboard)
        "widget_key" => "emails.deliverability",   # which catalog widget type
        "view"       => "detailed",                # selected render variant, or nil
        "settings"   => %{ ... },                  # per-instance customizations
        "pixel"      => %{"fx" => .., "fy" => .., "fw" => .., "fh" => ..},  # pixel canvas (px)
        "bp"         => %{"desktop" => %{"w" => 6, "h" => 2, "hidden" => false, "pos" => 0}, ...}
      }                                            # grid: per-breakpoint span/order/visibility

  Grid dashboards are a **responsive flow** — a widget's place is its `pos` in the
  active breakpoint, spanning `w` of that tier's columns (TV 16 / Desktop 12 /
  iPad 8 / Phone 4; see `PhoenixKitDashboards.Breakpoints`) and `h` rows. Pixel
  dashboards use `pixel` (absolute px). The `config` JSONB column holds
  dashboard-level state: `"type"` (`"grid"` | `"pixel"`, fixed at creation),
  per-breakpoint `"breakpoints"` metadata (`%{bp => %{"state" => "custom"}}`), and
  `"zoom"` (pixel).

  ## Scope

  - `"personal"` — `owner_user_uuid` set; private to that user.
  - `"system"`   — `owner_user_uuid` nil; visible to everyone (admin-authored).
  - `"role"`     — `role_uuid` set; visible to members of that role.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(personal system role)
  @layout_modes ~w(grid free)

  # A dashboard's TYPE is fixed at creation: "grid" (responsive breakpoints) or
  # "pixel" (a free-placement canvas). Replaces the old per-dashboard "mode"
  # toggle; legacy `config["mode"]` ("grid"/"free") maps to it.
  @types ~w(pixel grid)
  @default_type "grid"

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          title: String.t() | nil,
          slug: String.t() | nil,
          owner_user_uuid: String.t() | nil,
          role_uuid: String.t() | nil,
          scope: String.t(),
          layout: [map()],
          config: map(),
          is_default: boolean(),
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_dashboards" do
    field(:title, :string)
    field(:slug, :string)
    field(:owner_user_uuid, :binary_id)
    field(:role_uuid, :binary_id)
    field(:scope, :string, default: "personal")
    field(:layout, {:array, :map}, default: [])
    # Dashboard-level config (JSONB): "type" ("grid"|"pixel"), per-bp "breakpoints"
    # metadata, "zoom" (pixel).
    field(:config, :map, default: %{})
    field(:is_default, :boolean, default: false)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating / updating a dashboard's metadata."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(dashboard, attrs) do
    dashboard
    |> cast(attrs, [
      :title,
      :slug,
      :owner_user_uuid,
      :role_uuid,
      :scope,
      :layout,
      :config,
      :is_default,
      :position
    ])
    |> validate_required([:title, :scope])
    |> validate_inclusion(:scope, @scopes)
    |> validate_scope_target()
    |> maybe_put_slug()
    # Report the [owner_user_uuid, slug] uniqueness violation on :slug so the
    # context can detect a slug clash and retry with a suffix.
    |> unique_constraint(:slug, name: :phoenix_kit_dashboards_owner_slug_index)
  end

  @doc "Changeset that only replaces the layout (the hot path during editing)."
  @spec layout_changeset(t(), [map()]) :: Ecto.Changeset.t()
  def layout_changeset(dashboard, layout) when is_list(layout) do
    change(dashboard, layout: layout)
  end

  @doc "Changeset that only replaces the config map."
  @spec config_changeset(t(), map()) :: Ecto.Changeset.t()
  def config_changeset(dashboard, config) when is_map(config) do
    change(dashboard, config: config)
  end

  @doc "List of valid scope strings."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "List of valid layout-mode strings."
  @spec layout_modes() :: [String.t()]
  def layout_modes, do: @layout_modes

  @doc "List of valid dashboard type strings."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  The dashboard's fixed **type** — `"grid"` (responsive breakpoints) or `"pixel"`
  (free canvas). Reads `config["type"]`, falling back to the legacy
  `config["mode"]` (`"free"` → `"pixel"`), defaulting to `"grid"`.
  """
  @spec type(t()) :: String.t()
  def type(%__MODULE__{config: config}) do
    case config do
      %{"type" => t} when t in @types -> t
      %{"mode" => "free"} -> "pixel"
      %{"mode" => "grid"} -> "grid"
      _ -> @default_type
    end
  end

  @doc """
  Internal render mode — `"free"` (pixel canvas) or `"grid"` — derived from the
  dashboard `type/1`. Kept as the builder's rendering switch; the user-facing
  concept is `type/1` (chosen at creation).
  """
  @spec layout_mode(t()) :: String.t()
  def layout_mode(%__MODULE__{} = dashboard) do
    case type(dashboard) do
      "pixel" -> "free"
      _ -> "grid"
    end
  end

  # A scope must point at its audience — a "personal" dashboard without an owner
  # (or a "role" one without a role) would be visible to nobody, an orphan row
  # that only ever counts against slugs. Reject it at write time instead.
  defp validate_scope_target(changeset) do
    case get_field(changeset, :scope) do
      "personal" -> validate_required(changeset, [:owner_user_uuid])
      "role" -> validate_required(changeset, [:role_uuid])
      _ -> changeset
    end
  end

  defp maybe_put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        title = get_field(changeset, :title) || ""
        put_change(changeset, :slug, slugify(title))

      _ ->
        changeset
    end
  end

  @doc """
  Slugify a title (lowercase, dashes, ASCII-only), falling back to `"dashboard"`
  for a blank result. The `[owner_user_uuid, slug]` pair is unique, so the context
  suffixes on collision.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dashboard"
      slug -> slug
    end
  end
end
