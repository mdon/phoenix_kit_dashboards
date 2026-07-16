# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-07-16

### Added

- **Screenful lattice grid model**: replaces fixed device-tier breakpoints
  (TV/Desktop/iPad/Phone) with user-defined named layouts, each a `cols × rows`
  grid on a gapless 25px square-cell lattice representing exactly one
  screenful — nothing scrolls. Layouts are managed as a tab strip
  (add/rename/delete/duplicate) with numeric dimension inputs and a
  "Fit screen" button.
- **Fully live dashboards**: every mutation broadcasts over a per-dashboard
  PubSub topic, so any open session (e.g. a wall-mounted display) re-renders
  instantly on a concurrent edit and navigates away on delete.
- **Optimistic concurrency**: a monotonic `config["rev"]` compare-and-swap
  (no schema migration) refuses stale writes instead of silently clobbering a
  concurrent edit; the builder re-syncs automatically.
- **Display mode**: fullscreen now hides all edit chrome and auto-hides the
  cursor after idle; the refresh loop pauses while the tab is hidden so a
  backgrounded display doesn't fast-forward its clocks on return.
- **Host-app widgets**: any host application can contribute widgets via
  `config :phoenix_kit_dashboards, widget_providers: [...]`, using the same
  `phoenix_kit_widgets/0` contract as a PhoenixKit module.
- **Per-layout widget views**: a widget's render variant (detailed/compact/…)
  is chosen per layout and honored verbatim at any size via container-query
  self-fit sizing.
- Dedicated create/edit page (`DashboardFormLive`) replacing the old create
  modal.

### Changed

- Pixel-canvas dashboards brought up to the lattice-era polish (native fit,
  fill-to-container scaling, restack z-order).
- Manage page trimmed to list/create/clone/delete now that metadata editing
  lives on its own page.

### Fixed

- Hardened the module against a multi-AI security/quality review: re-authorize
  every builder event and form save, scope-gate add-widget paths, validate
  settings/view input to prevent bricking, bound pixel coordinates, gate
  module-stats on module access, and isolate provider discovery from crashes.
- `Grid.first_free/4` ignored a layout's actual row count (scanned to a
  hardcoded 160-row cap), letting a new widget seed below the visible
  screenful on a full small layout instead of triggering the documented
  below-the-fold fallback.
- `DashboardsLive` had no catch-all `handle_event`, unlike its sibling
  LiveViews — an unrecognized event crashed the process.
- `DashboardFormLive` treated a concurrent-edit `{:error, :stale}` as a
  generic save failure instead of resyncing.
- The `DashboardVisibility` JS hook didn't sync the refresh-pause state for a
  dashboard that mounts already in a background tab.

## [0.1.0] - 2026-06-12

### Added

- Initial scaffold of the Dashboards module.
- `PhoenixKit.Module` integration: auto-discovery, admin tab, permission,
  enable/disable.
- Backing `phoenix_kit_dashboards` table added as core PhoenixKit migration V133
  (modules do no DDL of their own).
- Widget provider contract — any module exposes widgets via a plain-map
  `phoenix_kit_widgets/0` (`PhoenixKitDashboards.Widget`).
- `PhoenixKitDashboards.Registry` — runtime discovery and a cached widget
  catalog (built-ins ∪ providers), filtered by module enablement and permissions.
- Built-in widgets: Note, Clock, Module stats.
- `phoenix_kit_dashboards` table + schema + context, with personal and
  system/shared dashboard scopes and a JSONB `layout` of widget instances.
- Manage page (`DashboardsLive`) and a gridstack-style 2D grid builder
  (`BuilderLive`) with add/remove, drag/resize persistence, and a
  schema-generated per-widget settings form.
