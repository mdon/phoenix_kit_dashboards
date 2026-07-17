# Follow-up — 2026-07-16 code review (phoenix_kit_dashboards)

Response to `dev_docs/2026-07-16-code-review.md`. Per-finding resolution below.
Verification at the bottom.

Baseline before this work: **212 tests, 0 failures** (full suite with a local
`phoenix_kit_dashboards_test` DB — the review ran with no Postgres, so it saw
only the 71 unit tests).

## Resolved

### #1 — BUG-HIGH · touch drag-out (pointer capture) — FIXED
`DashboardCatalogDrag.track()` computed `overCatalog` from
`ev.target.closest("#dashboard-catalog")`. Touch's implicit pointer capture pins
`ev.target` to the catalog entry for the whole gesture, so `overCatalog` was
always true → every drop cancelled. Now computed by rect math against the panel
(`this.el.getBoundingClientRect()` + `panelHidden`), mirroring the panel-hide
check right above it — pointer-capture-immune. (commit `33e88fc`)

### #2 — BUG-MEDIUM · pixel-canvas balloon — FIXED
`place_widget_px` / `add_widget_px` clamped `fx/fy` only to `[0, 20000]`, and
`free_canvas_dims` grows the canvas to contain widgets, so a crafted
`move_widget_to` at ~20000px forced a giant canvas for every viewer of a shared
dashboard. Placement is now bounded to one screen (`@free_max_px` = 4000px) past
the furthest OTHER widget's edge, still capped at `@free_max_pos` — the canvas
grows a screenful per move but a single event can't balloon it. Test updated to
assert the security property. (commit `33e88fc`)

### #3 — BUG-MEDIUM (docs) · pre-lattice min sizes — FIXED
`AGENTS.md` ("analog floors at 2×2") and the ClockWidget moduledoc + analog-face
comment ("analog 2×2 / digits 3×1", "per tier") corrected to the real lattice
values (normal 8×4 / digital 12×4 / analog 8×8) and the tier relic dropped.
(commits `f9774fc`, `3908a21`)

### #5 — IMPROVEMENT-HIGH · context↔LiveView drift trap — FIXED
The verbatim `size_bounds`/`instance_min` twins, the three `clamp/3` with
divergent semantics, the two int coercions, and the duplicated free-px constants
are consolidated:
- New `PhoenixKitDashboards.Sizing.bounds/2` is the single resize-bounds rule
  (a dedicated module — a Widget-hosted helper would create a Widget↔Registry
  cycle). `Dashboards` + `BuilderLive` both call it.
- `Lattice` gains the one `clamp/3`, the one `to_int/2`, and the free-px
  constants; every local `clamp`/`int`/`to_int` delegates to it. This also
  **fixed** builder's `to_int/2`, which was integer-only — a float from legacy
  JSONB silently rendered as the default. (commit `d6e64e5`)

### #6 — IMPROVEMENT-HIGH · registry cache invalidation — FIXED (documented)
Module **enablement** was already re-checked live (`visible_for_scope?`), so the
practical staleness is only the cached catalog STRUCTURE (widget definitions +
computed options like the module-stats / projects pickers). The moduledoc now
documents that live-vs-cached split precisely, and `enable_system/0` calls
`Registry.refresh/0`. Core exposes no module-toggle event to hook (verified), so
`refresh/0` stays host/provider-driven — noted as the remaining cross-repo
option. (commit `e538009`)

### #8 — IMPROVEMENT-MEDIUM · mixed-type numerics in grid math — FIXED
`Grid.collides?/below_all/compact`, `resolve_designed`, and `occupied_extent`
did raw arithmetic on stored `w/h` (`p["w"] || 1`), so a string/float span raised
`ArithmeticError`. All coerce through `Lattice.to_int/2` now. Regression tests in
`grid_test.exs`. (commit `d6e64e5`)

### #9 — IMPROVEMENT-MEDIUM · dead/unwired API — FIXED
- `get_or_create_default/1` hard-matched `{:ok, _} = create(...)` → MatchError on
  a create error; now handles `{:error, _}` (a lost concurrent race — re-query
  the winner) and is documented host-facing.
- `update_widget_settings/4` removed (pure redundant wrapper over
  `configure_widget/4`; its test retargeted).
- `hide_widget/4` + `resolve_hidden?/3` documented as the host-facing
  hidden-widget API (render support is built; no built-in toggle yet — a UI
  toggle would be a feature, out of sweep scope). (commit `3908a21`)

### #10 — IMPROVEMENT-MEDIUM · permission rule 3× under 3 names — FIXED
`can_delete?`/`deletable?`/`can_manage?` collapsed into
`Web.Helpers.manageable_by?/2` (takes an actor uuid so socket + render callers
share one rule); `can_view?` (×2) into `viewable_by?/2`. All three LVs rewired.
The list page's Edit item was gated by `deletable?` (right behavior, wrong name)
— `manageable_by?` makes the intent correct. (commit `3908a21`)

