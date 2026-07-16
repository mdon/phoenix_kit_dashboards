# CLAUDE_REVIEW — PR #3 (screenful lattice + live sync)

Two review rounds fed this PR:

1. **In-build multi-AI review** (gpt-5.6 / kimi / grok) during development — found and
   fixed the load-bearing authz / XSS / concurrency issues as the feature landed.
2. **Pre-PR triage sweep** — three focused read-only passes (authorization,
   error-handling/crash-resilience, audit-log/gettext/dead-code/test-coverage)
   over the full diff. Findings below, each classified and with its disposition.

Severity taxonomy: `BUG-CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT-HIGH/MEDIUM`, `NITPICK`.

## Fixed in this PR (sweep commit `e4b99a1`)

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | BUG-HIGH | `save_settings` crashed on a non-string `"view"` param (grid): `set_layout_view/4` is `when is_binary(view)` with no fallback, but the param was passed through with only a `not in [nil, ""]` check. | Guard `is_binary(params["view"])` before the grid view write. |
| 2 | BUG-MEDIUM | `Dashboards.get/1` raised `Ecto.Query.CastError` on a non-UUID id (PK is UUIDv7); every caller treats "not found" as `nil`. Reachable via `/dashboards/<junk>` and crafted `phx-value-uuid`. | Validate with `Ecto.UUID.cast/1` → bad id maps to `nil`. |
| 3 | IMPROVEMENT-HIGH | `refresh_resume` sent an immediate tick without latching `pk_refresh_scheduled`; spamming it enqueues N ticks that each spawn a self-rescheduling loop (self-DoS). | Latch before sending the tick. |
| 4 | NITPICK→fixed | `save_settings` swallowed `{:error, :stale}` (no resync) while every other mutation calls `resync/1`. | Route `:stale` through `resync/1`. |
| 5 | NITPICK→fixed | `delete` gated only on `can_delete?` (true for any non-personal), unlike `clone` which requires `can_view?` — a crafted uuid could blind-delete a role dashboard the actor can't see. | Add `can_view?` to the delete chain. |
| 6 | IMPROVEMENT-MEDIUM | Dead code from the tiers→lattice refactor: unreachable `grid_dim` event handler + `Dashboards.resize_grid/4` (the ± steppers were removed). | Removed both. |
| 7 | IMPROVEMENT-MEDIUM | `Dashboards.set_layout_mode/2` + `Dashboard.layout_modes/0` had no caller (type is fixed at creation). | Removed; `type/1`'s legacy `config["mode"]` read stays for old data. |
| 8 | IMPROVEMENT-MEDIUM | Raw arithmetic on stored geometry (`next_pixel_y`, `pixel_cells`) could `ArithmeticError` on a legacy/tampered non-integer pixel field. | Coerce via `int/2` / `to_int/2` (defense-in-depth; not event-reachable — every event write already coerces). |
| 9 | NITPICK | `normalize_entry/1` had no fallback for a `config["layouts"]` entry missing `"id"` (tampered config → `FunctionClauseError` in the hot `layouts/1`). | `layouts/1` drops id-less entries first. |
| 10 | BUG-MEDIUM (docs) | Three docstrings claimed mid-session role/permission revocation "fails closed like a fresh mount." The dispatcher re-fetches the dashboard *row* (so a scope flip fails closed), but the actor's roles/permissions come from the mount-time scope (core `on_mount` doesn't re-run per event). | Corrected the docstrings to state the real guarantee. |

Regression + blind-spot tests added (206 total): malformed-uuid `get/1`, `set_dims`/`fit_screen` LV events, hostile non-string view, `refresh_resume` idempotence, role-dashboard delete gate, malformed-uuid delete.

## Known gaps / accepted (documented, not changed)

- **IMPROVEMENT-MEDIUM — mid-session permission revocation is not live.** A
  role/permission *revocation* takes effect on the next remount, not the next
  event, because the actor's scope is captured at `on_mount`. Module *disabling*
  IS live (fresh `ModuleRegistry` lookup), and a dashboard *re-scope* IS caught
  (the row is re-fetched). Making permission revocation live per-event needs core
  support (a scope re-derivation hook); out of this module's scope. Blast radius
  is admin-only and self-heals on remount.
