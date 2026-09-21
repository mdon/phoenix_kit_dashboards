# AGENTS.md

Guidance for AI agents working on `phoenix_kit_dashboards`.

## Overview

`phoenix_kit_dashboards` lets users build dashboard pages out of **widgets**
contributed by any PhoenixKit module. It implements the `PhoenixKit.Module`
behaviour for zero-config auto-discovery. A widget *type* is a plain map a
provider returns from `phoenix_kit_widgets/0`; a dashboard is a user-owned 2D
canvas of placed widget *instances*, persisted as a JSONB `layout` list, scoped
personal / system / role.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex). No sibling `phoenix_kit_*` deps —
  the widget contract is duck-typed, so a provider is never a dependency.
- **Consumed by:** nothing. The dependency arrow points one way (a provider
  exposes `phoenix_kit_widgets/0`; this module discovers it at runtime).
  `phoenix_kit_projects` additionally consumes the duck-typed
  `phoenix_kit_project_extensions/0` entry this module exports.
- **Admin surface:** one visible tab **Dashboards** (`/admin/dashboards`,
  priority 650, group `:admin_modules`) plus four hidden tabs —
  `dashboards/new`, `dashboards/:uuid/edit` (form) and `dashboards/:uuid`
  (builder), one VISIBLE subtab **Places** (`dashboards/places`, the placement
  control screen) — plus one generated tab per declared `:module_tab` slot at
  `dashboards/places/<slug>`, hung under the DECLARING module's sidebar entry.
- **Module key** `"dashboards"`; settings prefix `dashboards_` (only
  `dashboards_enabled` today).

## What this module does NOT do

- **No DDL of its own beyond adopting `phoenix_kit_dashboards`' existing
  shape** — see "Database & migrations". `PhoenixKitDashboards.Migrations`
  owns that table's FUTURE shape; it does not create any OTHER table.
- **No Ecto repo** — DB access goes through `PhoenixKit.RepoHelper.repo/0`.
- **No `route_module/0`** — every page is an `admin_tabs/0` entry with
  `live_view:` set (single-page pattern, like `phoenix_kit_locations` /
  `phoenix_kit_catalogue`). `route_module/0` is only for locale-prefixed route
  variants; adding one here would register the same paths twice.
- **No dependency on widget providers** — a provider must stay usable without
  this package installed.
- **No one-click presets** — a new dashboard starts empty (see TODOs).
- **No DDL for placements either** — they live in the `dashboards_placements`
  setting and in each personal dashboard's own `config["slot"]`.
- **No slot invented for a module that did not declare one.** Core groups
  sub-tabs by parent id with no ownership check, so this module *could* inject
  a tab anywhere; declaring a slot is the consent, and nothing appears without
  one.
- **No viewport/tier detection** — a grid dashboard opens on its first named
  layout, not on a layout picked from the device width.

## Commands

