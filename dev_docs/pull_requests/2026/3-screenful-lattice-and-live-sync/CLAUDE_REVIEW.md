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