- **IMPROVEMENT-MEDIUM — widget hiding has no UI.** `hide_widget/4` +
  `resolve_hidden?/3` + the `"hidden"` placement flag + the render dimming are all
  wired, but no control sets it — a placed widget can't be hidden in production.
  Kept as a complete, tested capability awaiting a UI toggle (adding the toggle is
  a feature, out of a quality sweep's scope).
- **IMPROVEMENT-HIGH (test) — the activity-log rescue path is untested.**
  `log_on_ok/4` rescues a raising/exiting `Activity.log` so it never crashes a
  mutation; there's no mock harness to inject a failing logger here. Verified by
  inspection.
- **LiveView `:stale` → resync is a tight-race safety net.** The context-level
  `{:error, :stale}` is tested (optimistic-lock test); the dispatcher re-fetches
  before each event, so the LV path only fires if a write lands in the sub-
  round-trip window — not deterministically reproducible without concurrency
  injection. Wiring verified by inspection.
- **NITPICK — gettext on default names.** `"My Dashboard"`, `" (copy)"`, `"Layout N"`
  are stored, user-editable data, so they follow the data convention (not
  `gettext`) — a deliberate call, noted for consistency.
- **NITPICK — activity-log asymmetry.** Geometry edits via the settings modal log
  `widget_configured`; the identical drag gestures don't (hot path). Defensible —
  the modal is an explicit "configure" action.
- **NITPICK — unused exports** `Grid.max_rows/0`, `Lattice.stretch_tolerance/0`,
  `Dashboards.update_widget_settings/4`: harmless documented constant-getters /
  thin wrappers; left as API surface.

## Verified clean (checked, no issue)

Every mutating event routes through the re-fetching + `can_view?` dispatcher;
add-widget paths are scope-gated (`with_offered_widget`); `configure_widget`
coerces non-map settings, strips non-scalar values, and validates the view;
`module_stats` gates `get_config` on module access + enablement; the JS hooks
guard zero-size grids, zero divisors, re-entrant/out-of-window gestures, and
release pointer-capture/listeners; server-side clamps cap huge/negative pixel
coordinates; provider discovery + `Widget.from_map` rescue crashes and drop
malformed widgets; `subscribe`/`broadcast`/`log_on_ok` are rescued.

## Baseline

`mix precommit` green (format, `compile --warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `credo --strict`, `dialyzer`) + 206
tests, 0 failures.

## Round 3 — post-merge follow-up audit (fixed on `main`, after `ac45f61`)

PR #3 was already merged when this pass ran. Independent re-audit against the
Phoenix/Ecto gotcha lenses (mount queries, PubSub scoping, sticky-LV staleness,
`to_atom` on user input, N+1, CAS correctness, per-event authz, JS hook leaks)
turned up issues Round 2 missed. Fixed directly on `main` (no new PR — this
module integrates straight to `main`, see AGENTS.md).

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 11 | BUG-MEDIUM | `Grid.first_free/4` scanned `y` up to the hardcoded `@max_rows` (160), never the layout's real `rows` — callers clamp `w`/`h` to the layout but not the returned `y`. On a small, fully-packed layout (common now that layouts can be as small as 4×4, not fixed device tiers), `first_free` returned a "confident" in-bounds-looking placement 1+ rows past the visible screenful instead of correctly reporting "no fit" — clipped/invisible in the UI, contradicting the module's own "ONE SCREENFUL, NOTHING SCROLLS" invariant. Reproduced: a 4×4 layout packed solid with 1×1s → `Grid.first_free(occupied, 1, 1, 4) == {0, 4}` (row 4 is out of bounds for rows 0..3). | Added an optional `rows` param (default `max_rows/0`, so existing unbounded callers are unaffected) to `first_free/5` and `compact/3`; every dashboards.ex call site that has a real layout row count now passes it (`new_instance`, `reorder_widgets`, `add_layout`, `resolve_designed`). When no fit exists within `rows`, `first_free` now correctly returns `nil`, and the caller's existing `below_all/1` fallback (stacking below the screenful) applies — the *documented* behavior for a full layout, not an accidental scan artifact. Note: a full layout's new-widget-goes-below-the-fold fallback is unchanged/pre-existing and still not surfaced to the user as a "no room" message — see Known gaps below. |
| 12 | BUG-MEDIUM | `Web.DashboardsLive` had no catch-all `handle_event/3` — only `"clone"` and `"delete"` (each requiring a `"uuid"` param) were defined, unlike both sibling LiveViews touched by this same PR (`BuilderLive`, `DashboardFormLive`), which both guard exactly this case. Any other event name, or `"clone"`/`"delete"` fired with a missing `"uuid"` (a crafted push, a future UI change that forgets this file), raises `FunctionClauseError` and crashes the LiveView process. | Added the same catch-all `handle_event(event, _params, socket)` (logs + no-ops) used by the sibling files. |
| 13 | IMPROVEMENT-MEDIUM | `DashboardFormLive.do_update/2`'s `{:error, _changeset}` wildcard also matched `{:error, :stale}` (`Dashboards.update/3`'s real spec is `{:error, :stale \| Ecto.Changeset.t()}`) — a concurrent metadata edit (two admins editing the same dashboard's title/scope) in the re-fetch→persist window was reported as a generic "Could not update dashboard" with no resync. Same bug class as fixed item #4 above, reintroduced in this PR's own new file. | Added an explicit `{:error, :stale}` branch: flashes "this dashboard was just edited elsewhere — please try again" and navigates back to the index (this page is a one-shot form, not a long-lived session like the builder, so there's no in-place state to resync — back-to-index is the correct equivalent of `BuilderLive`'s `resync/1`). |
| 14 | IMPROVEMENT-MEDIUM | `DashboardVisibility` JS hook only reacted to `visibilitychange` transitions — a dashboard that mounts *already* in a background tab (ctrl/click-opened, several tabs restored at browser startup) never pushed the initial `refresh_pause`, so the server's refresh loop ticks unattended until the *first* transition — exactly the "backlog fast-forwards on refocus" bug the pause/resume feature (`de8f914`) was built to eliminate, just for the "born hidden" case instead of "backgrounded after focus." | `mounted()` now also pushes `refresh_pause` immediately if `document.hidden` is already true at mount. |

Not fixed (documented only):
- **NITPICK, low confidence — `DashboardFormLive.scope_attrs/2` accepts any
  non-empty `role_uuid` string from a hand-crafted `"save"` event on create**,
  even though the UI hides the role option. Impact is minimal: the page is
  already admin-gated, the changeset still requires a valid UUID shape, and the
  backend already fully supports role dashboards by design (grandfathered edit
  path) — this is "using a hidden feature you already have latent authority
  over," not a privilege escalation. Left as-is.

Regression tests added: `Grid.first_free/5` and `Grid.compact/3` rows-bound
cases (`test/grid_test.exs`); a metadata `update/3` stale-CAS case mirroring
the existing `add_widget` one (`test/dashboards_test.exs`); unrecognized-event
and missing-uuid catch-all cases for `DashboardsLive` (`test/web/dashboards_live_test.exs`).
The `:stale` branch in `DashboardFormLive.do_update/2` and the JS hook's
initial-visibility push are verified by inspection only, same as the
already-documented tight-race note above — not deterministically reproducible
without concurrency/DOM injection.

## Known gaps / accepted (Round 3, in addition to the above)

- **IMPROVEMENT-MEDIUM — a full layout has no "no room" UX.** When
  `add_widget/3`'s catalog-click path can't fit the new widget within the
  active layout's `rows` (now correctly detected — see fix #11), it falls back
  to `Grid.below_all/1`, stacking the widget below the visible screenful with
  no error or flash. The user sees the widget vanish with no explanation. This
  fallback already existed before Round 3 (previously "practically
  unreachable" at `max_rows = 160`; now genuinely reachable on any small,
  full layout) — surfacing a "no room, resize the layout or free a spot"
  message is a UX feature, out of a bug-fix pass's scope.
