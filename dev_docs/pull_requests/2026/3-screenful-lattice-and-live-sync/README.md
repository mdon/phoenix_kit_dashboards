# PR #3: Screenful lattice, live sync, and a security/quality hardening pass

**Author**: @mdon
**Reviewer**: Claude + multi-AI panel (gpt-5.6 / kimi / grok)
**Status**: In Review
**Commit**: `343ece0..HEAD`
**Date**: 2026-07-16

## Goal

Rebuild the grid dashboard model around a **screenful lattice**, make dashboards
**fully live** across sessions (edit on a laptop → a wall TV updates instantly),
and harden the module against a multi-AI security/quality review — so a dashboard
open on a display keeps a clean, correct, self-updating picture and the builder
holds up under concurrent editing and hostile input.

## What Was Changed

### The grid model — from device tiers to a screenful lattice

The old model had fixed device breakpoints (TV/Desktop/iPad/Phone). It's replaced
by **user-defined named layouts**, each a `cols × rows` grid on a gapless **25px
nominal square-cell lattice** representing **exactly one screenful — nothing
scrolls**. The canvas fits the viewing pane: per-axis stretch only within a tight
~4% tolerance (absorbing Fit-screen rounding), otherwise the intact artboard
shrinks to fit a smaller pane or **floats centered at natural size** in a bigger
one (never blown up). Widget content self-fits via container-query type scaling
clamped to a consistent range; list widgets take an "items: N" slot budget. Views
(detailed/compact/analog…) are **user-chosen per layout** and honored verbatim —
never silently switched by size.

### Fully live (PubSub) + concurrency-safe

Every mutation flows through a single `persist/1` choke point that (a) broadcasts
the new state on a per-dashboard PubSub topic — the builder subscribes on mount,
so any open session re-renders on someone else's edit and navigates away on delete
— and (b) optimistic-locks on a monotonic `config["rev"]` counter (compare-and-swap,
**no schema migration**): a stale-snapshot write is refused with `{:error, :stale}`
instead of clobbering a concurrent edit, and the LiveView re-syncs.

### Display mode + polish

Full-screen is now a clean **display mode**: it hides the per-widget edit chrome,
resize grips, guides and caption, and auto-hides the mouse after idle (YouTube-style).
The refresh loop pauses while the tab is hidden (snap-to-now on return) so a
backgrounded tab doesn't fast-forward its clocks; it also no longer forces a
full-page re-render every tick (all refresh state lives in the process dictionary).

### Host-app widgets

The host app can contribute widgets via `config :phoenix_kit_dashboards,
widget_providers: [MyApp.Widgets]` — same `phoenix_kit_widgets/0` plain-map
contract as a module, discovered by the Registry, verified end-to-end in the parent.

### Security / quality hardening (multi-AI review)

Re-authorize every builder event and the form save; gate the add-widget paths
through the catalog's scope filter; nil-crash guards on the settings modal; scalar
settings + declared-view validation to prevent bricking; pixel-coordinate bounds;
module-stats gated on module access + enablement; `Widget.from_map` accepts
string-keyed provider maps and rejects form-breaking schema keys; provider
isolation; JS zero-size-grid and out-of-window-release guards. **Core companion
fix** (separate PR in `phoenix_kit`): the HTML sanitizer's URL blacklist was
bypassable by entity/whitespace obfuscation — replaced with an allowlist.

### Files Modified

| File | Change |
|------|--------|
| `web/builder_live.ex` | Lattice render, per-layout views, live-sync + stale re-sync, event re-auth, display mode, refresh loop → process dict, pause/resume |
| `dashboards.ex` | `persist/1` (PubSub + optimistic lock), lattice geometry, `set_layout_view/4`, scalar-settings guard, pixel bounds, `:stale` specs |
| `web/dashboard_form_live.ex` | New dedicated create/edit page (replaces the modal); re-auth on save |
| `web/dashboards_live.ex` | Manage page trimmed to list/create/clone/delete |
| `registry.ex` | Config-declared host `widget_providers`; provider isolation |
| `widget.ex` | Lattice sizes, ignore provider `max_size`, string-keyed maps, schema-key charset |
| `layout.ex` | Per-layout `view/2`; lattice span defaults |
| `widgets/*` | Self-fit (container queries), clamped type, module-stats access gate |
| `priv/static/assets/phoenix_kit_dashboards.js` | Native fit, drag/resize per-axis zoom, dot guides, fullscreen idle-cursor, visibility pause, zero-size guards |
| `test/**` | +live_sync, +builder_live_sync, optimistic-lock, authz, pause/resume, display-mode, host-provider, self-fit; breakpoints test removed |

## Implementation Details

- **Standard cells**: `Lattice` holds `@cell 25`, dims `4..160`, stretch tolerance
  `1.04`. Fit is NATIVE (no CSS transform) so text/SVG render undistorted (the
  analog clock stays round); only cell rectangles absorb the ~4% stretch.
- **Optimistic lock without a migration**: `rev` lives in the existing `config`
  JSONB; `persist/1` does a guarded `update_all` CAS and broadcasts on success.
- **Refresh loop hygiene**: latch + paused flag + per-widget refresh times are in
  the process dictionary, so a tick only `send_update`s due widgets — no parent
  re-render, no per-second layout DB query.
- **No backwards compatibility**: there are no users yet, so tier/unit translation
  was deleted rather than adapted.

## Testing

- [x] Unit + LiveView tests: 206 tests, 0 failures (incl. two-session live-sync,
      optimistic-lock, authz, pause/resume, display-mode, host-provider, self-fit)
- [x] `mix precommit` green: format, `compile --warnings-as-errors`,
      `deps.unlock --check-unused`, `hex.audit`, `credo --strict`, `dialyzer`
- [x] Pre-PR triage sweep (authz / error-handling / audit-log-gettext-dead-code) — see `CLAUDE_REVIEW.md`
- [x] Browser-verified across four layout shapes (Desktop/Wall TV/Phone/Square)
- [x] Host-app widget discovery + render verified in `phoenix_kit_parent`

## Related

- Core companion: HTML sanitizer allowlist fix (`phoenix_kit`, separate PR)
- Previous: [#1 dashboard-builder-overhaul](/dev_docs/pull_requests/2026/1-dashboard-builder-overhaul/)
