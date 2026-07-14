# AGENTS.md

This file provides guidance to AI agents working in this repository.

## Project Overview

`phoenix_kit_dashboards` is a PhoenixKit module that lets users build custom
dashboard pages from **widgets** exposed by any PhoenixKit module. It implements
the `PhoenixKit.Module` behaviour for zero-config auto-discovery.

Two core ideas:

1. **Widget provider contract** — any module exposes widget *types* by defining
   `phoenix_kit_widgets/0` returning plain maps. Providers do **not** depend on
   this package; the dependency arrow points one way (data → never → dashboards).
2. **Dashboards are user-owned instances** — a dashboard is a free-form 2D grid
   of placed widget instances, persisted as a JSONB `layout` list (the
   `phoenix_kit_crm` `view_config` precedent), scoped personal / system / role.

## Key Modules

- `PhoenixKitDashboards` — `PhoenixKit.Module` callbacks (tab, permission,
  enable/disable, `version`, `css_sources`, `get_config`).
- `PhoenixKitDashboards.Widget` — the widget **type** struct + `from_map/2`
  normalization of the plain-map provider contract. Views may declare a per-view
  `min_size` (`min_size_for/2`); resize limits, the settings modal, and view
  switching (which auto-grows the placement where the grid has room) all honour
  the selected view's floor. `Widgets.ClockWidget` is the worked example:
  normal/digital/analog views (analog floors at 2×2), per-instance timezone
  (fixed UTC offsets always; IANA city zones only when the host configures a tz
  database) and a show/hide-timezone toggle.
- `PhoenixKitDashboards.Registry` — convention-based discovery (queries
  `PhoenixKit.ModuleRegistry`, calls `phoenix_kit_widgets/0` on exporters),
  cached in `:persistent_term`, filtered by module enablement + permissions.
- `PhoenixKitDashboards.Widgets` + `Widgets.*` — built-in widgets (Note, Clock,
  Module stats). Each is a `Phoenix.LiveComponent`.
- `PhoenixKitDashboards.Schemas.Dashboard` + `PhoenixKitDashboards.Dashboards` —
  schema (JSONB `layout`) + context. The `phoenix_kit_dashboards` table is created
  by **core** migration `V133` (see below), not by this module. The context logs
  a business activity on every user-meaningful mutation (create/update/delete +
  widget add/remove/configure); `save_layout/2` is the drag/resize hot path and is
  deliberately **not** logged.
- `PhoenixKitDashboards.Web.{DashboardsLive, BuilderLive}` — manage page + grid
  builder. `PhoenixKitDashboards.Web.Helpers` provides `actor_opts/1` for
  threading the acting user into context calls.

## Conventions (inherited from the PhoenixKit ecosystem)

- **Module key** `"dashboards"`, consistent across all callbacks.
- **Tab IDs** prefixed `:admin_` (`:admin_dashboards`).
- **URL paths** use hyphens; navigation always via `PhoenixKitDashboards.Paths`
  → `PhoenixKit.Utils.Routes.path/1`, never hardcoded.
