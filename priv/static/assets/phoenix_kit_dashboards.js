// Prebuilt LiveView hooks for phoenix_kit_dashboards, declared via `js_sources/0`.
// Core's `:phoenix_kit_js_sources` compiler concatenates this (IIFE-wrapped) into
// the host's `phoenix_kit_modules.js` and folds `window.PhoenixKitDashboardsHooks`
// into `window.PhoenixKitHooks`, so the hooks are in the host LiveSocket at
// construction and resolve on LiveView navigation.
//
// All hooks are progressive enhancement — both dashboard types stay operable
// without JS via the Settings modal inputs / arrow nudges:
//   DashboardGridDrag  — grid cell placement (drag a widget to any free cell)
//   DashboardFreeDrag  — pixel-canvas move (left/top px)
//   DashboardResize    — corner resize (cells in grid, px in pixel mode)
//   DashboardGridFit / DashboardFreeFit / DashboardFullscreen / DashboardBreakpoint
//                      — fit-scaling, fullscreen and tier detection helpers
window.PhoenixKitDashboardsHooks = window.PhoenixKitDashboardsHooks || {};

(function () {
  "use strict";

  window.PhoenixKitDashboardsHooks.DashboardFreeDrag = {
    mounted() {
      var self = this;
      this._onDown = function (e) {
        // Ignore a second finger/pointer while a drag is already in flight — a
        // concurrent start would overwrite the live listener refs and leak them.
        if (self.card) return;
        // Primary button only — a right-click must open the context menu, not
        // start a drag that never sees its pointerup.
        if (e.button != null && e.button !== 0) return;
        // The whole top bar is the handle, but its buttons (settings/remove/
        // nudges) must stay buttons — a press on them never starts a drag.
        if (e.target.closest("button, a, input, select, textarea, label")) return;
        var handle = e.target.closest(".pk-free-handle");
        if (!handle || !self.el.contains(handle)) return;
        var card = handle.closest(".sortable-item");
        if (card) {
          e.preventDefault();
          self.startDrag(card, e);
        }
      };
      this.el.addEventListener("pointerdown", this._onDown);
    },

    destroyed() {
      if (this._onDown) this.el.removeEventListener("pointerdown", this._onDown);
      this.stopTracking();
    },

    startDrag(card, e) {
      var self = this;
      var rect = card.getBoundingClientRect();
      this.card = card;
      this.pointerId = e.pointerId;
      // Screen px per CSS px (free mode has a `zoom` on an ancestor; 1 otherwise).
      this.zoom = card.offsetWidth ? rect.width / card.offsetWidth : 1;
      // The card is absolutely positioned inside the canvas; offsetLeft/Top ARE
      // its fx/fy. Drag updates left/top directly — pixel-precise, never snapped.
      this.startLeft = card.offsetLeft;
      this.startTop = card.offsetTop;
      this.startClientX = e.clientX;
      this.startClientY = e.clientY;

      card.style.zIndex = "50";
      card.style.opacity = "0.85";
      card.style.transition = "none";

      this._onMove = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        var dx = (ev.clientX - self.startClientX) / self.zoom;
        var dy = (ev.clientY - self.startClientY) / self.zoom;
        card.style.left = Math.max(0, self.startLeft + dx) + "px";
        card.style.top = Math.max(0, self.startTop + dy) + "px";
      };
      this._onUp = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        self.endDrag(ev);
      };
      this._onCancel = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        self.cancelDrag();
      };
      document.addEventListener("pointermove", this._onMove);
      document.addEventListener("pointerup", this._onUp);
      document.addEventListener("pointercancel", this._onCancel);
    },

    endDrag(e) {
      var card = this.card;
      this.stopTracking();
      if (!card) return;

      var dx = (e.clientX - this.startClientX) / this.zoom;
      var dy = (e.clientY - this.startClientY) / this.zoom;
      var fx = Math.round(Math.max(0, this.startLeft + dx));
      var fy = Math.round(Math.max(0, this.startTop + dy));

      // Leave the card exactly where it was dropped (px). The server re-render
      // sets the same left/top, so nothing moves — no snap, no rubber-band.
      card.style.left = fx + "px";
      card.style.top = fy + "px";
      card.style.zIndex = "";
      card.style.opacity = "";
      card.style.transition = "";
      card.setAttribute("data-fx", fx);
      card.setAttribute("data-fy", fy);
      this.card = null;

      this.pushEvent("move_widget_to", { id: card.getAttribute("data-id"), fx: fx, fy: fy });
    },

    // Cancelled gesture: snap the card back to where it started + detach listeners.
    cancelDrag() {
      var card = this.card;
      this.stopTracking();
      if (!card) return;
      card.style.left = this.startLeft + "px";
      card.style.top = this.startTop + "px";
      card.style.zIndex = "";
      card.style.opacity = "";
      card.style.transition = "";
      this.card = null;
    },

    stopTracking() {
      if (this._onMove) document.removeEventListener("pointermove", this._onMove);
      if (this._onUp) document.removeEventListener("pointerup", this._onUp);
      if (this._onCancel) document.removeEventListener("pointercancel", this._onCancel);
      this._onMove = this._onUp = this._onCancel = null;
    },
  };

  // `DashboardResize` — per-card corner-drag resize (both grid + free modes).
  // During the drag the card is sized in raw pixels so it follows the cursor
  // freely; on release it snaps to the nearest whole cell and pushes the absolute
  // target span. The final placement is written client-side with the same values
  // the server will render, so the server re-render confirms it with no flicker.
  window.PhoenixKitDashboardsHooks.DashboardResize = {
    mounted() {
      var self = this;
      this._onDown = function (e) {
        // Ignore a concurrent pointer while a resize is already in flight (its
        // listener refs are live; a second start would overwrite and leak them).
        if (self._onMove) return;
        // Primary button only (same rationale as the drag hooks).
        if (e.button != null && e.button !== 0) return;
        var handle = e.target.closest(".pk-resize-handle");
        if (!handle || !self.el.contains(handle)) return;
        e.preventDefault();
        e.stopPropagation();
        self.startResize(e);
      };
      this.el.addEventListener("pointerdown", this._onDown);
    },

    destroyed() {
      if (this._onDown) this.el.removeEventListener("pointerdown", this._onDown);
      this.stopTracking();
    },

    intVal(name, fallback) {
      var v = parseInt(this.el.getAttribute(name), 10);
      return isNaN(v) ? fallback : v;
    },

    // CSS px for a span of `n` cells given per-cell stride + gap: n cells hold
    // (n-1) inner gaps → n*stride - gap.
    spanPx(n, stride, gap) {
      return n * stride - gap;
    },

    // The snapped + fitted cell size for a raw px request: nearest whole cells,
    // clamped to the widget's min/max — and to what FITS at the widget's cell
    // anchor (grid edge / nearest neighbour), mirroring the server's
    // Grid.fit_size so the preview, the final style, and the persisted result
    // all agree. Width fits first (at the pre-drag height), then height at the
    // fitted width.
    fitCells(wpx, hpx) {
      var w = Math.max(this.minW, Math.min(this.maxW, Math.round((wpx + this.gapX) / this.strideX)));
      var h = Math.max(this.minH, Math.min(this.maxH, Math.round((hpx + this.gapY) / this.strideY)));
      if (isNaN(this.gridX) || isNaN(this.gridY)) return { w: w, h: h };

      w = Math.min(w, this.cols - this.gridX);
      h = Math.min(h, 400 - this.gridY);
      var probeH = Math.min(this.startH, h);
      while (w > this.minW && this.cellsCollide(w, probeH)) w--;
      while (h > this.minH && this.cellsCollide(w, h)) h--;
      return { w: Math.max(w, 1), h: Math.max(h, 1) };
    },

    cellsCollide(w, h) {
      for (var i = 0; i < this.blockers.length; i++) {
        var b = this.blockers[i];
        if (
          this.gridX < b.x + b.w &&
          b.x < this.gridX + w &&
          this.gridY < b.y + b.h &&
          b.y < this.gridY + h
        ) {
          return true;
        }
      }
      return false;
    },

    // Highlight the whole-cell rectangle the widget will snap to (grid resize), so
    // it's clear where a free-dragging corner will land. Anchored at the card's grid
    // cell (offsetLeft/Top, so it scales with the fit transform) and labelled W × H.
    snapPreview(wpx, hpx) {
      var fitted = this.fitCells(wpx, hpx);
      var w = fitted.w;
      var h = fitted.h;

      var el = this.preview;
      if (!el) {
        el = document.createElement("div");
        el.setAttribute("aria-hidden", "true");
        el.style.cssText =
          "position:absolute;pointer-events:none;z-index:45;box-sizing:border-box;" +
          "border:2px dashed var(--color-primary,#6366f1);border-radius:0.5rem;" +
          "background:color-mix(in srgb, var(--color-primary,#6366f1) 14%, transparent);" +
          "color:var(--color-primary,#6366f1);font-size:11px;font-weight:600;line-height:1;" +
          "display:flex;align-items:flex-start;justify-content:flex-end;padding:3px 5px;";
        (this.el.parentElement || document.body).appendChild(el);
        this.preview = el;
      }

      el.style.left = this.el.offsetLeft + "px";
      el.style.top = this.el.offsetTop + "px";
      el.style.width = this.spanPx(w, this.strideX, this.gapX) + "px";
      el.style.height = this.spanPx(h, this.strideY, this.gapY) + "px";
      el.textContent = w + " × " + h;
    },

    clearSnapPreview() {
      if (this.preview) {
        this.preview.remove();
        this.preview = null;
      }
    },

    startResize(e) {
      var self = this;
      var card = this.el;
      var rect = card.getBoundingClientRect();
      var parent = card.parentElement;
      var pst = parent ? getComputedStyle(parent) : {};

      this.free = card.getAttribute("data-free") === "true";
      // Screen px per CSS px (accounts for free mode's `zoom`; 1 in grid mode).
      this.zoom = card.offsetWidth ? rect.width / card.offsetWidth : 1;
      this.pointerId = e.pointerId;
      this.startX = e.clientX;
      this.startY = e.clientY;
      this.startCssW = card.offsetWidth;
      this.startCssH = card.offsetHeight;
      // Clean, pre-mutation placement — restored verbatim on a cancelled gesture.
      this.origStyle = card.getAttribute("style") || "";

      if (this.free) {
        // Pixel canvas: size is free px within a sane range (the server clamps too).
        this.minPxW = this.minPxH = 60;
        this.maxPxW = this.maxPxH = 4000;
      } else {
        // Grid: snap targets are whole cells. Derive the exact per-cell stride
        // from the parent's gaps so the px<->cell conversion is accurate.
        this.startW = this.intVal("data-w", 4);
        this.startH = this.intVal("data-h", 2);
        this.minW = this.intVal("data-min-w", 1);
        this.maxW = this.intVal("data-max-w", 12);
        this.minH = this.intVal("data-min-h", 1);
        this.maxH = this.intVal("data-max-h", 8);
        this.gapX = parseFloat(pst.columnGap) || 0;
        this.gapY = parseFloat(pst.rowGap) || 0;
        this.strideX = this.startW ? (this.startCssW + this.gapX) / this.startW : this.startCssW || 1;
        this.strideY = this.startH ? (this.startCssH + this.gapY) / this.startH : this.startCssH || 1;
        this.minPxW = this.spanPx(this.minW, this.strideX, this.gapX);
        this.maxPxW = this.spanPx(this.maxW, this.strideX, this.gapX);
        this.minPxH = this.spanPx(this.minH, this.strideY, this.gapY);
        this.maxPxH = this.spanPx(this.maxH, this.strideY, this.gapY);
        // Explicit cell anchor + the other widgets' cells: the snap target must
        // GROW UNTIL BLOCKED by a neighbour or the grid edge (mirrors the
        // server's Grid.fit_size), and the final style keeps the x/y anchor.
        this.gridX = parseInt(card.getAttribute("data-x"), 10);
        this.gridY = parseInt(card.getAttribute("data-y"), 10);
        this.cols = parent ? parseInt(parent.getAttribute("data-cols"), 10) || 12 : 12;
        this.blockers = [];
        if (parent && !isNaN(this.gridX) && !isNaN(this.gridY)) {
          var sibs = parent.querySelectorAll(".sortable-item[data-id]");
          for (var i = 0; i < sibs.length; i++) {
            if (sibs[i] === card) continue;
            this.blockers.push({
              x: parseInt(sibs[i].getAttribute("data-x"), 10) || 0,
              y: parseInt(sibs[i].getAttribute("data-y"), 10) || 0,
              w: parseInt(sibs[i].getAttribute("data-w"), 10) || 1,
              h: parseInt(sibs[i].getAttribute("data-h"), 10) || 1
            });
          }
        }
      }

      card.style.zIndex = "40";
      card.style.transition = "none";
      card.classList.add("pk-resizing");

      this._onMove = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        var dxCss = (ev.clientX - self.startX) / self.zoom;
        var dyCss = (ev.clientY - self.startY) / self.zoom;
        var wpx = Math.max(self.minPxW, Math.min(self.maxPxW, self.startCssW + dxCss));
        var hpx = Math.max(self.minPxH, Math.min(self.maxPxH, self.startCssH + dyCss));
        card.style.width = wpx + "px";
        card.style.height = hpx + "px";
        // Grid: light up the cells the widget will snap to on release.
        if (!self.free) self.snapPreview(wpx, hpx);
      };
      this._onUp = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        self.endResize(ev);
      };
      this._onCancel = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        self.cancelResize();
      };
      document.addEventListener("pointermove", this._onMove);
      document.addEventListener("pointerup", this._onUp);
      document.addEventListener("pointercancel", this._onCancel);
    },

    endResize(e) {
      var card = this.el;
      this.stopTracking();

      var dxCss = (e.clientX - this.startX) / this.zoom;
      var dyCss = (e.clientY - this.startY) / this.zoom;
      var pxW = Math.round(Math.max(this.minPxW, Math.min(this.maxPxW, this.startCssW + dxCss)));
      var pxH = Math.round(Math.max(this.minPxH, Math.min(this.maxPxH, this.startCssH + dyCss)));

      // The final placement is written via the CSSOM, never by rewriting the
      // attribute string: once any hook touches `el.style.*`, the browser
      // re-serializes the whole inline style (Chrome collapses the spans into a
      // `grid-area:` shorthand) and LiveView won't restore the server string while
      // its rendered value is unchanged — so a string match on `grid-column:` can
      // miss, silently reverting the card to its old span until the server ack (a
      // visible rubber-band). Clear the drag-only overrides, set the new geometry.
      card.style.zIndex = "";
      card.style.transition = "";
      card.classList.remove("pk-resizing");

      if (this.free) {
        // Free canvas: keep the exact px size (no snap); left/top are untouched
        // (a bottom-right resize grows from the fixed top-left).
        card.style.width = pxW + "px";
        card.style.height = pxH + "px";
        card.setAttribute("data-fw", pxW);
        card.setAttribute("data-fh", pxH);
        this.pushEvent("resize_widget_to", { id: card.getAttribute("data-id"), fw: pxW, fh: pxH });
        return;
      }

      // Grid: snap to the nearest whole cell that FITS (fitCells — grid edge +
      // neighbours) and swap the drag's px size for the snapped span, keeping
      // the explicit x/y anchor.
      var fitted = this.fitCells(pxW, pxH);
      var w = fitted.w;
      var h = fitted.h;
      card.style.width = "";
      card.style.height = "";
      if (!isNaN(this.gridX) && !isNaN(this.gridY)) {
        card.style.gridColumn = this.gridX + 1 + " / span " + w;
        card.style.gridRow = this.gridY + 1 + " / span " + h;
      } else {
        card.style.gridColumn = "span " + w;
        card.style.gridRow = "span " + h;
      }
      card.setAttribute("data-w", w);
      card.setAttribute("data-h", h);

      this.pushEvent("resize_widget_to", { id: card.getAttribute("data-id"), w: w, h: h });
    },

    // Cancelled gesture (e.g. touch interrupted): restore the pre-drag placement
    // and drop all listeners rather than leave the card stuck at a pixel size.
    cancelResize() {
      this.stopTracking();
      this.el.setAttribute("style", this.origStyle || "");
      this.el.classList.remove("pk-resizing");
    },

    stopTracking() {
      this.clearSnapPreview();
      if (this._onMove) document.removeEventListener("pointermove", this._onMove);
      if (this._onUp) document.removeEventListener("pointerup", this._onUp);
      if (this._onCancel) document.removeEventListener("pointercancel", this._onCancel);
      this._onMove = this._onUp = this._onCancel = null;
    },
  };

  // `DashboardGridDrag` — explicit cell placement for GRID dashboards: grab a
  // widget by its `.pk-drag-handle` and drop it on any cell (gaps are fine —
  // that's the point of the grid type). A floating clone follows the cursor
  // while the widget itself jumps cell-to-cell under it as a live, cell-snapped
  // preview — but only through FREE cells (occupancy is checked against every
  // other widget's data-x/-y/-w/-h, which mirror the server's placements), so
  // the shown spot is always a legal one and the drop always matches the
  // preview. On drop it pushes `move_widget_grid` with the final cells; the
  // widget's style is already the server format, so the ack confirms with no
  // flicker. Cell math derives from the live grid metrics (data-cols +
  // computed gaps/auto-rows) and getBoundingClientRect, so it's correct under
  // the fit `transform: scale`.
  window.PhoenixKitDashboardsHooks.DashboardGridDrag = {
    mounted() {
      var self = this;
      // The LV pushes `sortable:flash` after a (legacy) reorder attempt (the
      // same contract core's SortableGrid uses — that hook isn't mounted here,
      // so this one answers it): pulse the moved card green/red.
      this.handleEvent("sortable:flash", function (payload) {
        if (!payload || !payload.uuid) return;
        var card = self.el.querySelector('.sortable-item[data-id="' + payload.uuid + '"]');
        if (!card || typeof card.animate !== "function") return;
        var color =
          payload.status === "ok"
            ? "rgba(34, 197, 94, 0.35)"
            : payload.status === "error"
              ? "rgba(239, 68, 68, 0.35)"
              : null;
        if (!color) return;
        card.animate(
          { backgroundColor: ["rgba(0, 0, 0, 0)", color, "rgba(0, 0, 0, 0)"] },
          { duration: 1100, easing: "ease-out" }
        );
      });
      this._onDown = function (e) {
        if (self.item) return;
        if (e.button != null && e.button !== 0) return;
        // The whole top bar is the handle, but its buttons (settings/remove)
        // must stay buttons — a press on them never starts a drag.
        if (e.target.closest("button, a, input, select, textarea, label")) return;
        var handle = e.target.closest(".pk-drag-handle");
        if (!handle) return;
        var item = handle.closest(".sortable-item[data-id]");
        if (!item || !self.el.contains(item)) return;
        e.preventDefault();
        self.startDrag(e, item);
      };
      this.el.addEventListener("pointerdown", this._onDown);
    },

    destroyed() {
      if (this._onDown) this.el.removeEventListener("pointerdown", this._onDown);
      this.finish();
    },

    intVal(el, name, fallback) {
      var v = parseInt(el.getAttribute(name), 10);
      return isNaN(v) ? fallback : v;
    },

    // Per-cell stride + scale from the live grid, so cell math holds at any
    // fit-zoom and column count.
    metrics() {
      var cs = getComputedStyle(this.el);
      var cols = this.intVal(this.el, "data-cols", 12);
      var gapX = parseFloat(cs.columnGap) || 0;
      var gapY = parseFloat(cs.rowGap) || 0;
      var rowH = parseFloat(cs.gridAutoRows) || 128;
      var colW = (this.el.offsetWidth - (cols - 1) * gapX) / cols;
      var rect = this.el.getBoundingClientRect();
      return {
        cols: cols,
        strideX: colW + gapX,
        strideY: rowH + gapY,
        scale: this.el.offsetWidth ? rect.width / this.el.offsetWidth : 1
      };
    },

    startDrag(e, item) {
      var self = this;
      this.item = item;
      this.pointerId = e.pointerId;
      this.m = this.metrics();
      this.w = this.intVal(item, "data-w", 4);
      this.h = this.intVal(item, "data-h", 2);
      this.origin = { x: this.intVal(item, "data-x", 0), y: this.intVal(item, "data-y", 0) };
      this.pos = { x: this.origin.x, y: this.origin.y };
      this.origStyle = item.getAttribute("style") || "";

      // Cell occupancy of every OTHER widget (server renders data-x/-y on all).
      this.blockers = [];
      var sibs = this.el.querySelectorAll(".sortable-item[data-id]");
      for (var i = 0; i < sibs.length; i++) {
        if (sibs[i] === item) continue;
        this.blockers.push({
          x: this.intVal(sibs[i], "data-x", 0),
          y: this.intVal(sibs[i], "data-y", 0),
          w: this.intVal(sibs[i], "data-w", 1),
          h: this.intVal(sibs[i], "data-h", 1)
        });
      }

      var rect = item.getBoundingClientRect();
      this.grabDX = e.clientX - rect.left;
      this.grabDY = e.clientY - rect.top;

      // Floating drag image: a copy sized to the on-screen (possibly fit-scaled)
      // widget, following the cursor — immediate, obvious "picked up" feedback.
      var clone = item.cloneNode(true);
      clone.removeAttribute("id");
      clone.removeAttribute("phx-hook");
      clone.classList.remove("sortable-item");
      clone.style.cssText =
        "position:fixed;margin:0;box-sizing:border-box;pointer-events:none;z-index:9999;left:" +
        rect.left +
        "px;top:" +
        rect.top +
        "px;width:" +
        rect.width +
        "px;height:" +
        rect.height +
        "px;opacity:.92;box-shadow:0 14px 34px rgba(0,0,0,.28);border-radius:.5rem;" +
        "transform:none;transition:none;cursor:grabbing;";
      document.body.appendChild(clone);
      this.clone = clone;

      // The clone is a static snapshot, but the original stays LiveView-managed
      // and keeps updating mid-drag (a clock ticks every second) — mirror those
      // updates into the clone so the copy in your hand doesn't visibly freeze
      // at grab-time while the drop placeholder ticks on.
      if (typeof MutationObserver === "function") {
        this._mirror = new MutationObserver(function () {
          if (self.clone && self.item) self.clone.innerHTML = self.item.innerHTML;
        });
        this._mirror.observe(item, {
          childList: true,
          subtree: true,
          characterData: true,
          attributes: true
        });
      }

      // The widget itself is the live drop preview — dimmed + dashed while it
      // tracks the drag cell-by-cell.
      item.style.opacity = "0.35";
      item.style.outline = "2px dashed var(--color-primary,#6366f1)";
      item.style.outlineOffset = "-2px";
      item.style.borderRadius = ".5rem";
      item.style.transition = "none";

      document.body.style.userSelect = "none";
      document.body.style.cursor = "grabbing";
      try {
        this.el.setPointerCapture(e.pointerId);
      } catch (_e) {}

      this._onMove = function (ev) {
        if (ev.pointerId !== self.pointerId) return;
        ev.preventDefault();
        self.clone.style.left = ev.clientX - self.grabDX + "px";
        self.clone.style.top = ev.clientY - self.grabDY + "px";
        self.track();
      };
      this._onUp = function (ev) {
        if (ev.pointerId === self.pointerId) self.drop();
      };
      this._onCancel = function (ev) {
        if (ev.pointerId === self.pointerId) self.cancel();
      };
      document.addEventListener("pointermove", this._onMove, { passive: false });
      document.addEventListener("pointerup", this._onUp);
      document.addEventListener("pointercancel", this._onCancel);
    },

    collides(x, y) {
      for (var i = 0; i < this.blockers.length; i++) {
        var b = this.blockers[i];
        if (x < b.x + b.w && b.x < x + this.w && y < b.y + b.h && b.y < y + this.h) return true;
      }
      return false;
    },

    // The cell under the CLONE's top-left corner (the box the user is placing),
    // in unscaled grid coordinates. The preview only moves onto a legal spot:
    // in-bounds and collision-free — otherwise it stays at the last valid cell,
    // so what you see is always exactly what a drop commits.
    track() {
      var gridRect = this.el.getBoundingClientRect();
      var cloneRect = this.clone.getBoundingClientRect();
      var cssLeft = (cloneRect.left - gridRect.left) / this.m.scale;
      var cssTop = (cloneRect.top - gridRect.top) / this.m.scale;

      var tx = Math.round(cssLeft / this.m.strideX);
      var ty = Math.round(cssTop / this.m.strideY);
      tx = Math.max(0, Math.min(this.m.cols - this.w, tx));
      // Mirror the server's row cap (Grid.max_rows).
      ty = Math.max(0, Math.min(400 - this.h, ty));

      if ((tx !== this.pos.x || ty !== this.pos.y) && !this.collides(tx, ty)) {
        this.pos = { x: tx, y: ty };
        this.item.style.gridColumn = tx + 1 + " / span " + this.w;
        this.item.style.gridRow = ty + 1 + " / span " + this.h;
      }
    },

    drop() {
      var item = this.item;
      var moved = item && (this.pos.x !== this.origin.x || this.pos.y !== this.origin.y);
      var pos = this.pos;
      this.finish();
      if (!item || !moved) return;
      item.setAttribute("data-x", pos.x);
      item.setAttribute("data-y", pos.y);
      this.pushEvent("move_widget_grid", { id: item.getAttribute("data-id"), x: pos.x, y: pos.y });
    },

    // Cancelled gesture: back to the pre-drag placement.
    cancel() {
      var item = this.item;
      var origStyle = this.origStyle;
      this.finish();
      if (item) item.setAttribute("style", origStyle);
    },

    finish() {
      if (this._mirror) {
        this._mirror.disconnect();
        this._mirror = null;
      }
      if (this.clone) {
        this.clone.remove();
        this.clone = null;
      }
      if (this.item) {
        // Keep the (possibly moved) grid placement; drop only the drag styling.
        this.item.style.opacity = "";
        this.item.style.outline = "";
        this.item.style.outlineOffset = "";
        this.item.style.borderRadius = "";
        this.item.style.transition = "";
        try {
          this.el.releasePointerCapture(this.pointerId);
        } catch (_e) {}
        this.item = null;
      }
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      if (this._onMove) document.removeEventListener("pointermove", this._onMove);
      if (this._onUp) document.removeEventListener("pointerup", this._onUp);
      if (this._onCancel) document.removeEventListener("pointercancel", this._onCancel);
      this._onMove = this._onUp = this._onCancel = null;
    }
  };


  // `DashboardFreeFit` — scales the free canvas to FILL the available width
  // (fit-to-width), times an optional manual `data-zoom` multiplier. Vertical
  // overflow scrolls. Uses `transform: scale` (not CSS `zoom`) so the drag/resize
  // hooks' `rect.width / offsetWidth` still reads the exact scale. A `.pk-free-spacer`
  // sized to the scaled canvas gives the scroll area its extent.
  window.PhoenixKitDashboardsHooks.DashboardFreeFit = {
    mounted() {
      var self = this;
      // A ResizeObserver re-fits whenever the container's width changes — viewport,
      // sidebar, or catalog toggle (a flex reflow). `scrollbar-gutter: stable` on
      // the container keeps its width stable, so fit()'s child changes can't feed
      // back into a resize loop. A window `resize` listener is a belt-and-suspenders
      // fallback; `updated()` covers logical-dim changes from widget moves.
      if (typeof ResizeObserver === "function") {
        this._ro = new ResizeObserver(function () {
          self.fit();
        });
        this._ro.observe(this.el);
      }
      this._onResize = function () {
        self.fit();
      };
      window.addEventListener("resize", this._onResize);
      this.fit();
    },

    updated() {
      this.fit();
    },

    destroyed() {
      if (this._ro) this._ro.disconnect();
      window.removeEventListener("resize", this._onResize);
    },

    fit() {
      var canvas = this.el.querySelector(".pk-free-canvas");
      var spacer = this.el.querySelector(".pk-free-spacer");
      if (!canvas || !spacer) return;

      var contentW = parseFloat(canvas.getAttribute("data-logical-width")) || canvas.offsetWidth;
      var logicalH = parseFloat(canvas.getAttribute("data-logical-height")) || canvas.offsetHeight;
      if (!contentW || !logicalH) return;

      var cs = getComputedStyle(this.el);
      var pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
      var avail = this.el.clientWidth - pad;
      if (avail <= 0) return;

      var manual = parseFloat(this.el.getAttribute("data-zoom")) || 100;
      // The canvas is at least as wide as the container, so an empty / narrow
      // layout sits at natural size (scale 1) instead of pre-shrunk; only a layout
      // that extends past the container width scales down to fit.
      var designW = Math.max(contentW, avail);
      canvas.style.width = designW + "px";

      var scale = (avail / designW) * (manual / 100);
      canvas.style.transformOrigin = "top left";
      canvas.style.transform = "scale(" + scale + ")";
      // The scaled canvas is position:absolute (out of flow); the spacer carries
      // the scaled dimensions so the container scrolls to fit it.
      spacer.style.width = designW * scale + "px";
      spacer.style.height = logicalH * scale + "px";
      // Reveal only once scaled, so the pre-fit (unscaled) frame never flashes.
      canvas.style.opacity = "1";
    },
  };

  // `DashboardGridFit` — lays the grid out at its design width (`data-design-width`)
  // and scales it via transform to fit the available space: shrink-to-fit normally,
  // FILL when fullscreen (a TV). Editable at any scale — SortableJS + the resize hook
  // are transform-aware. Re-fits on resize / fullscreen change (both fire the RO).
  window.PhoenixKitDashboardsHooks.DashboardGridFit = {
    mounted() {
      var self = this;
      this._ro = new ResizeObserver(function () {
        self.fit();
      });
      this._ro.observe(this.el);
      this._onResize = function () {
        self.fit();
      };
      window.addEventListener("resize", this._onResize);
      this.fit();
    },

    updated() {
      this.fit();
    },

    destroyed() {
      if (this._ro) this._ro.disconnect();
      window.removeEventListener("resize", this._onResize);
    },

    fit() {
      var canvas = this.el.querySelector(".pk-grid-scale-canvas");
      var spacer = this.el.querySelector(".pk-grid-scale-spacer");
      if (!canvas || !spacer) return;

      var designW = parseFloat(this.el.getAttribute("data-design-width")) || canvas.offsetWidth;
      if (!designW) return;

      var cs = getComputedStyle(this.el);
      var pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
      var avail = this.el.clientWidth - pad;
      if (avail <= 0) return;

      // In fullscreen the design fills the screen (can scale up); otherwise shrink
      // to fit and never blow a small design up past 1:1.
      var fullscreen = document.fullscreenElement && document.fullscreenElement.contains(this.el);
      var scale = fullscreen ? avail / designW : Math.min(1, avail / designW);

      canvas.style.transformOrigin = "top left";
      canvas.style.transform = "scale(" + scale + ")";
      // offsetHeight is the UNSCALED layout height (transform doesn't affect it);
      // the spacer carries the scaled dims so the container scrolls + centers.
      spacer.style.width = designW * scale + "px";
      spacer.style.height = canvas.offsetHeight * scale + "px";
      canvas.style.opacity = "1";
    },
  };

  // `DashboardFullscreen` — a button that toggles native fullscreen on its
  // `data-target` element (the grid fit container), so the current view fills a TV
  // (or a phone in landscape). A fullscreenchange nudges a resize so DashboardGridFit
  // re-fits (fills) at the new size. Must run in the click gesture (browser rule).
  window.PhoenixKitDashboardsHooks.DashboardFullscreen = {
    mounted() {
      var self = this;
      this._onClick = function () {
        var target = document.getElementById(self.el.getAttribute("data-target"));
        if (document.fullscreenElement) {
          document.exitFullscreen();
        } else if (target && target.requestFullscreen) {
          target.requestFullscreen().catch(function () {});
        }
      };
      this.el.addEventListener("click", this._onClick);
      this._onFsChange = function () {
        window.dispatchEvent(new Event("resize"));
      };
      document.addEventListener("fullscreenchange", this._onFsChange);
    },

    destroyed() {
      if (this._onClick) this.el.removeEventListener("click", this._onClick);
      if (this._onFsChange) document.removeEventListener("fullscreenchange", this._onFsChange);
    },
  };

  // `DashboardBreakpoint` — on connect, matches the viewport width against the tier
  // thresholds (from `data-breakpoints`, ordered largest→smallest) and pushes
  // `detect_bp` ONCE so a grid dashboard opens at the tier that best fits the screen
  // and stays there. The grid is hidden until this settles, so no wrong-tier flash.
  window.PhoenixKitDashboardsHooks.DashboardBreakpoint = {
    mounted() {
      var tiers = [];
      try {
        tiers = JSON.parse(this.el.getAttribute("data-breakpoints") || "[]");
      } catch (e) {
        tiers = [];
      }

      var w = window.innerWidth;
      var bp = tiers.length ? tiers[tiers.length - 1].k : null;
      for (var i = 0; i < tiers.length; i++) {
        if (w >= tiers[i].w) {
          bp = tiers[i].k;
          break;
        }
      }

      if (bp) this.pushEvent("detect_bp", { bp: bp });
    },
  };
})();
