# Code Review — phoenix_kit_dashboards (general library pass)

**Date**: 2026-07-16
**Scope**: Whole library at `7bf668a` (post-0.2.0), incl. recent PR #3 (screenful lattice + live sync) and the two hardening sweeps (`e4b99a1`, `9c8249b`).
**Method**: Two read-only exploration passes + manual verification of every bug-class claim against the source. `mix credo --strict` and `mix test` run locally.

Severity taxonomy (project convention): `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## Health summary

- `mix credo --strict`: **clean** — 448 mods/funs, 0 issues.
- `mix test`: **71 unit tests, 0 failures** (141 integration tests excluded — no PostgreSQL in this environment).
- The recent hardening commits already closed most event-reachable crash paths (malformed UUIDs, hostile view params, stale-write resync, PubSub-down guards). All JS hooks have `destroyed()` cleanup; observers are disconnected; the registry fails closed on permissions.
- What remains is mostly **refactor debris from the tiers→layouts rework** (naming, duplication, dead code) plus a small number of real bugs.

## Findings

| # | Severity | Finding |
|---|----------|---------|
| 1 | BUG-HIGH | Catalog drag-out likely broken on touch (implicit pointer capture) |
| 2 | BUG-MEDIUM | Pixel canvas can be ballooned to 20000px via drag/crafted event |
| 3 | BUG-MEDIUM (docs) | ClockWidget moduledoc + AGENTS.md state pre-lattice min sizes |
| 4 | IMPROVEMENT-HIGH | `builder_live.ex` is 2036 lines doing five jobs — extract components |
| 5 | IMPROVEMENT-HIGH | Context↔LiveView duplicated logic (size bounds, clamps, coercion) is a drift trap |
| 6 | IMPROVEMENT-HIGH | Registry `:persistent_term` cache never invalidated |
| 7 | IMPROVEMENT-HIGH (test) | Zero JS coverage, incl. the client/server `fitCells` ↔ `Grid.fit_size/8` mirror |
| 8 | IMPROVEMENT-MEDIUM | Stored JSONB mixed-type numerics can still crash grid math |
| 9 | IMPROVEMENT-MEDIUM | Dead/unwired public API: `get_or_create_default`, `hide_widget`, `update_widget_settings` |
| 10 | IMPROVEMENT-MEDIUM | Same permission rule copy-pasted 3× under 3 names |
| 11 | IMPROVEMENT-MEDIUM | Refactor-vocabulary debt: `bp`, "tier", "free"/"pixel" |
| 12 | IMPROVEMENT-MEDIUM | `dashboards.ex` (1423 lines) mixes context CRUD with layout CRUD + resolution |
| 13 | IMPROVEMENT-MEDIUM | JS hooks: ~150 lines of copy-pasted collision/pointer/metrics logic |
| 14 | IMPROVEMENT-MEDIUM (test) | Elixir coverage gaps: Lattice, Web.Helpers, concurrency, delete CAS |
| 15 | NITPICK | Misc small items (see list) |

---

### 1. BUG-HIGH — Catalog drag-out likely broken on touch devices

`priv/static/assets/phoenix_kit_dashboards.js:960` — `track()` computes
`overCatalog` via `ev.target.closest("#dashboard-catalog")`. Touch pointers get
**implicit pointer capture** on the `pointerdown` target, so for the whole
gesture `ev.target` remains the catalog entry → `overCatalog` is always true →
every drop cancels. Catalog drag-out is unusable on phones/tablets (plain
click-to-add still works).

**Fix**: use rect math like the panel-hide check right above it
(`js:854-866`), or call `releasePointerCapture`. Not reproduced on real
hardware — verify on a touch device before/after.

### 2. BUG-MEDIUM — Pixel canvas can be ballooned to 20000px

Client `DashboardFreeDrag` clamps only `>= 0` (`js:156-157`); the server clamp
is `0..@free_max_pos` (20000) in `place_widget_px` (`dashboards.ex:897-904`),
and the builder grows the canvas to contain widgets
(`builder_live.ex:1644-1649`). A crafted `move_widget_to` — or a determined
editor — can place a widget at ~20000px, forcing a gigantic canvas/spacer for
**all viewers** of a shared dashboard.

**Fix**: clamp server-side to the current canvas extent + one screen, or cap
canvas growth.

### 3. BUG-MEDIUM (docs) — ClockWidget min-size docs are pre-lattice

`clock_widget.ex:11` moduledoc: "the analog face needs a squarer box (2×2)
than a line of digits (3×1)" — the catalog actually declares normal 8×4,
digital 12×4, analog **8×8** (`widgets.ex:77-80`). `AGENTS.md` repeats the
stale "analog floors at 2×2". Also a "per tier" relic comment at
`clock_widget.ex:158` (tiers are gone).

**Fix**: update both docs to the lattice numbers.

### 4. IMPROVEMENT-HIGH — Split `builder_live.ex` (2036 lines)

The file does five jobs: mount/auth (75-123), event dispatch (~25 handlers,
204-509), refresh loop + live sync (603-774), helpers (776-894), and
**rendering — 56% of the file (896-2036)**. Natural seams, in payoff order:

1. Presentational function components → `BuilderLive.Components`
   (`grid`, `layout_bar`, `grid_mode`, `free_mode`, `widget_card`,
   `widget_body`, `catalog_drawer` + private style helpers) — ~900 lines,
   zero behavior risk.
2. Settings modal → own component incl. the save pipeline
   (`settings_modal` 1821-1991, `settings_field` 1999-2035,
   `save_settings` 539-594) — ~350 lines, one coherent feature.
3. Refresh loop → plain module (611-774, already self-contained).

Result: a ~700-line LiveView. Mechanical refactor, covered by existing LV
tests. Also fixes the over-long functions: `settings_modal` ~170 lines
(incl. two near-mirror size/position input blocks 1870-1941), `layout_bar`
~160, `widget_card` ~128.

### 5. IMPROVEMENT-HIGH — Context↔LiveView duplicated logic (drift trap)

The comments admit "mirrors the context" — they will drift:

- `size_bounds`/`instance_min` verbatim, incl. the identical unknown-widget
  fallback: `dashboards.ex:1366-1374` ≡ `builder_live.ex:1583-1592`.
- `@free_min_px`/`@free_max_px`: `dashboards.ex:25-26` ≡ `builder_live.ex:71-72`.
- `clamp/3` exists 3× with **different semantics** (`dashboards.ex:1376`
  integer-guarded; `builder_live.ex:1666` and `widget.ex:324` unguarded).
- Int coercion: `int/2` (`dashboards.ex:1381-1383`) truncates floats;
  `to_int/2` (`builder_live.ex:1651-1652`) accepts integers only — a float
  `fh` from legacy JSONB silently renders as the default.

**Fix**: consolidate into `Widget` (size bounds, next to `min_size_for/2`)
and `Lattice` (px constants, one `clamp`, one coercion); delete the twins.

### 6. IMPROVEMENT-HIGH — Registry cache is never invalidated

`registry.ex:29-30` moduledoc says "call `refresh/0` after modules are
toggled" — **nothing in lib/ calls it**. Impact is bounded (enablement is
re-checked live per call via `visible_for_scope?`, `registry.ex:87-89`), but
changed `views`/`settings_schema`/`refresh_interval`, new providers, and
computed options (`ClockWidget.timezone_options` `widgets.ex:88`,
`ModuleStatsWidget.module_options` `widgets.ex:118-123`) go stale until
BEAM restart.

**Fix**: hook core's module enable/disable to call `Registry.refresh/0`, or
document the host obligation in the moduledoc/README.

### 7. IMPROVEMENT-HIGH (test) — Zero JS test coverage

No package.json/runner. The safety-critical pair is client `fitCells`
(`js:268-279`) mirroring server `Grid.fit_size/8` (`grid.ex:138-151`): if
these drift, drops stop matching previews (the core invariant of the grid).
The pure geometry functions (collision, fit, metrics) are Node-testable
without a browser.

**Fix**: a minimal Node test for the extracted pure functions (pairs well
with #13's dedup).

### 8. IMPROVEMENT-MEDIUM — Mixed-type stored numerics can crash grid math

Same tampered/legacy-JSONB class as PR#3-sweep finding #8 (fixed on the
pixel/render path only). `Layout.placement/2` merges stored values verbatim
(`layout.ex:40-43`). `Grid.collides?` guards `x`/`y` but not `w`/`h`
(`grid.ex:42-44`: `ow = p["w"] || 1` then `ox + ow`); `below_all` guards `y`
not `h` (`grid.ex:83`); `occupied_extent` does raw `p["x"] + (p["w"] || 1)`
(`dashboards.ex:840-841`). A placement with integer x/y but string w/h raises
`ArithmeticError` in `place_widget_grid`/`set_grid_dims`. Not event-reachable
(every event write coerces) — defense in depth.

**Fix**: coerce numerics centrally in `Layout.placement/2` (single choke
point) or in `Grid` entry points.

### 9. IMPROVEMENT-MEDIUM — Dead / unwired public API

Zero callers in lib/ (tests only):

- `get_or_create_default/1` — also hard-matches `{:ok, dashboard} = create(...)`
  (`dashboards.ex:100`), so a transient DB error raises `MatchError`.
- `hide_widget/4` + `resolve_hidden?/3` + the `visible:` option of
  `resolve_items/3` — the builder *renders* `hidden` state but no event can
  set it (PR#3 review already noted "awaiting a UI toggle").
- `update_widget_settings/4` — 1-line wrapper over `configure_widget/4`.

**Fix**: decide per function — wire the UI toggle, document as intended
public API in the moduledoc, or remove.

### 10. IMPROVEMENT-MEDIUM — Same permission rule 3× under 3 names

`can_delete?/2` (`dashboards_live.ex:108-111`) ≡ `can_manage?/2`
(`dashboard_form_live.ex:171-174`) ≡ `deletable?/2` (`dashboards_live.ex:114-115`);
`can_view?/2` duplicated too (`builder_live.ex:888-890` ≡
`dashboards_live.ex:102-104`). The Edit menu item is gated by `deletable?`
(`dashboards_live.ex:199`) — same behavior today, wrong intent. Also the 5
near-identical flash+redirect blocks in `builder_live.ex`.

**Fix**: one `manageable_by?/2` + `viewable_by?/2` in `Web.Helpers`; extract
`not_found/1` / `deny/1` helpers.

### 11. IMPROVEMENT-MEDIUM — Refactor-vocabulary debt

The breakpoint→layout refactor left three terms for one concept:

- `bp` as the parameter name throughout (`dashboards.ex:285,403,455,509,564`;
  `builder_live.ex:212,263,747,1544,1570`) though the value is a layout id
  like `"l1"`.
- "tier" in comments (`dashboards.ex:250,446,1096-1097`;
  `builder_live.ex:747,1544,1554`).
- `"free"` vs `"pixel"` dual vocabulary (type is `"pixel"`,
  `layout_mode` returns `"free"`, events are mixed:
  `add_widget_px` vs `move_widget_grid`).
- Vestigial magic default `bp \\ "default"` in `size_limits/3`
  (`builder_live.ex:1570`) — no such layout exists anymore.

**Fix**: rename to `layout_id`/"layout" in one sweep; pick one of
"free"/"pixel" for internal vocabulary.

### 12. IMPROVEMENT-MEDIUM — Split `dashboards.ex` (1423 lines)

Pure-function domains that never touch the repo directly:

- Named-layout CRUD (~270 lines, `dashboards.ex:589-845`: `layouts/1`,
  `add_layout`, `rename_layout`, `delete_layout`, `set_grid_dims`,
  `occupied_extent`…) → `Dashboards.Layouts`.
- Placement resolution (`resolve_items`, `resolve_designed` 1259-1291,
  `materialize_grid` 1315-1336) → `Layout`; `resolve_designed`'s inline
  packer (1279-1288) re-implements `Grid.compact/3` (`grid.ex:102-114`) —
  consolidate into one `Grid` pack function.
- Slug machinery (118-187) is split arbitrarily with the schema.

### 13. IMPROVEMENT-MEDIUM — JS hooks: ~150 collapsible lines

- Collision check copy-pasted 3× (`js:281-294`, `690-696`, `947-953`).
- Blocker collection from sibling data-attrs 3× (`js:389-400`, `594-604`, `903-911`).
- The pointermove/up/cancel document-listener trio + pointerId guard 4×
  (`js:132-150`, `407-430`, `669-687`, `822-836`) → one shared `trackPointer`
  helper (as `makeEdgeScroller` already does for scrolling).
- Grid metrics 2× (`js:565-577`, `888-898`); zoom-per-axis 2× (`js:104-105`,
  `342-343`); dashed-preview factory 2× (`js:299-323`, `1003-1016`).
- `intVal` defined twice with **different signatures** (`js:245`
  `(name, fallback)` vs `js:557` `(el, name, fallback)`).

### 14. IMPROVEMENT-MEDIUM (test) — Elixir coverage gaps

- No direct tests: `Lattice`, `Paths`, `Web.Helpers` (incl. the
  security-relevant `user_role_uuids/1` name→uuid mapping,
  `helpers.ex:60-69`), `NoteWidget.fit_font/2`, `ModuleStatsWidget`
  permission gating (`module_stats_widget.ex:199-209`), registry
  duplicate-key/enablement gates.
- Concurrency: CAS tested only sequentially (`dashboards_test.exs:185-221`);
  `delete/2` bypasses the CAS (`dashboards.ex:225-236`) → concurrent delete
  raises `Ecto.StaleEntryError` uncaught.
- Untested LV paths: `refresh_pause`/`refresh_resume`
  (`builder_live.ex:130-151`), catalog `add_widget_at`/`add_widget_px` pushes.

### 15. NITPICKs

- `add_layout/2` resolves the same layout twice (`dashboards.ex:651-660`).
- `configure_widget` spec lists only `:settings`/`:view`
  (`dashboards.ex:1016-1021`) but also handles `:min_override` (1061);
  concurrently-removed instance during an open modal → phantom write +
  `widget_configured` log (guard in `configure_widget`, no-op when the
  instance id isn't found).
- `ModuleStatsWidget` declares no `refresh_interval` (only the clock does,
  `widgets.ex:73`) — stats go stale until reload; deliberate? Document or add.
- `persist/1` CAS fragment casts stored `rev` to int (`dashboards.ex:1224`) —
  tampered non-numeric rev raises an uncaught DB error.
- JS: row-cap fallback disagrees — 50 (`js:253`) vs 36 (`js:567,889`);
  `ResizeObserver` unguarded in `DashboardGridFit` (`js:1176`) vs guarded in
  `DashboardFreeFit` (`js:1102`); `makeEdgeScroller` spins rAF at 60fps even
  at the scroll extent (`js:36-37`); stale "~10%" comments vs
  `TOLERANCE = 1.04` (`js:1169,1199` vs `1226`); file header lists 7 of the
  10 hooks (`js:9-13`); `showCanvasPreview` hardcodes 25px (`js:1030-1031`).
- `NoteWidget`: the `with` on `note_widget.ex:38` has no `else`, so a
  non-binary body falls through to the second check anyway — the `with` line
  is dead weight; `title` unguarded (44); every instance emits a duplicate
  `<style>` block (95-99) → one static rule.
- `role_scope_visible?/2` ignores its second argument
  (`dashboard_form_live.ex:181`).
- `add_widget/3` doesn't `materialize_grid` first while `add_widget_at/6`
  does (`dashboards.ex:255` vs `294`) — undocumented asymmetry.
- `role_scope_visible?` aside: the `bp \\ "default"` magic id
  (`builder_live.ex:1570`) — see #11.

## Suggested order

1. **#1** (touch drag — user-facing) and **#2** (canvas balloon) — small, real bugs.
2. **#5** dedup sweep (size bounds/clamps/coercion into `Widget`/`Lattice`) — kills the drift trap while the surface is small.
3. **#8 + #3 + nitpicks** — one hardening/cleanup commit, same style as `9c8249b`.
4. **#6** registry invalidation — needs a decision on where core hooks module toggles.
5. **#4 / #12 / #13** structural splits — mechanical, do when touching those files next; don't let them grow further.
6. **#7 / #14** test backfill — pair the JS geometry extraction (#13) with its tests (#7).
