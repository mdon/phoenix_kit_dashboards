# CLAUDE_REVIEW — PR #4 (code review resolution + C14 sweep)

This PR already carried two review rounds before merge (documented in
`dev_docs/2026-07-16-code-review.md` / `-FOLLOWUP.md`): the original 15-finding
review, and a multi-AI (Codex/Grok/ZAI) re-review that caught a `Grid.compact`/`pack`
regression. This is **round 3** — an independent post-merge pass, run as four parallel
lenses (geometry/math, context/permission layer, LiveView extraction, gettext/widgets),
each explicitly told not to re-report anything already fixed in rounds 1-2.

Severity taxonomy: `BUG-CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT-HIGH/MEDIUM`, `NITPICK`.

## Fixed in this round

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | BUG-HIGH | `Dashboards.place_at_cell/5` (reached via `place_widget_grid/5`, the server-side handler for a grid drag-to-cell drop) read `Layout.placement/2`'s `"w"`/`"h"` raw, with no `Lattice.to_int` coercion. `Layout.placement/2` does **not** coerce by design (every other call site in `grid.ex` coerces at the point of arithmetic). A widget instance carrying a legacy/tampered string span (`"h" => "4"`) crashed `grid_rows(...) - h` with `ArithmeticError` — a plain drag-to-cell action on any dashboard with such a row. `"w"` had a quieter failure mode: `min(placement["w"], cols)` picks `cols` unconditionally when `"w"` is a binary (Erlang term ordering: any number < any binary), silently discarding the stored width instead of coercing it. Round 1's finding #8 fixed this coercion-gap bug class in `Grid.collides?/below_all/compact`, `resolve_designed`, and `occupied_extent` — `place_at_cell` was the one call site it missed. | Coerce both via the module's existing `int/2` → `Lattice.to_int/2` helper, floored at 1 like every other geometry site: `w = min(max(int(placement["w"], 1), 1), cols)`, `h = max(int(placement["h"], 1), 1)`. |
| 2 | BUG-MEDIUM | `Dashboards.grow_on_layout/5` (reached via a widget view switch that raises the view's minimum size, e.g. clock text→analog) had the identical gap: `w = max(p["w"], min(min.w, cols))` — `max` against a binary `p["w"]` always returns the binary itself (same term-ordering rule), so `w` silently becomes the raw string. If `p["h"]` happened to be a valid integer needing growth, the `w == p["w"] and h == p["h"]` no-op guard evaluated false (because `h` changed), falling into the `is_integer(p["x"]) and is_integer(p["y"])` branch, which then computed `p["x"] + w` — `integer + binary` → `ArithmeticError`. Repro: a clock widget stored with `"w" => "4"` (legacy string) and a valid integer `"h"`, switched from a view with a lower height floor to one with a higher one. | Coerce `p["w"]`/`p["h"]` up front via `int/2`, floored at 1, and compare against the coerced originals (`orig_w`/`orig_h`) rather than the raw map values, so the no-op guard and the growth arithmetic both see integers. |
| 3 | IMPROVEMENT-MEDIUM | `Dashboards.resize_instance/7` passed `placement["h"]` uncoerced as `Grid.fit_size/8`'s `orig_h` ("probe height" used to decide whether the width-fit should hold the current height). Not a crash — `Grid.fit_size` does `min(orig_h, req_h)`, and a binary `orig_h` always loses that `min` to the integer `req_h` — but it silently discards the stored height for legacy/tampered rows instead of using it, same missed-coercion pattern as #1/#2. | Coerce to `orig_h = max(int(placement["h"], 1), 1)` before the `Grid.fit_size/8` call. |
| 4 | IMPROVEMENT-HIGH | `web/dashboards_live.ex`'s widget-count caption used `Gettext.ngettext(PhoenixKitWeb.Gettext, "%{count} widget", "%{count} widgets", n)` — the runtime form, left over from before this PR's ~109-site macro conversion. Unlike the documented exception (`Helpers.translate_catalog/1`, which genuinely needs the runtime form for a dynamic variable), this call has **static literal** msgids; only the plural count is dynamic, which `ngettext/3` handles natively. `Gettext.ngettext/4` (the top-level runtime function) bypasses `mix gettext.extract` entirely (extraction is wired into the compile-time macros from `use Gettext, backend: ...`, not the runtime `Gettext` module functions) — so `"%{count} widget"`/`"%{count} widgets"` can never gain a translation via the normal workflow, silently undermining the PR's own "one exception" claim. Not introduced by this PR (the call site wasn't touched in the diff) but directly contradicts its stated scope, and rounds 1-2 missed it. | Converted to the macro form: `ngettext("%{count} widget", "%{count} widgets", length(dashboard.layout))` (the module already has `gettext/1`/`ngettext/3` in scope via `use PhoenixKitWeb, :live_view`). |
| 5 | NITPICK | `web/builder_components.ex`'s moduledoc claimed *"BuilderLive keeps its own thin `to_int`/`clamp` wrappers"* for event handlers — stale from an earlier phrasing. The actual helper is `to_i/1` (event-param rounder: rounds floats, parses integer strings, defaults to `0`), which does **not** wrap or call `Lattice.to_int`/`Lattice.clamp` at all. `builder_live.ex` itself carries the accurate comment; the twin claim in the new file was never updated to match. No runtime impact (clamping still happens server-side in the `Dashboards` context regardless). | Corrected the moduledoc to describe `to_i/1` accurately as an unrelated event-param rounder, not a `Lattice` wrapper. |