### #14 / #15 — test backfill + nitpicks — MOSTLY FIXED
- **Elixir nitpicks:** the `persist/1` CAS `::int` cast is regex-guarded (a
  tampered non-numeric `rev` no longer raises an uncaught DB error); NoteWidget
  dropped its dead `with` and now coerces `title`; `configure_widget/4` `@spec`
  lists `:min_override`; `role_scope_visible?` dropped its ignored arg;
  documented ModuleStats' intentional static refresh and the
  add_widget/add_widget_at materialize asymmetry.
- **JS nitpicks (safe subset):** header lists all 9 hooks; row-cap default
  unified to 36; stale "~10%" tolerance comments → ~4%; `DashboardGridFit`'s
  ResizeObserver typeof-guarded like `DashboardFreeFit`.
- **Tests:** `lattice_test`, `sizing_test`, `web/helpers_test` (+17) pin the
  consolidations above. (commits `e538009`, `f53a315`)

## Deferred (with rationale) — recommended as a focused follow-up

### #4 / #12 — split `builder_live.ex` (2036) + `dashboards.ex` (1423)
Pure mechanical code motion, but the largest change by far and the review's own
step 5 ("mechanical, do when touching those files next; don't let them grow
further"). Kept out of this pass so the diff stays reviewable and the behavioral
fixes above can be verified in isolation; the splits belong in their own commit
where the only risk is code motion. **No new code was added to either file here**
(the dedup #5 net-removed lines from both), so they haven't grown.

### #13 (deep) / #7 — JS hook dedup + JS geometry tests
The safe JS nitpicks are done (#15). The ~150-line dedup (shared
`trackPointer`/collision/metrics helpers) and the Node test harness for the pure
geometry (`fitCells` ↔ `Grid.fit_size/8`) are deferred: **this repo has no JS
test runner**, so refactoring the drag/resize hooks can only be validated by
driving them in a real browser. That extraction + its Node tests should land
together, browser-verified, as their own change — doing it blind here would risk
the exact drop-matches-preview invariant the review calls out.

### #11 — vocabulary debt (`bp` / "tier" / "free")
Renaming the `bp` parameter to `layout_id` and dropping "tier" language is a
large mechanical rename across `dashboards.ex` + `builder_live.ex` + `layout.ex`.
The persisted JSONB key stays `"bp"` (back-compat), so this is names/comments
only — low behavioral value, high churn — best bundled with the #4/#12 splits
that touch the same code.

### #15 — micro-items left as-is
`add_layout/2`'s double layout resolution (negligible perf); the NoteWidget
per-instance `<style>` (a *static* rule — de-duping needs CSS infra or a risky
Tailwind-arbitrary conversion, so kept with its explanatory comment); `intVal`
defined twice with different signatures (they're methods on different hook
objects, so not a real conflict); `makeEdgeScroller` rAF at the scroll extent
and `showCanvasPreview`'s hardcoded 25px (behavioral JS, deferred with #13).

## Multi-AI re-review of the fix diff

A 4-AI adversarial panel (Codex, Kimi, Grok, ZAI — Gemini was quota-exhausted)
reviewed the fix diff for regressions the fixes themselves introduced. It
confirmed the JS rect math, the Sizing/Lattice consolidation, `manageable_by?`,
the CAS regex, and `get_or_create_default` are all correct, and surfaced six
items — **all fixed and pinned** (commit `af9687c`):

- **pixel_bound excluded the moved widget** (Grok HIGH, Kimi MED) — a widget
  parked far out was yanked back when peers moved nearer. Now includes its own
  edge (a single event still can't jump more than one screen).
- **Uncapped string geometry balloon** (ZAI MED, Codex MED) — `free_geometry`
  now clamps stored fx/fy/fw/fh on read (grid dims were already capped by
  `layouts/1`).
- **Zero-width span not floored** (Codex MED) — `collides?`/`below_all`/
  `occupied_extent` now floor a coerced span to 1, like rendering/compact.
- **pixel_bound could go negative** (Codex LOW) — extent floored at 0.
- **NoteWidget title dropped non-string scalars** (ZAI LOW) — a numeric/boolean
  title now still renders; only a map/list falls back.
- **`update_widget_settings/4` removal was breaking** (Codex MED) — restored as
  a documented thin alias for `configure_widget/4`.

## Verification

- `mix precommit` (via `PHOENIX_KIT_PATH=../phoenix_kit`): **clean** — compile
  (warnings-as-errors), `mix format`, `credo --strict`, dialyzer **0 errors**.
- `mix test`: **236 tests, 0 failures** (212 baseline + 24 new).
- `node --check` on the hook bundle: clean.
