# PR #4: Address the 2026-07-16 code review: 15 findings + multi-AI re-review + C14 sweep

**Author**: @mdon
**Reviewer**: @claude (round 3, post-merge)
**Status**: Merged
**Commit**: `9d6fd5e` (merge; base `cc996f1`)
**Date**: 2026-07-18

## Goal

Resolve all 15 findings from the 2026-07-16 code review (`dev_docs/2026-07-16-code-review.md`),
documented finding-by-finding in `dev_docs/2026-07-16-code-review-FOLLOWUP.md`. Two extra
rounds fed the same PR before merge: a multi-AI (Codex/Grok/ZAI) re-review that caught a
`Grid.compact`/`pack` regression, and a C14 stale-reference quality sweep.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `dashboards.ex` | 1503→1459 lines; pure helpers extracted to `layouts.ex`; packer consolidated onto `Grid.slot/5` + `Grid.pack/4`; permission checks unified onto `Web.Helpers.viewable_by?/manageable_by?`; `bp`/"tier" vocabulary renamed to `layout_id`/"layout" internally (JSONB key `"bp"` unchanged, back-compat). |
| `grid.ex` / `lattice.ex` / `sizing.ex` | Packing primitives consolidated (`slot/5` shared by `compact/3` and `pack/4`, which now have distinct, documented contracts — `compact` never rewrites a stored `h`); span/coordinate coercion centralized in `Lattice.to_int/2` / `Lattice.clamp/3`. |
| `layouts.ex` (new) | Pure layout-list helpers extracted out of `dashboards.ex`. |
| `web/builder_live.ex` | 2028→991 lines; presentational HEEx extracted to `web/builder_components.ex`. |
| `web/builder_components.ex` (new) | ~1047 lines of extracted function components + render-only helpers. |
| `web/dashboards_live.ex`, `web/dashboard_form_live.ex` | Minor: permission-check renames, doc fixes. |
| `web/helpers.ex` | Permission checks (`viewable_by?`/`manageable_by?`) consolidated from 3 differently-named spellings. |
| widgets (`clock_widget.ex` etc.) | Size docs corrected to match the real lattice/`min_size` values. |
| ~109 call sites across `lib/` | `Gettext.gettext(PhoenixKitWeb.Gettext, "...")` → the `gettext/1` macro idiom (compile-time extraction). |
| `priv/static/assets/phoenix_kit_dashboards.js`, `test/js/geom.test.cjs` | JS collision math (`rectsOverlap`/`fitSpan`) deduped, pinned against `Grid.fit_size/8` via a Node test harness. |

No schema or API-shape changes; this PR is refactor + bug fixes, described as behavior-preserving.

## Implementation Details

- **Packer split, not shared**: `Grid.compact/3` (reorder/duplicate-layout — must preserve a
  caller's stored `h`) and `Grid.pack/4` (`resolve_designed` — may reshape) briefly shared code
  during development; a multi-AI re-review caught the resulting regression (compact silently
  row-clamped/rewrote `h`) before merge. The shipped version keeps them separate, sharing only
  the genuine common primitive `Grid.slot/5`.
- **Gettext idiom conversion**: pure syntax change (verified: 99 unique msgids, identical
  multiset pre/post-PR). `Helpers.translate_catalog/1` is documented as the one exception
  (translates a runtime variable, which the compile-time macro can't take).

## Testing

- [x] Unit tests: `mix test` (DB-less) — 93 tests, 0 failures in this environment (146
      integration tests auto-exclude; no PostgreSQL available in this sandbox)
- [x] `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer,
      hex.audit) after round-3 fixes below
- Per the PR description: 237 tests / 0 failures with a local DB + core checkout, 4/4 Node JS
  geometry tests, browser-verified builder navigation

## Related

- Prior round 1/2 review docs (not in this directory's convention): `dev_docs/2026-07-16-code-review.md`,
  `dev_docs/2026-07-16-code-review-FOLLOWUP.md`
- Previous PR doc: [#3](/dev_docs/pull_requests/2026/3-screenful-lattice-and-live-sync)
- Round-3 findings: [CLAUDE_REVIEW.md](./CLAUDE_REVIEW.md)