- **UUIDv7 primary keys**: `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
- **No own repo** — DB access through `PhoenixKit.RepoHelper.repo/0`.
- **No DB work in modules** — modules never define migrations or DDL. New tables
  go into **core `phoenix_kit`** as a new versioned migration. The
  `phoenix_kit_dashboards` table is core `V133`
  (`phoenix_kit/lib/phoenix_kit/migrations/postgres/v133.ex`).
- **`enabled?/0`** rescues + catches `:exit`, returns `false` on any failure.
- **Activity logging** — every mutating context function accepts `opts \\ []` and
  logs via `PhoenixKit.Activity.log/1`, guarded with `Code.ensure_loaded?/1` +
  rescued so a logging failure never crashes the mutation. LiveViews pass
  `Web.Helpers.actor_opts/1`.
- **Gettext** — user-facing strings route to core's `PhoenixKitWeb.Gettext`
  (`Gettext.gettext(PhoenixKitWeb.Gettext, "...")`). This module ships no backend
  or `priv/gettext` — the standard for a small module.
- **Form components** — use core `PhoenixKitWeb.Components.Core.{Input, Select,
  Textarea, Checkbox}` (`<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>`),
  which render the daisyUI 5 `<label class="select">` wrapper. Never put the
  `select` class directly on `<select>`.

## The grid (Phoenix-first, no module JS)

The builder grid is **server-rendered HEEx + a CSS grid** — each widget is anchored
at its placement's explicit cells (`grid-column/-row: <x+1> / span <w>`) on the
active breakpoint's column grid. It renders and is readable **without any
JavaScript**, and every mutation (add / remove / move / resize) re-renders
normally — there is **no** `phx-update="ignore"` and no client-owned DOM.

**Drag-to-place** is progressive enhancement via the module's own
**`DashboardGridDrag`** hook (core's SortableJS-based `SortableGrid` is 1D reorder —
it can't do 2D cell placement): the grid container sets
`phx-hook="DashboardGridDrag"` + `data-cols`, each card is a
`.sortable-item[data-id]` carrying `data-x/-y/-w/-h`, dragged by its
`.pk-drag-handle` — the widget's WHOLE top bar (buttons inside it are excluded
by the hook, so settings/remove still click; the grip icon is just the
affordance). A floating clone follows the cursor while the widget itself
jumps cell-to-cell under it as the live preview — the target cell comes from the
clone's top-left against the grid metrics (data-cols + computed gaps/auto-rows +
the fit scale), and the preview only ever moves through FREE cells (occupancy from
the other cards' data attrs), so the shown spot is always legal and **the drop
always matches the preview**. On drop it pushes `move_widget_grid %{id, x, y}`
(0-based cells; `Dashboards.place_widget_grid/5` clamps + collision-rejects
server-side). Tier detection: hosts SHOULD pass `viewport_width` in the
LiveSocket connect params (README) so the builder mounts straight into the
right tier (`Breakpoints.for_width/1`, `screen_known?`); without it the
`DashboardBreakpoint` hook round-trip detects it behind a loading state, with
a 4s reveal-at-default fallback for broken assets (no-JS reveals instantly via
`<noscript>`). **Catalog drag-out** (`DashboardCatalogDrag` on `#dashboard-catalog`,
entries carry `data-widget-key/-w/-h`): drag an entry past a ~6px threshold and a
ghost + a free-cells-only dashed footprint follow the pointer; dropping pushes
`add_widget_at %{key, x, y}` (grid) or `add_widget_px %{key, fx, fy}` (pixel
canvas) — a plain click still adds at the first free spot, and a completed drag
swallows its trailing click. **Resize** is a bottom-right corner grip (`.pk-resize-handle`) driven
by the per-card `DashboardResize` hook — pixel-smooth while dragging, and on
release it **branches on the card's `data-free` flag**: grid mode snaps to the
nearest whole cell that FITS (grid edge + neighbours, mirroring `Grid.fit_size/8`)
keeping the x/y anchor → `resize_widget_to %{id, w, h}`; free mode keeps the exact
px → `resize_widget_to %{id, fw, fh}` (clamped to `[60, 4000]`). No-JS fallbacks:
the Settings modal's Width/Height + Column/Row inputs (grid) and Width/Height +
X/Y px inputs (pixel). All placement drags **edge auto-scroll** the pane (a shared
rAF scroller; FreeDrag folds the pane-scroll delta into its drag deltas).

The module hooks ship via `js_sources/0` (`priv/static/assets/phoenix_kit_dashboards.js`):
`DashboardGridDrag` (above), `DashboardFreeDrag` (free canvas — drag a
`.pk-free-handle` grip, moves the card via `left/top` and pushes
`move_widget_to %{id, fx, fy}` in exact px), `DashboardResize` (corner resize, both
modes; see above), plus the fit/fullscreen/tier helpers (`DashboardGridFit`,
`DashboardFreeFit`, `DashboardFullscreen`, `DashboardBreakpoint`). All are
enhancement only — the non-hook fallbacks are the server-driven modal inputs.
The drag/resize hooks leave the card exactly where dropped and update the
style in the server's format, so the re-render confirms identically with **no
rubber-band / no snap**; they guard concurrent pointers + handle `pointercancel`,
and only the primary button starts a gesture. An earlier scaffold loaded gridstack
from a CDN via an inline `<script>`; that was removed (it broke on LiveView
navigation). Do not reintroduce inline-`<script>` hooks — ship any hook via
`js_sources/0`.

