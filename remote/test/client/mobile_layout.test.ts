import test from "node:test";
import assert from "node:assert/strict";

import {
  MOBILE_REMOTE_MEDIA_QUERY,
  fitModeForSurface,
  shouldUseCanvasPan,
  shouldUseViewportFit,
} from "../../src/client/mobile_layout";

test("mobile media query matches the responsive CSS breakpoint", () => {
  assert.equal(
    MOBILE_REMOTE_MEDIA_QUERY,
    "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)",
  );
});

test("fitModeForSurface uses viewport fitting when remote dimensions are unknown", () => {
  assert.equal(fitModeForSurface(false), "viewport");
});

test("fitModeForSurface preserves remote-grid sizing when dimensions are known", () => {
  assert.equal(fitModeForSurface(true), "remote-grid");
});

test("shouldUseViewportFit is true only when remote grid dimensions are unknown", () => {
  assert.equal(shouldUseViewportFit(false), true);
  assert.equal(shouldUseViewportFit(true), false);
});

test("mobile rendering keeps remote grid dimensions", () => {
  assert.equal(shouldUseViewportFit(true), false);
});

test("desktop remote-grid surfaces keep canvas panning enabled", () => {
  const desktopWindow = {
    matchMedia: () => ({ matches: false }),
  } as Pick<Window, "matchMedia">;

  assert.equal(shouldUseCanvasPan(true, desktopWindow), true);
  assert.equal(shouldUseCanvasPan(false, desktopWindow), false);
});
