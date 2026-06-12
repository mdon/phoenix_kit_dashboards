defmodule PhoenixKitDashboards.Schemas.Dashboard do
  @moduledoc """
  A dashboard page: an ordered set of placed widgets owned by a user (personal)
  or by the system / a role (shared).

  The `layout` field is a JSONB list of **widget instances** — read-whole,
  write-whole, mirroring `phoenix_kit_crm`'s per-user `view_config` precedent.
  Each instance is a map:

      %{
        "id"         => "<uuid>",                  # instance id (unique within the dashboard)
        "widget_key" => "emails.deliverability",   # which catalog widget type
        "x" => 0, "y" => 0, "w" => 6, "h" => 2,    # free 2D grid placement (12-col)
        "settings"   => %{ ... }                   # per-instance customizations
      }

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

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          title: String.t() | nil,
          slug: String.t() | nil,
          owner_user_uuid: String.t() | nil,
          role_uuid: String.t() | nil,
          scope: String.t(),
          layout: [map()],
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
    field(:is_default, :boolean, default: false)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating / updating a dashboard's metadata."
  def changeset(dashboard, attrs) do
    dashboard
    |> cast(attrs, [
      :title,
      :slug,
      :owner_user_uuid,
      :role_uuid,
      :scope,
      :layout,
      :is_default,
      :position
    ])
    |> validate_required([:title, :scope])
    |> validate_inclusion(:scope, @scopes)
    |> maybe_put_slug()
    |> unique_constraint([:owner_user_uuid, :slug],
      name: :phoenix_kit_dashboards_owner_slug_index
    )
  end

  @doc "Changeset that only replaces the layout (the hot path during editing)."
  def layout_changeset(dashboard, layout) when is_list(layout) do
    change(dashboard, layout: layout)
  end

  @doc "List of valid scope strings."
  def scopes, do: @scopes

  defp maybe_put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        title = get_field(changeset, :title) || ""
        put_change(changeset, :slug, slugify(title))

      _ ->
        changeset
    end
  end

  defp slugify(title) do
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
