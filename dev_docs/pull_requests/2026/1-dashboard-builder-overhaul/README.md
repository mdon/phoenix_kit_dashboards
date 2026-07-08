# PR #1: Dashboard builder overhaul

**Author**: @mdon
**Reviewer**: @ddon (Claude)
**Status**: Merged
**Commit**: `ab2f9d6` (merge) + post-merge `32a6343`, `4d5b0a5`
**Date**: 2026-07-08

## Goal

Turn the initial gridstack-style scaffold into a full, Phoenix-first dashboard
builder: explicit per-breakpoint **cell placement** (responsive grid tiers),
a second **pixel-canvas** dashboard type, a richer widget provider contract
(view variants + size-awareness + live `refresh_interval`), and a complete
DB/LiveView test harness. Type is chosen at creation and fixed; layouts persist
per user/system/role.

## What Was Changed

41 files, +8222/−489 — a near-total rewrite. Highlights:

| File | Change |
|------|--------|
| `lib/phoenix_kit_dashboards/breakpoints.ex` | New — responsive tiers (TV 16 / Desktop 12 / iPad 8 / Phone 4), per-tier designable rows |
| `lib/phoenix_kit_dashboards/grid.ex` | New — pure cell math: `collides?/5`, `first_free/4`, `compact/2`, `fit_size/8` |
| `lib/phoenix_kit_dashboards/layout.ex` | New — embedded per-widget geometry (pixel + per-breakpoint), legacy flat-shape fallback |
| `lib/phoenix_kit_dashboards/dashboards.ex` | Context: per-breakpoint edits, `resolve_items/3` single render path, `materialize_grid`, forced `save_customized` write |
| `lib/phoenix_kit_dashboards/web/builder_live.ex` | Server-rendered grid + pixel modes, drag/resize handlers, host-driven `:refresh_tick` loop |
| `lib/phoenix_kit_dashboards/widget.ex` | Provider contract normalization (`from_map/2`), per-view `min_size`, sanitized size bounds |
| `priv/static/assets/phoenix_kit_dashboards.js` | New — module drag/resize/fit/detect hooks (progressive enhancement) |
| `test/**` | New DB (`DataCase`) + LiveView (`LiveCase`) harness; unit + integration levels |

### Schema Changes

The per-dashboard JSONB **`config`** column (type + home tier + customized set)
is created by **core** migration **V139** (this module owns no DDL). The `layout`
JSONB list holds embedded-geometry widget instances.

## Implementation Details

- **Single render path** (`resolve_items/3`): a designed breakpoint renders its
  stored cells; an undesigned one is derived (reflow + compact) from the nearest
  designed tier. Preview and runtime never diverge.
- **Forced layout write** in `save_customized/3`: `materialize_grid/2` pre-mutates
  the struct in memory, so a plain `change/2` would diff-skip a write equal to the
  derived values — `force_change/3` guarantees persistence.
- **Host-driven refresh**: LiveComponents have no process, so `BuilderLive` runs a
  single `:refresh_tick` loop and `send_update/2`s each due, visible widget.

## Testing

- [x] Unit tests (no DB): 63 passing
- [x] Integration tests (`:integration`): require PostgreSQL + core ≥ 1.7.179
- [x] Gate green: format, `compile --warnings-as-errors`, `credo --strict`, dialyzer
- [ ] Migration tested on staging (core-owned; V139)

## Related

- Review: [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md)
- Release: `phoenix_kit_dashboards 0.1.0` (Hex), pin bumped to `phoenix_kit ~> 1.7.179`