```bash
mix deps.get
createdb phoenix_kit_dashboards_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

`MIX_ENV=test mix test.setup` creates the test database and `MIX_ENV=test mix
test.reset` drops and recreates it. Both need `MIX_ENV=test`: `Test.Repo` is
compiled only in that environment, so the alias fails with `:nofile` in `dev`.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.
- `mix test.reset` — drops the test database and recreates it.

## Conventions

- **Module key** `"dashboards"`, used identically in every callback, the
  permission key and `update_boolean_setting_with_module/3`.
- **Tab ids** are prefixed `:admin_` (`:admin_dashboards`, …); **URL segments use
  hyphens**.
- **Paths** always come from `PhoenixKitDashboards.Paths`
  (`index/0`, `new/0`, `edit/1`, `builder/1`), which routes through
  `PhoenixKit.Utils.Routes.path/1` so the host's PhoenixKit URL prefix and
  locale are honoured. Never hardcode `/admin/dashboards`.
- **Routing** is the single-page pattern: pages are `admin_tabs/0` entries with
  `live_view:` set; hidden ones carry `visible: false` and a `parent:`, and the
  `:uuid` dynamic segment is spliced verbatim into the generated route. Never
  hand-register these routes in a host router, and do not add `route_module/0`.
- **LiveView macro:** admin LiveViews (`DashboardsLive`, `BuilderLive`,
  `DashboardFormLive`) use `use PhoenixKitWeb, :live_view`;
  `BuilderComponents` uses `use PhoenixKitWeb, :html`. `ProjectDashboardLive`
  is plain `use Phoenix.LiveView` because it is embedded as a tab inside the
  projects hub rather than mounted as an admin page. Widgets are
  `Phoenix.LiveComponent`s. No template wraps in `LayoutWrapper` — core's admin
  layout already surrounds them.
- **Gettext:** this module ships its **own** backend
  (`PhoenixKitDashboards.Gettext`, `priv/gettext/{en,et,ru}`). Every
  LiveView/component adds `use Gettext, backend: PhoenixKitDashboards.Gettext`
  explicitly, **after** `use PhoenixKitWeb, :live_view`/`:html` — the later
  `use Gettext` shadows core's backend, so the ordering is load-bearing.
  Extract/merge with `mix gettext.extract --merge`.
  - `Web.Helpers.translate_catalog/1` is the runtime path for catalog **data**
    (widget names/descriptions/view names/settings labels — plain strings that
    arrive from the provider contract) via
    `Gettext.gettext(PhoenixKitDashboards.Gettext, string)`.
  - Because `mix gettext.extract` cannot see a literal behind a variable, every
    such msgid needs a **noop anchor**: `Widgets.__catalog_strings__/0`
    (`gettext_noop/1`) pins the built-in widgets' catalog strings, and
    `translatable_labels/0` (`dgettext_noop/2`) pins the four tab labels (one of
    which doubles as the permission label) that `Tab.localized_label/1` and
    `Permissions.localized_module_label/1` translate at render time through each
    declaration's `gettext_backend`/`gettext_domain`.
- **JS hooks** ship as a prebuilt bundle declared by `js_sources/0`
  (`priv/static/assets/phoenix_kit_dashboards.js`, global
  `PhoenixKitDashboardsHooks`): `DashboardGridDrag`, `DashboardCatalogDrag`,
  `DashboardFreeDrag`, `DashboardResize`, `DashboardGridFit`,
  `DashboardFreeFit`, `DashboardFitScreen`, `DashboardFullscreen`,
  `DashboardVisibility`. They are **enhancement only** — both dashboard types
  render and stay fully operable without JavaScript through the Settings
  modal's size / Column-Row / X-Y inputs, and nothing uses
  `phx-update="ignore"`. Never register a hook from an inline `<script>`:
  morphdom does not execute inserted script tags, so the hook vanishes on
  LiveView navigation. `js_sources/0` carries no `@impl` — older core releases
  do not declare the callback.
- **Tailwind:** `css_sources/0` returns `[:phoenix_kit_dashboards]`; core's
  `:phoenix_kit_css_sources` compiler wires the host's `@source` at compile
  time, so templates are scanned with no host configuration.
- **Page layout:** an admin page wraps in
  `<div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">` and carries
  **no in-page `<h1>`** — the admin header breadcrumb already renders
  `@page_title`, so the page reclaims the space. Embedded surfaces
  (`AdminHomeLive`, `ProjectDashboardLive`) add no container of their own: the
  host page already pads them.
- **Every name is a link.** A place opens its page, a dashboard opens its
  builder — from Places, the library and a slot header alike.
- **Form components** come from core:
  `PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}`
  (`<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>`), which render the
  daisyUI 5 `<label class="select">` wrapper. Never put the `select` class
  directly on a `<select>`.
- **`enabled?/0`** reads `dashboards_enabled`, rescues and catches `:exit`, and
  returns `false` on any failure. `enable_system/0` also calls
  `Registry.refresh/0` so a provider enabled alongside this module is picked up
  without a BEAM restart.
