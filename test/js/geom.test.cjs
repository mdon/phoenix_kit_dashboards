"use strict";

// Unit tests for the pure cell geometry in the hook bundle
// (priv/static/assets/phoenix_kit_dashboards.js). The bundle is browser code
// (an IIFE that assigns hooks to `window`), so stub `window` before requiring
// it — only `window` is touched at load; the DOM-using hook methods aren't
// called. The bundle exports its pure functions via `module.exports` when Node
// is present.

const test = require("node:test");
const assert = require("node:assert/strict");

global.window = { PhoenixKitDashboardsHooks: {} };
const { rectsOverlap, fitSpan } = require("../../priv/static/assets/phoenix_kit_dashboards.js");

test("rectsOverlap: overlap and clear separation", () => {
  const others = [{ x: 2, y: 0, w: 4, h: 2 }];
  assert.equal(rectsOverlap(0, 0, 4, 2, others), true); // overlaps [2,6)×[0,2)
  assert.equal(rectsOverlap(6, 0, 4, 2, others), false); // edge-adjacent, clear
  assert.equal(rectsOverlap(2, 2, 4, 2, others), false); // directly below, clear
  assert.equal(rectsOverlap(0, 0, 4, 2, []), false); // no blockers
});

// These cases mirror grid_test.exs's Grid.fit_size/8 tests one-for-one — if the
// client `fitSpan` and the server `Grid.fit_size` ever drift, the drop stops
// matching the preview, and these shared expected values catch it.
test("fitSpan mirrors Grid.fit_size: grows freely, clamped to the grid edge", () => {
  // fit_size(2,0,8,5, ...) with no neighbours -> {8,5}
  assert.deepEqual(fitSpan(8, 5, 2, 0, 12, 160, 1, 1, 2, []), { w: 8, h: 5 });
  // width past the right edge stops at cols - x = 10
  assert.deepEqual(fitSpan(16, 5, 2, 0, 12, 160, 1, 1, 2, []), { w: 10, h: 5 });
});

test("fitSpan mirrors Grid.fit_size: grows until blocked by a neighbour", () => {
  // neighbour at x=6 on the same rows -> width stops at 6
  assert.deepEqual(
    fitSpan(10, 2, 0, 0, 12, 160, 1, 1, 2, [{ x: 6, y: 0, w: 4, h: 4 }]),
    { w: 6, h: 2 }
  );
  // neighbour below at y=3 -> height stops at 3
  assert.deepEqual(
    fitSpan(4, 6, 0, 0, 12, 160, 1, 1, 2, [{ x: 0, y: 3, w: 4, h: 2 }]),
    { w: 4, h: 3 }
  );
});

test("fitSpan never returns below 1×1", () => {
  const r = fitSpan(0, 0, 0, 0, 12, 160, 1, 1, 1, []);
  assert.ok(r.w >= 1 && r.h >= 1);
});