Regression tests added in `test/dashboards_test.exs` (`place_widget_grid/5` and
`resize_widget/5` describe blocks): a legacy string-span placement fed through
`place_widget_grid/5` and through a view-switch growth (`configure_widget/4`), each
asserting coercion instead of a crash.

## Known gaps / accepted (documented, not changed)

- **IMPROVEMENT-MEDIUM, test coverage — `test/js/geom.test.cjs`'s parity claim is
  narrower than advertised.** The file's comment says the JS `fitSpan` "mirrors
  `Grid.fit_size` one-for-one," but `fitSpan` has no `max_size` parameter at all —
  that clamp happens outside it, in the DOM-bound `DashboardResize.fitCells`
  (`Math.min(this.maxW, …)`), which isn't exercised by the Node harness. The Node
  tests only cover cases where the grid edge/neighbour is the binding constraint,
  never one where `max_size` is tighter than `cols - x`. Not a live bug today (the
  clamp is applied correctly in `fitCells`), but a real coverage gap in exactly the
  area the file's own comment claims to pin. Left as documented, not changed —
  closing it needs a DOM-level (not pure-function) JS test harness, out of scope for
  a review-round fix.
- **NITPICK — `Web.Helpers.viewable_by?/2` has no direct unit test** in the new
  `test/web/helpers_test.exs` (only `manageable_by?`, `scope_label`,
  `translate_catalog` are covered there). It's a two-line delegate to the
  already-tested `Dashboards.visible_to?/3` and is exercised indirectly via every
  LiveView test — low priority.

## Verified clean (checked, no issue)

**Context/permission layer**: all 11 call sites of `viewable_by?`/`manageable_by?`
are 1:1 renames of the pre-PR `can_view?`/`can_manage?`/`can_delete?` calls with
identical gating logic and argument order; no check dropped, weakened, or
reordered. Stale-write (`{:error, :stale}`) handling is unchanged and still
terminates through `persist/1`'s CAS on every mutation path. `Registry`'s
`:persistent_term` cache invalidation (`enable_system/0` → `Registry.refresh/0`)
is intact; `disable_system/0` correctly doesn't need it (enablement is checked
live). Activity logging's logged/unlogged split (mutations logged,
`save_layout/2` + per-widget geometry tweaks not) matches every function's own
doc comment. The only `String.to_atom` in the module (`widget.ex:296`) is gated
by a hardcoded allowlist against developer-declared provider keys, not
end-user/param input — unchanged by this PR.

**LiveView extraction** (`builder_live.ex` 2028→991, `builder_components.ex` new
~1047 lines): a line-multiset diff of the extraction commit confirmed 1:1 code
motion, not a rewrite — no handler, assign, or helper dropped or duplicated
between the two files. No DB queries in `mount/3` (only `Dashboards.subscribe`
when `connected?`, and a `:persistent_term` catalog read). PubSub topic is
scoped per dashboard uuid, not global. Both the outer re-fetch dispatcher and
the inner catch-all `handle_event/3` are present, matching sibling LiveViews.
`BuilderComponents`' functions are genuinely display-only — every helper they
call operates on the already-loaded `%Dashboard{}` struct or the persistent_term
catalog, no Repo calls, no internal state.

**Gettext conversion**: extracted every `Gettext.gettext(...)`/`gettext(...)`/
`ngettext(...)` msgid literal from the pre-PR and post-PR trees across all of
`lib/phoenix_kit_dashboards/` — 118 calls, 99 unique msgids, exact multiset
match on both sides. No string altered, no msgid orphaned. Every module calling
`gettext/1` has the macro in scope (`use Gettext, backend: PhoenixKitWeb.Gettext`
directly, or transitively via `use PhoenixKitWeb, :live_view`/`:html`) — the
merge compiles. `Helpers.translate_catalog/1` is genuinely dynamic (sourced from
the runtime widget-provider catalog) and correctly kept as the runtime form.

**Widget size docs**: `ClockWidget`'s moduledoc (normal 8×4 / digital 12×4 /
analog 8×8) matches its declared `min_size` values in `widgets.ex`, both within
`Lattice`'s 4..160 bounds.

**Grid packer split**: `compact/3` still has its own fresh-grid loop, never
rewrites or row-clamps a caller's stored `h` — confirmed against the round-2
regression guard test. No `Grid.compact`/`pack`/`slot` call site in
`dashboards.ex` defaults to `@max_rows` where a real layout row count is
available (the round-3-of-PR#3 bug class, from the *previous* PR, did not
recur here). Off-by-one bounds in `first_free`/`free_x_in_row` are correct at
both edges.

## Baseline

`mix precommit` clean (compile `--warnings-as-errors`, `deps.unlock
--check-unused`, `hex.audit`, `format --check-formatted`, `credo --strict`,
`dialyzer`) against local core (`PHOENIX_KIT_PATH=../phoenix_kit`) after the
round-3 fixes above. `mix test`: 93 unit tests, 0 failures (146 `:integration`
tests auto-excluded — no PostgreSQL available in this review environment; per
AGENTS.md this is expected without a local DB, and the PR's own description
reports 237/0 with one).
