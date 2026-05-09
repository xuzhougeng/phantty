import test from "node:test";
import assert from "node:assert/strict";

import {
  CANVAS_PAN_TAP_THRESHOLD,
  clampCanvasPan,
  defaultCanvasPan,
  isCanvasDrag,
  panCanvasBy,
  panCanvasByWheel,
} from "../../src/client/mobile_canvas";

test("clampCanvasPan keeps an oversized canvas inside the viewport", () => {
  assert.deepEqual(
    clampCanvasPan({ x: -900, y: -500 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
  assert.deepEqual(
    clampCanvasPan({ x: 80, y: 60 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: 0 },
  );
});

test("clampCanvasPan disables panning when the canvas fits", () => {
  assert.deepEqual(
    clampCanvasPan({ x: -20, y: -20 }, { width: 900, height: 900 }, { width: 390, height: 500 }),
    { x: 0, y: 0 },
  );
});

test("defaultCanvasPan starts at the bottom-left of an oversized terminal canvas", () => {
  assert.deepEqual(
    defaultCanvasPan({ width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: -400 },
  );
});

test("panCanvasBy accumulates drag deltas and clamps to available canvas", () => {
  assert.deepEqual(
    panCanvasBy({ x: 0, y: 0 }, { x: -220, y: -180 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -220, y: -180 },
  );
  assert.deepEqual(
    panCanvasBy({ x: -480, y: -350 }, { x: -80, y: -100 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
});

test("panCanvasByWheel maps wheel deltas to terminal canvas movement", () => {
  assert.deepEqual(
    panCanvasByWheel({ x: 0, y: 0 }, { x: 0, y: 180 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: -180 },
  );
  assert.deepEqual(
    panCanvasByWheel({ x: -480, y: -350 }, { x: 80, y: 100 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
});

test("isCanvasDrag distinguishes tap jitter from canvas drag", () => {
  assert.equal(isCanvasDrag({ x: CANVAS_PAN_TAP_THRESHOLD - 1, y: 0 }), false);
  assert.equal(isCanvasDrag({ x: CANVAS_PAN_TAP_THRESHOLD + 1, y: 0 }), true);
});
