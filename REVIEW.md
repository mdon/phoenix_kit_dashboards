# Review — PR #1: Dashboard builder overhaul

**PR:** [BeamLabEU/phoenix_kit_dashboards#1](https://github.com/BeamLabEU/phoenix_kit_dashboards/pull/1) —
"Dashboard builder overhaul: explicit cell placement, pixel parity, widget API, quality sweep"
**Author:** mdon · **Merge:** `ab2f9d6` · **Reviewer:** Claude (Opus 4.8)
**Scope:** 41 files, +8222/−489 — a near-total rewrite of the builder plus the
grid/pixel layout engine, widget contract, and a full test harness.

## Verdict

**High quality — accept.** The layout engine (breakpoints → grid math → embedded
per-widget geometry → single `resolve_items/3` render path) is coherent and the
tricky invariants are handled correctly and *with comments explaining why*:

- `save_customized/3` **force-writes** the layout because `materialize_grid/2`
  pre-mutates the struct in memory, so a plain `change/2` would diff-skip a write
  that equals the derived values (`dashboards.ex:884`). This is exactly the trap
  AGENTS.md flags; it's done right.
- The `:refresh_tick` loop uses `System.monotonic_time/1` and defaults an unseen
  widget's next-refresh to `now`, **not** `0` — monotonic time is large-negative
  on the BEAM, so a `0` default would make the due-check never fire
  (`builder_live.ex:482`). Correctly reasoned.
- `configure_widget/4` coerces a non-map `settings` to `%{}` so a crafted scalar
  can't brick a widget's `update/2` on every render (`dashboards.ex:779`).
- No DB work in `mount/3`; the dashboard loads in `handle_params/3`. Every layout
  handler degrades to a no-op on `{:error, _}` instead of a `MatchError` crash.
- `Registry.has_access?/2` fails **closed**; discovery rescues per-provider.
- The `derive_tier` ↔ `derivation_source` recursion terminates (the source is
  always a *customized* tier → `resolve_designed`, never re-derives).

**Cross-boundary sync checks (both clean):**
- All 8 `phx-hook` names in HEEx exist in `priv/static/assets/phoenix_kit_dashboards.js`.
- Every JS `pushEvent` (`move_widget_to/_grid`, `add_widget_at/_px`,
  `resize_widget_to`, `detect_bp`) has a matching `handle_event` with matching keys.

## Gate

Run against local core (`PHOENIX_KIT_PATH=../phoenix_kit`), Elixir 1.19.5 / OTP 28:

| Step | Result |
|---|---|
| `mix format --check-formatted` | ✅ |
| `mix compile --force --warnings-as-errors` | ✅ zero warnings |
| `mix credo --strict` | ✅ 395 mods/funs, no issues |
| `mix test` (unit) | ✅ 63 tests, 0 failures |
| `mix test` (integration) | ⏭️ 104 excluded — no local PostgreSQL (expected; config-dependent tests need core V139, still unreleased — see AGENTS.md) |
| `mix dialyzer` | ✅ Total errors: 0 — passed successfully |

## Findings

Nothing rises to a correctness bug that fires in a real code path. Two
documentation inaccuracies fixed; the rest are recorded observations left as-is
with the reasoning.

### NITPICK (fixed) — stale/incorrect docs

1. **`web/builder_live.ex` moduledoc** said "two layout modes (per-dashboard
   `config["mode"]`)". The model changed: a dashboard's **type** is fixed at
   creation in `config["type"]` (`"grid"`|`"pixel"`) and the render mode is
   derived via `Dashboard.layout_mode/1`; `config["mode"]` is only a legacy
   fallback. **Fixed** to describe the type-at-creation model.
2. **`grid.ex` moduledoc** referenced `fit_size/7`; the function is `fit_size/8`
   (and AGENTS.md already calls it `/8`). **Fixed.**

### CLEANLINESS (documented, not changed) — `set_layout_mode/2` is a legacy no-op

`Dashboards.set_layout_mode/2` (+ `Dashboard.layout_modes/0`, `@layout_modes`)
writes `config["mode"]`. Since `type/1` prefers `config["type"]` and every
dashboard is now created with it, the written `"mode"` is **never consulted** in
production — no LiveView calls `set_layout_mode/2`. It survives only via the
legacy `config["mode"]` mapping and two tests (`dashboards_test.exs:138,512`) that
use it to build a pixel dashboard through the legacy path.

**Not removed:** it is public, tested, and harmless; deleting tested API during a
review is over-reach. Flag for the maintainer to retire alongside the legacy
`config["mode"]` mapping in a future cleanup.

### LOW / edge case (documented, not changed) — `Grid.fit_size/8` at the right edge

When `cols - x < min_w`, `req_w` clamps below `min_w`, so `largest_fitting/3`
walks an **empty** descending range and returns the `min_w` floor **without a
fit check** (`grid.ex:145`). At the grid's right edge with no right-hand
neighbour, `resize_instance/6`'s `collides?` safety net (`dashboards.ex:501`)
passes (it checks only other widgets, not the grid edge), so the widget can end
up spanning **one column past the grid edge** (cosmetic overflow, not a crash).

Reachability is marginal: it needs a `min_override` widget parked in the last
column, then resized *after* its floor is raised again — normal placement clamps
`x ≤ cols − w`, so a `min_w ≥ 2` widget can't otherwise sit at `x = cols − 1`.

**Not fixed:** the neighbour case (the common one) is already covered, the result
is cosmetic, and hardening the core fit math for this corner risks a regression
without a test to pin it. If addressed later, the cheapest fix is an extra
`x + w2 <= cols` guard in `resize_instance/6`'s safety branch.

### INFO — no action

- **`DashboardsLive.mount/3` runs `list_for_user/2` (a DB query) in mount.** It
  has no `handle_params`, so mount is the only load point; the query therefore
  runs on both the static and the connected render (one redundant query on first
  paint). Standard for a no-`handle_params` list page — guarding with
  `connected?/1` would blank the first paint. Acceptable.
- **`Jason.encode!` for `bp_thresholds/0`** (`builder_live.ex`) rather than the
  built-in `JSON` (Elixir 1.18+, which this project requires). Works — Jason is
  reliably present via Phoenix — but `JSON.encode!` would drop the reliance on a
  transitive dep. Optional.

## What I verified but found correct

- View-switch growth vs. the settings-modal resize: `resize_widget/5` re-clamps to
  the *new* view's `min_size` (`Grid.fit_size` floors at it), so the modal's
  pre-change `w/h` can't silently undo a `grow_for_view` growth.
- Refresh `send_update/2` only targets widgets whose `visible_for_scope?` is true —
  the same gate `widget_body/1` uses to mount the component, so no update ever
  targets an unmounted placeholder. Hidden-on-tier widgets still render (dimmed),
  so they remain valid `send_update` targets.
- `add_widget_at/6` materializes before collision-checking; `new_instance/2`'s
  home-tier seed is correctly computed against the (separately-resolved) home tier.
- `Widget.from_map/2` never `String.to_atom`s provider input (all `to_string`),
  validates the component is a loaded `Phoenix.LiveComponent`, and sanitizes sizes
  so a malformed provider can't desync the client resize limits from the server clamp.