## Dashboard type (fixed at creation) & the layout model

A dashboard's **type is chosen at creation** (`config["type"]` = `"grid"` | `"pixel"`)
and is fixed — there is no runtime toggle (`Dashboard.type/1`; legacy `config["mode"]`
`"free"`→`"pixel"` still maps; `Dashboard.layout_mode/1` derives `"free"`/`"grid"` from
type for the builder's internal render switch).

**Geometry is embedded per widget** (`PhoenixKitDashboards.Layout`) so add/remove is
atomic — a widget item is `%{id, widget_key, settings, view, "pixel" => %{fx,fy,fw,fh},
"bp" => %{<bp> => %{x,y,w,h,hidden,pos}}}`. `Layout.pixel/1` + `placement/2` default
and fall back to the legacy flat shape (`pos` is the legacy-order tiebreaker; items
without stored `x`/`y` are packed at render and pinned on their first edit).

- **`"grid"` — responsive breakpoints with EXPLICIT CELL PLACEMENT.** Tiers
  (`PhoenixKitDashboards.Breakpoints`, largest→smallest): **TV ≥1920 = 16 cols,
  Desktop ≥1280 = 12, iPad ≥768 = 8, Phone <768 = 4**, each with a `preview_width`.
  A placement is `%{x, y, w, h, hidden}` — `x`/`y` are 0-based cells; a widget goes
  ANYWHERE (gaps allowed, that's the point), widgets never overlap
  (`PhoenixKitDashboards.Grid` owns the occupancy/packing/fit math). Each tier has
  its own **designable surface** (`Breakpoints.max_rows/1`: TV 8, desktop 15,
  iPad 24, phone 36 — the builder renders + scrolls ALL of it so a widget can be
  placed on any row up front; `Grid.max_rows/0` = 50 is only the hard bound that
  derived-tier packing may overflow into, and overflowing content still renders).
  Each breakpoint has its own layout: edits
  (move/resize/hide) act on the **active** breakpoint and flip it to customized —
  `materialize_grid` first pins every widget's resolved cells so editing one can't
  shift the rest (and `save_customized` must FORCE the layout write: the struct was
  pre-mutated in memory, so a plain Ecto `change/2` would diff against it and
  silently skip persisting when the edit equals the derived values). Placements
  that predate explicit cells (order-only `pos` data) pack first-fit around the
  placed ones at render, no migration. An un-customized breakpoint is
  **auto-derived** from the nearest customized one **in either direction** by
  **reflow + compact** (its widgets in reading order, spans clamped to the target
  columns, packed first-fit). A dashboard has a **home tier** (`home_bp/1` =
  `config["home_bp"]`, set from the creator's screen on first open via
  `put_home_bp/2`; defaults desktop). The home tier is always a **designed** view
  (`customized?/2` = state custom **or** the home) and is the seed (`add_widget`
  seeds `bp[home]` at the first free cell) + derivation anchor; it can't be reset.
  `Dashboards.resolve_items/3` is the single render path — every placement it
  returns carries explicit cells (`visible: true` filters hidden; hidden widgets
  keep occupying their cells).

  **Always fit-scaled + editable.** The grid is laid out at its tier's design width
  and scaled to the available space by **`DashboardGridFit`** (shrink-to-fit for a
  DIFFERENT tier's preview; **fills** — scaling past 1:1 — on the viewer's NATIVE
  tier, `data-fill`, and in fullscreen). It's
  **editable at any scale**: corner-resize via the scale-aware `DashboardResize`;
  cell placement by dragging via the module's `DashboardGridDrag` (screen-space
  metrics, so it's transform-aware at any scale) or the Settings modal's
  Column/Row inputs. So an employee on a phone can fix the *TV* layout: tap
  TV, and edit it shrunk-to-fit. **On open** (the
  **`DashboardBreakpoint`** hook reports the screen tier once, `detect_bp`) we only
  ever show a *designed* view (`display_bp/2` = the screen tier if designed, else the
  nearest designed one) — never a freshly-derived one; hosts passing
  `viewport_width` in the LiveSocket connect params (README) skip the hook
  round-trip entirely and mount straight into the right tier. `scaled?` (view ≠
  the viewer's own size) drives the banner. The **catalog** is a slide-over panel
  in BOTH modes: always rendered but hidden, toggled client-side (`JS.toggle`, so
  opening is instant), entries grouped by providing module, and it hides itself
  while a catalog drag is off-panel so cells under it can take the drop
  (releasing over the visible panel cancels). The **full-screen** button lives in
  the title row for both modes (`DashboardFullscreen` → requests fullscreen on
  the fit container; a `fullscreenchange` re-fits to fill). The whole grid pane
  is held hidden (a spinner + "fitting…" text; `<noscript>` reveal) until the
  tier resolves, so the switcher never animates desktop→tv.
- **`"pixel"` — an absolute pixel canvas**: drag/resize anywhere, exact px in
  `pixel.fx/fy/fw/fh`, no snapping. Widgets may **overlap deliberately** — each
  widget bar has bring-to-front / send-to-back (`restack_widget_px/3`, a `"z"`
  key in the pixel map that survives moves since `put_pixel` merges). No Layout
  bar and no zoom control (pixel has no tiers; fit-to-width handles scale). The
  **`DashboardFreeFit`** hook scales the canvas via `transform: scale` to **fill
  the container width** AND grows its height to at least the pane's (edge-to-edge,
  no gap around the canvas; a loading spinner covers the pane until the fit
  reveals it) — re-fit by a `ResizeObserver` (`scrollbar-gutter: stable` prevents
  a feedback loop); a `.pk-free-spacer` gives the scroll extent. `transform:
  scale` (not CSS `zoom`) so the drag/resize hooks' `rect.width/offsetWidth`
  reads the exact scale. Move = `DashboardFreeDrag` (`left/top`, pane-scroll
  compensated); resize = the corner grip in px.

Both types render + are operable without JS (grid: Settings modal size +
Column/Row inputs; pixel: modal size + X/Y px inputs).
- **Widget views + size**: a widget type may declare `views: [%{key:, name:}]`
  render variants (detailed / compact / color grid…); the instance stores the
  selected `"view"`, and the host passes both `view` and `size` (`%{w:, h:}`) to
  the widget `LiveComponent` so one widget renders several densities and
  auto-degrades when small. Reference: `Widgets.ModuleStatsWidget`; the real
  consumer is `phoenix_kit_projects`' five widgets.
- **Live refresh**: a widget type may declare `refresh_interval` (ms); the host
  (`BuilderLive`) runs a single `:refresh_tick` loop and `send_update/2`s each due
  widget so it re-queries. `Widgets.ClockWidget` (1 s) and the projects widgets
  (15–30 s) use it. Widgets never subscribe themselves (LiveComponents have no
  process); the host drives refresh.
- **Scopes + sharing**: dashboards are `personal` / `system` (shared) / `role`.
  **Role-scope creation is HIDDEN in the UI for now** (boss call 2026-07-14 —
  it was briefly offered in the old create modal): the form page authors
  personal/system only; the backend keeps full role support (`list_for_user/2`
  role visibility, handler path), and an already-role-scoped dashboard is
  grandfathered on its edit page (role picker from core `Roles.list_roles/0`)
  so a save can't silently convert it. The manage page **clones** any visible
  dashboard into a private copy, and
  gates delete/visibility via `can_view?`/`can_delete?`; `list_for_user/2` takes
  the user's role uuids so role dashboards surface for their members.

## Tailwind CSS

UI templates are scanned via `css_sources/0` (`[:phoenix_kit_dashboards]`). Core's
`:phoenix_kit_css_sources` compiler wires the host's Tailwind `@source` at compile
time — zero-config after `mix phoenix_kit.install`.

## Routing

Single-page pattern: the list page and the hidden per-dashboard builder are both
declared as `admin_tabs/0` entries with `live_view:` set (the builder is
`visible: false` with a `:uuid` dynamic segment spliced into the generated route).
This matches `phoenix_kit_locations` / `phoenix_kit_catalogue`. Do **not** add a
`route_module/0` — that's only needed for locale-prefixed route variants.

## Database & Migrations

This module owns no DDL. The backing `phoenix_kit_dashboards` table (personal /
system / role scopes, JSONB `layout`, `owner_user_uuid` FK → `phoenix_kit_users`
`ON DELETE CASCADE`) ships as core migration **V133** (first released in core
`1.7.145`).

The per-dashboard JSONB **`config`** column (type + home tier + customized set) ships as core
migration **V139**, released in core **`1.7.179`**. The config-dependent features
(type, home tier, customized tiers) need that column, so the `mix.exs` core pin
floor is `~> 1.7.179` — a core older than that would resolve an older pin yet lack
the column the layout engine reads. Cross-repo work can still run against
**local core** (`PHOENIX_KIT_PATH=../phoenix_kit`), where `ensure_current` builds
the migration; standalone `mix test` needs a core `>= 1.7.179` for the
config-dependent integration tests (no GitHub Actions CI here).

## Testing

Two levels: **unit** (no DB — `test/phoenix_kit_dashboards_test.exs`) and
**integration** (`:integration` tag via `DataCase` / `LiveCase`, real PostgreSQL).

```bash
createdb phoenix_kit_dashboards_test          # first time (or: mix test.setup)
PHOENIX_KIT_PATH=../phoenix_kit mix test      # vs local core (see below)
```

Without PostgreSQL, integration tests auto-exclude and unit tests still run.
`test/test_helper.exs` builds the schema via
`PhoenixKit.Migration.ensure_current/2` (no module-owned DDL) and starts the test
Endpoint. Support harness in `test/support/`: `Test.Repo`, `Test.Endpoint`,
`Test.Router` (scoped `/en/admin/dashboards`), `Test.Layouts`, `Test.Hooks`
(`:assign_scope` on_mount — its `nil` branch still assigns `phoenix_kit_current_scope`
because `BuilderLive` reads it strictly), `DataCase`, `LiveCase` (`fake_scope/1` +
`put_test_scope/2` + `fixture_dashboard/2`), `Fixtures` (`user_fixture/1` — a real
`phoenix_kit_users` row is required for the owner FK), `ActivityLogAssertions`.

## Local cross-repo development

The core pin resolves from Hex by default. Export `PHOENIX_KIT_PATH=../phoenix_kit`
(the `pk_dep/3` helper in `mix.exs`) to build against a local core checkout — unset
= the published pin, so `mix hex.publish` is unaffected. Never commit a hand-edited
`path:` tuple.

## Commands

```bash
mix deps.get
mix test                 # unit tests; :integration excluded without a DB
mix format
mix credo --strict
mix precommit            # compile (warnings-as-errors) + checks
```

## Versioning & Releases (boss-only)

Releases are cut by the maintainer — agents stop at the PR at the current version.
Do **not** bump `@version`, edit `CHANGELOG.md`, tag, or `mix hex.publish`. Version
locations (bumped together at release time): `mix.exs` `@version`,
`lib/phoenix_kit_dashboards.ex` `version/0`,
`test/phoenix_kit_dashboards_test.exs` assertion. Tags are bare version numbers
(`0.1.0`, no `v` prefix).

## Pull Requests

Branch `main`; PR `main → main`. Commit messages start with `Add`, `Update`,
`Fix`, `Remove`, `Merge` — **no AI attribution footers**. There is no GitHub
Actions CI on this repo: test state is whatever local `mix test` reports (run
against local core via `PHOENIX_KIT_PATH`).

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` — a
`README.md` (PR summary) plus a per-reviewer `{AGENT}_REVIEW.md` (e.g.
`CLAUDE_REVIEW.md`; never append to another agent's file). See
`dev_docs/pull_requests/README.md` + `TEMPLATE.md`. Severity taxonomy:
`BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

### Dashboard presets

Offer one-click **presets** when creating (or on an empty) dashboard: the user
picks e.g. "Overview" and gets a ready-made set of widgets already placed and
configured (an overview preset ≈ projects board + workload + deadlines; a
personal preset ≈ my-tasks + only-my-projects deadlines + a clock). Likely
shape: a preset is data — a named list of `{widget_key, view, settings, size}`
entries laid out by the same first-free packing as `add_widget/3` — and
modules could contribute presets the same duck-typed way they contribute
widgets. Idea noted 2026-07-08; not designed yet.