- **Activity logging:** every mutating context function takes `opts \\ []` and
  logs through core's `PhoenixKit.Activity.log/3`, which never raises, so a
  logging failure never crashes the mutation. LiveViews thread the actor with
  `Web.Helpers.actor_opts/1` (core's `PhoenixKitWeb.Actor`). `save_layout/2` is the drag/resize
  hot path and is deliberately **not** logged.
- **Dashboard type is fixed at creation** — `config["type"]` is `"grid"` or
  `"pixel"` and there is no runtime toggle (legacy `config["mode"]` `"free"`
  still maps to `"pixel"`). A type change means creating a new dashboard.
- **Scopes and sharing:** `personal` (owner-private) / `system` (shared with
  everyone) / `role` (visible to a role's members).
  - **Role-scope creation is hidden in the UI**: the form page authors
    personal/system only. The backend keeps full role support
    (`list_for_user/2` role visibility, the handler path), and an
    already-role-scoped dashboard is grandfathered on its edit page (role picker
    from core `Roles.list_roles/0`) so a save cannot silently convert it.
  - The manage page **clones** any visible dashboard into a private copy and
    gates visibility/delete via `Web.Helpers.viewable_by?/2` and
    `manageable_by?/2` (context-side: `Dashboards.visible_to?/3`).
    `list_for_user/2` takes the user's role uuids so role dashboards surface for
    their members.
  - Only `system` dashboards may back a project-extension tab
    (`project_dashboard_options/0` lists exactly those) — personal and role
    dashboards carry per-user visibility a project-wide tab cannot honour.
- **One write choke point:** every mutation reaches the database through the
  context's private `persist/1`, which owns both live sync (broadcast) and the
  optimistic lock. Do not add a second write path.
- **UUIDv7 primary keys** (`@primary_key {:uuid, UUIDv7, autogenerate: true}`)
  and `use PhoenixKit.SchemaPrefix` on every table-backed schema.

### Landmines

- Tabs generate routes in declaration order: the static `dashboards/new` MUST be
  declared before the dynamic `dashboards/:uuid`, or the builder route swallows
  the create page.
- A catalog string that reaches gettext through a variable (widget names, view
  names, settings labels, tab/permission labels) is invisible to
  `mix gettext.extract` — if the msgid is not pinned by
  `Widgets.__catalog_strings__/0` or `translatable_labels/0`, it silently never
  enters `default.pot` and renders untranslated.
- The Registry catalog's **structure** is memoized in `:persistent_term`: a
  newly installed provider, a changed widget definition (`views`,
  `settings_schema`, `refresh_interval`) or a computed option list (e.g. the
  module-stats picker) does not appear until `Registry.refresh/0` runs.
  Enablement and permissions are re-checked live and need no refresh.
- `BuilderLive.render/1` reads `@phoenix_kit_current_scope` strictly, so
  `Test.Hooks`'s `nil` branch must still assign it (as `nil`); dropping that
  branch raises `KeyError` in every builder test that sets no scope.
- Placement edits persist via `Ecto.Changeset.force_change/3`: `materialize_grid`
  pre-mutates the struct in memory, so a plain `change/2` diffs against the
  materialized copy and silently skips the write when the edit equals the packed
  values.
- A `:module_tab` slot's URL is built by THIS package
  (`dashboards/places/<slug>`), never inside the declaring module's namespace.
  Routes are generated per module in declaration order, so a slot naming
  `projects/dashboard` is swallowed by that module's dynamic `projects/:id`
  and renders its show page against the literal id `"dashboard"`. The sidebar
  position comes from `parent_tab`, which is independent of the URL. The
  top-level Dashboards tab therefore cannot use a plain `:prefix` match — it
  would light up alongside the slot's own tab for one page — so it carries a
  regex excluding `dashboards/places/<slug>`, and the Places screen itself
  matches `:exact`.
- The slot catalog must be discovered through **`ModuleDiscovery`** (a beam
  scan) as well as `ModuleRegistry` (a runtime `:persistent_term`). Slot tabs
  feed `admin_tabs/0`, which core turns into ROUTES at **compile** time, when
  the runtime registry is still empty — registry-only discovery produced no
  slot routes at all, then memoized the empty catalog for the life of the BEAM.
  `refresh/0` only caches a catalog built from a populated module list.
- A **bind** lives on the layout item beside `settings`, never inside it: a
  marker stored in a uuid-shaped settings field is eaten by validation and
  makes the settings form display a value the widget is not using.
- An instance saved before binds existed has no bind, and its stored id is
  treated as a **pin**. Never reinterpret a saved selection as "this page's" —
  that silently changes which record someone's board shows.

## Architecture

```
lib/phoenix_kit_dashboards.ex          # PhoenixKit.Module callbacks + both provider contracts
lib/phoenix_kit_dashboards/
  migrations.ex                        # module-owned migration chain (pkd_schema:<N> marker)
  dashboards.ex                        # context: CRUD, placement, live sync, optimistic lock
  schemas/dashboard.ex                 # the phoenix_kit_dashboards schema (JSONB layout + config)
  widget.ex                            # widget TYPE struct + from_map/2 normalization
  registry.ex                          # provider discovery + :persistent_term catalog
  widgets.ex, widgets/*.ex             # built-in widgets (note, clock, module stats)
  layout.ex, grid.ex, lattice.ex, sizing.ex, layouts.ex  # geometry + placement engine
  slot.ex, slots.ex                    # the SLOT contract + its catalog (mirrors widget.ex/registry.ex)
  placements.ex                        # dashboard -> slot -> audience, and resolution
  binds.ex                             # host-side resolution of a widget's context subject
  refresh.ex                           # the shared widget refresh loop (all four surfaces)
  paths.ex, gettext.ex
  web/                                 # DashboardsLive, DashboardFormLive, BuilderLive,
                                       # PlacesLive, SlotLive, AdminHomeLive,
                                       # ProjectDashboardLive, BuilderComponents,
                                       # SlotComponents, Helpers
priv/static/assets/phoenix_kit_dashboards.js   # the js_sources/0 hook bundle
```

Key modules:

- `PhoenixKitDashboards` — `PhoenixKit.Module` callbacks (`module_key`,
  `enabled?`, `enable_system`/`disable_system`, `version`, `admin_tabs`,
  `permission_metadata`, `css_sources`, `js_sources`, `get_config`) plus
  `phoenix_kit_widgets/0` and `phoenix_kit_project_extensions/0`.
- `PhoenixKitDashboards.Registry` — convention-based discovery: queries
  `PhoenixKit.ModuleRegistry` and calls `phoenix_kit_widgets/0` on any module
  exporting it (always including this one), memoizes in `:persistent_term`, and
  filters by module enablement + scope permission on every read
  (`visible_for_scope?/2` is the render gate for already-placed widgets too).
- `PhoenixKitDashboards.Widget` — the widget type struct and `from_map/2`, which
  normalizes and sanitizes the plain-map contract; a malformed entry is dropped,
  never allowed to abort catalog discovery.
- `PhoenixKitDashboards.Lattice` / `Layout` / `Grid` / `Sizing` / `Layouts` —
  the 25px square-cell design space and the placement/packing engine.
- `PhoenixKitDashboards.Dashboards` — the context. `persist/1` is the single
  write choke point.
- `PhoenixKitDashboards.Web.Helpers` — `actor_opts/1`, `translate_catalog/1`,
  `viewable_by?/2`, `manageable_by?/2`, `user_role_uuids/1`.

### Widget provider contract

Any module exposes widget types by defining a zero-arity `phoenix_kit_widgets/0`
returning **plain maps** — no dependency on this package, no `@impl`, no new core
callback. A host app that is not a PhoenixKit module declares providers in
config instead: `config :phoenix_kit_dashboards, widget_providers: [MyApp.Widgets]`.

| Key | Required | Meaning |
|---|---|---|
| `key` | yes | Globally unique catalog key (`"emails.deliverability"`). |
| `name` | yes | Display name (translated through `translate_catalog/1`). |
| `component` | yes | A `Phoenix.LiveComponent` module. |
| `module_key` | no | Gates the widget on that module's enablement + permission. Absent = always offered. |
| `default_size` / `min_size` | no | Lattice units. Defaults `%{w: 16, h: 8}` / `%{w: 8, h: 4}`. |
| `max_size` | no | Accepted but **ignored** — every widget may span the full lattice (160). |
| `settings_schema` | no | `[%{key, type, label, options, default}]`; types `:string`, `:text`, `:number`, `:boolean`, `:select`. Select `options` may be `{label, value}` tuples. |
| `views` | no | `[%{key, name, min_size}]` named render variants; a view may raise the size floor (`min_size_for/2`). |
| `refresh_interval` | no | Milliseconds, floored to 1000. The host runs one `:refresh_tick` loop and `send_update/2`s each due widget — widgets never subscribe or time themselves (a LiveComponent has no process). |
| `description`, `icon`, `category` | no | Catalog presentation. |

The host renders `<.live_component module={w.component} id={instance_id}
settings={…} view={…} size={%{w:, h:}} scope={…} />`, so one widget can render
several densities and degrade when small. Each widget owns its own data loading.

`phoenix_kit_project_extensions/0` is the same style of duck-typed contract in
the other direction: it offers `phoenix_kit_projects` a read-only **Dashboard**
tab (`Web.ProjectDashboardLive`) rendering one linked shared dashboard, picked
via `config_schema` from `project_dashboard_options/0`.

### Slot + placement contracts

A **slot** is a place a dashboard can be shown; a **placement** binds a
dashboard to one, for one audience. Both are the same duck-typed style as
widgets — a module defines a zero-arity function returning plain maps.

`phoenix_kit_dashboard_slots/0`:

| Key | Required | Meaning |
|---|---|---|
| `key` | yes | Globally unique (`"projects.project"`). |
| `name` | yes | Plain-language, shown on the Places screen. |
| `surface` | no | `:module_tab` (a sidebar sub-tab), `:record_tab` (rendered by the owning module inside one record), `:admin_home`. Default `:module_tab`. |
| `parent_tab` | for `:module_tab` | Sidebar tab id to hang under. The URL is this package's; a slot never names one. |
| `slug` | no | Last URL segment (`dashboards/places/<slug>`). Defaults to the key. |
| `module_key` | no | Gates the slot AND its generated tab on that module. |
| `provides` | no | Context kinds supplied at render (`["projects.project"]`). |
| `cardinality` | no | `:one` (default) or `:many` — several dashboards as tabs. |
| `allow_personal`, `chrome`, `icon`, `description`, `priority` | no | Behaviour + presentation. |

`phoenix_kit_dashboard_viewer_context/2` — `(kind, scope) -> id | nil`. Answers
"which one is MINE" for a context kind. Only the module owning the record can
answer it, and a shared role dashboard on a context-free page needs it: slot
context alone cannot give each project manager their own project.

A settings field may declare `context: "<kind>"`, marking it as holding a
context subject. The field still stores a plain id; declaring the kind is what
lets the host offer "the one this page is about" / "mine" and resolve either
into it.

**Resolution** (`Placements.resolve/3`) is personal → role → everyone. Tiers
REPLACE rather than merge, and only one role may win — chosen by an explicit
integer `priority` (lower wins), because a viewer with two matching roles
would otherwise resolve by whatever order the role list came back in.

The **personal** tier is reached through `Web.Personal` ("Make it mine" /
"Use the shared one"), shared by every surface that renders a place so the two
cannot drift. Forking copies the board on screen and places the copy for that
person; it changes nothing anyone else sees. Resetting UNPLACES the copy and
never deletes it — the work stays in the library. `clone/3` therefore strips
`config["slot"]`: a copy is unplaced until someone says otherwise, or one
person ends up with two dashboards claiming one place.

**Binds** (`PhoenixKitDashboards.Binds`) resolve in the HOST, never the widget:
the duck-typed contract forbids requiring widget changes, so the concrete value
is written into the widget's own settings field before render and every
existing widget works untouched. A layout item carries
`"binds" => %{kind => "slot" | "viewer" | %{"pin" => id}}` beside `settings`.
An unresolvable bind renders an explanatory card — never hidden (reads as a
deleted widget, leaves a hole in the grid) and never a fallback record (that is
how one project's numbers reach another's screen).

### Data model

One table, `phoenix_kit_dashboards`: `uuid` (UUIDv7 PK), `title`, `slug`,
`owner_user_uuid` (FK → `phoenix_kit_users`, `ON DELETE CASCADE`), `role_uuid`,
`scope`, `layout` (JSONB array), `config` (JSONB), `is_default`, `position`,
timestamps. `[owner_user_uuid, slug]` is unique; `create/2` auto-uniquifies the
title-derived slug with `-N` suffixes, retrying on a concurrent insert.

- `layout` is read-whole / write-whole. One item is
  `%{"id", "widget_key", "view", "settings", "pixel" => %{fx,fy,fw,fh}, "bp" => %{<layout_id> => %{x,y,w,h,hidden,pos}}}`
  — geometry is embedded per widget so add/remove is atomic. The `"bp"` key name
  is kept for back-compat but is keyed by **layout id**, not a breakpoint.
- `config` holds dashboard-level state: `"type"` (`"grid"` | `"pixel"`, fixed at
  creation), the ordered `"layouts"` list (`[%{"id","name","cols","rows"}]`), and
  `"rev"`.
- `config["rev"]` is a monotonic counter used as an **optimistic lock**: a write
  lands only if `rev` is unchanged (compare-and-swap, so no migration). A losing
  writer gets `{:error, :stale}` and re-syncs instead of clobbering the winner.

### PubSub

`Dashboards.topic(uuid)` = `"phoenix_kit_dashboards:<uuid>"`, subscribed via
`Dashboards.subscribe/1` (which rescues to `{:error, :pubsub_unavailable}` so a
missing PubSub server costs live sync, not the mount). Messages:
`{:dashboard_updated, %Dashboard{}}` and `{:dashboard_deleted, uuid}`.
`PubSubHelper` is used for both directions so cross-module broadcasts land on
the host's PubSub; broadcast failures never crash a mutation.

### Settings & permissions

- Setting `dashboards_enabled` (boolean) — the module gate.
- Permission key `"dashboards"`, declared by `permission_metadata/0` with
  `gettext_backend:`/`gettext_domain:` so the admin matrix renders it
  translated. All four tabs require it. The project extension declares
  `permission_actions: [:view]`.
- Host config `:phoenix_kit_dashboards, :widget_providers` — extra provider
  modules (see the contract table above).

## Database & migrations

`phoenix_kit_dashboards` (the table) and its `config` column were originally
created by **core's** versioned chain (`V133`/`V139`). Its FUTURE shape is now
owned by this module's own migration chain,
`PhoenixKitDashboards.Migrations` (`migration_module/0`), following the
canonical dual-reader protocol `phoenix_kit_hello_world` documents and
`phoenix_kit_boards`/`phoenix_kit_web_analytics` run in production —
`migrated_version/1` (migration context, via `Ecto.Migration`'s `repo()`, no
rescue) and `migrated_version_runtime/1` (the one `mix phoenix_kit.update`
calls, via `PhoenixKit.RepoHelper.repo()`, rescues to `0` except an invalid
prefix, which re-raises); `up/1` re-reads the version through
`migrated_version/1` before changing anything. The chain version is tracked
as a `pkd_schema:<N>` `COMMENT ON TABLE` marker; a marker-less table, or one
carrying a foreign (non-`pkd_schema:`) comment, reads as version 0. Varchar
widths are sourced from `PhoenixKitDashboards.Schemas.Dashboard.column_widths/0`
— never a second hard-coded number in the migration DDL.

Ownership unfolds in three phases (see the moduledoc for the full account):
**Phase 0** (this V1) is a pure **adoption** — it reproduces core's
V133/V139 shape under core's exact object names (idempotent `CREATE
TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` / guarded `DO $$ ... $$`
constraint blocks), so on every existing install it changes nothing except
stamping the marker; because it changes no shape, core's `ExpectedSchema`
manifest stays accurate and no core release was required to ship it.
**Phase 1** is the first real shape change (a future V2+) — it requires
first adding the altered objects to core's manifest generator's
`@excluded_exact` and regenerating `ExpectedSchema`, then raising this
package's core floor. **Phase 2** is a future core baseline squash that
drops this table from core's own chain entirely — V1's `CREATE TABLE` is
therefore already a fully self-sufficient definition (it calls
`Helpers.ensure_extension!/1` + `Helpers.ensure_uuid_v7_function/1` rather
than assuming core's chain provided them), not merely a shape-matching
no-op for an already-existing table.

**A table-shape change to `phoenix_kit_dashboards` is a new version in this
chain from now on — never a new core migration.** `down/1` NEVER drops the
table or its data, for any target including `0`; rolling this chain back
only unstamps (or re-stamps) the marker. There is deliberately no automated
uninstall path — README.md's "Removing this module" section has the manual
operator SQL. A host picks up a pending version the next time it runs `mix
phoenix_kit.update`, which generates its own
`dashboards_update_v00_to_v01.exs` migration file.

Table-backed schemas use UUIDv7 primary keys and `use PhoenixKit.SchemaPrefix`,
and all DB access goes through `PhoenixKit.RepoHelper.repo/0`.

## Testing

Two levels: **unit** (no database — `test/phoenix_kit_dashboards_test.exs` and
the geometry suites) and **integration** (`:integration`, applied automatically
by `DataCase`/`LiveCase`, needs PostgreSQL). Without a database the integration
tag is excluded and the unit tests still run.

Test database `phoenix_kit_dashboards_test` (`mix test.setup` creates it).
`test/test_helper.exs` requires the `test/support` files explicitly (Elixir 1.19
no longer auto-loads them), probes for the database with `psql -lqt`, builds the
schema with `PhoenixKit.Migration.ensure_current/2`, starts
`PhoenixKit.PubSub.Manager` + `PhoenixKit.ModuleRegistry`, forces the URL-prefix
cache to `"/"` so `Paths` matches the test router, and starts the test Endpoint
only when the database is available.

Support harness in `test/support/`: `Test.Repo`, `Test.Endpoint`, `Test.Router`
(scoped `/en/admin/dashboards`), `Test.Layouts`, `Test.Hooks` (`:assign_scope`
`on_mount`), `DataCase`, `LiveCase` (`fake_scope/1`, `put_test_scope/2`,
`fixture_dashboard/2`), `Fixtures` (`user_fixture/1` — a real `phoenix_kit_users`
row is required for the owner FK), `ActivityLogAssertions`.

`config/test.exs` honours `PGUSER` / `PGPASSWORD` / `PGHOST` (defaults
`postgres`), `PGDATABASE` and `PGPOOL`. A local Postgres without a `postgres`
role needs `PGUSER=<your role>`, or the suite fails as pool timeouts that look
like flakiness. `PGPOOL` bounds the pool (default
`System.schedulers_online() * 2`, too many connections for a shared instance).

> **Caution:** do not combine `PGDATABASE` (pointing at a shared database) with
> `PHOENIX_KIT_PATH`. `ensure_current/2` would then run that local core's
> migration chain against the shared database, moving the schema for every other
> module pointed at it.

`test/i18n_test.exs` smoke-tests the per-module i18n wiring. It is tagged
`:requires_phoenix_kit_i18n_api` and excluded only if `phoenix_kit` ever resolves
below the release that shipped the `gettext_backend:` API — a defensive guard
against a stale lockfile, since the `mix.exs` floor already postdates it.

## Feature notes

| Feature | Invariant that must hold | Guide |
|---|---|---|
| Grid + pixel canvas, named layouts, drag/resize hooks | A grid layout is exactly one screenful (nothing scrolls); hooks are enhancement only and both types stay operable with JavaScript off. | [`dev_docs/guides/layout-model.md`](dev_docs/guides/layout-model.md) |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **Dashboard presets.** Offer one-click presets when creating (or on an empty)
  dashboard: the user picks e.g. "Overview" and gets a ready-made set of widgets
  already placed and configured (an overview preset ≈ projects board + workload
  + deadlines; a personal preset ≈ my-tasks + only-my-projects deadlines + a
  clock). Likely shape: a preset is data — a named list of
  `{widget_key, view, settings, size}` entries laid out by the same first-free
  packing as `add_widget/3` — and modules could contribute presets the same
  duck-typed way they contribute widgets. Not designed yet; unblocked by a
  product decision on which presets ship.
