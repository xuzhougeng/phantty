export const CANVAS_PAN_TAP_THRESHOLD = 8;

export type CanvasPoint = {
  x: number;
  y: number;
};

export type CanvasSize = {
  width: number;
  height: number;
};

export type CanvasPanOptions = {
  bottomGutter?: number;
};

export type ResizeCanvasPanOptions = CanvasPanOptions & {
  pan: CanvasPoint;
  previousViewport: CanvasSize | null;
  viewport: CanvasSize;
  canvas: CanvasSize;
};

export type CanvasPanDragInput = {
  mobile: boolean;
  isPrimary: boolean;
  button: number;
};

export type CanvasWheelInput = {
  mobile: boolean;
  useCanvasPan: boolean;
};

export type CanvasScrollbarOptions = CanvasPanOptions & {
  minThumbHeight?: number;
};

export type CanvasScrollbarMetrics = {
  visible: boolean;
  trackHeight: number;
  thumbTop: number;
  thumbHeight: number;
};

export type MeaningfulTerminalCanvasHeightInput = {
  measuredHeight: number;
  rows: number;
  cursorY: number;
  lastNonBlankRow: number;
};

export const CANVAS_WHEEL_EVENT_OPTIONS: AddEventListenerOptions = {
  capture: true,
  passive: false,
};

const BOTTOM_ANCHOR_EPSILON = 24;

export function clampCanvasPan(
  pan: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
  options: CanvasPanOptions = {},
): CanvasPoint {
  const minX = Math.min(0, viewport.width - canvas.width);
  const minY = bottomPanLimit(viewport, canvas, options);
  return {
    x: clamp(pan.x, minX, 0),
    y: clamp(pan.y, minY, 0),
  };
}

export function defaultCanvasPan(
  viewport: CanvasSize,
  canvas: CanvasSize,
  options: CanvasPanOptions = {},
): CanvasPoint {
  return clampCanvasPan({ x: 0, y: bottomPanLimit(viewport, canvas, options) }, viewport, canvas, options);
}

export function resizeCanvasPan(options: ResizeCanvasPanOptions): CanvasPoint {
  const clamped = clampCanvasPan(options.pan, options.viewport, options.canvas, options);
  if (!shouldKeepBottomAnchored(options)) return clamped;

  return {
    x: clamped.x,
    y: defaultCanvasPan(options.viewport, options.canvas, options).y,
  };
}

export function panCanvasBy(
  startPan: CanvasPoint,
  delta: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
): CanvasPoint {
  return clampCanvasPan(
    {
      x: startPan.x + delta.x,
      y: startPan.y + delta.y,
    },
    viewport,
    canvas,
  );
}

export function panCanvasByWheel(
  startPan: CanvasPoint,
  delta: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
): CanvasPoint {
  return panCanvasBy(startPan, { x: -delta.x, y: -delta.y }, viewport, canvas);
}

export function isCanvasDrag(delta: CanvasPoint): boolean {
  return Math.hypot(delta.x, delta.y) > CANVAS_PAN_TAP_THRESHOLD;
}

export function shouldStartCanvasPanDrag(input: CanvasPanDragInput): boolean {
  if (!input.isPrimary) return false;
  return input.mobile ? input.button === 0 : input.button === 1;
}

export function shouldConsumeCanvasWheel(input: CanvasWheelInput): boolean {
  return !input.mobile && input.useCanvasPan;
}

export function verticalScrollbarMetrics(
  pan: CanvasPoint,
  viewport: CanvasSize,
  canvas: CanvasSize,
  trackHeight: number,
  options: CanvasScrollbarOptions = {},
): CanvasScrollbarMetrics {
  const normalizedTrackHeight = Math.max(0, Math.round(trackHeight));
  const bottomGutter = Math.max(0, options.bottomGutter ?? 0);
  const contentHeight = canvas.height + bottomGutter;
  const minPanY = bottomPanLimit(viewport, canvas, options);
  const scrollRange = Math.abs(minPanY);
  const minThumbHeight = Math.max(8, options.minThumbHeight ?? 32);

  if (normalizedTrackHeight <= 0 || contentHeight <= viewport.height || scrollRange <= 0) {
    return {
      visible: false,
      trackHeight: normalizedTrackHeight,
      thumbTop: 0,
      thumbHeight: normalizedTrackHeight,
    };
  }

  const thumbHeight = Math.min(
    normalizedTrackHeight,
    Math.max(minThumbHeight, Math.round((viewport.height / contentHeight) * normalizedTrackHeight)),
  );
  const thumbTravel = Math.max(0, normalizedTrackHeight - thumbHeight);
  const progress = clamp(-clampCanvasPan(pan, viewport, canvas, options).y / scrollRange, 0, 1);

  return {
    visible: true,
    trackHeight: normalizedTrackHeight,
    thumbTop: Math.round(progress * thumbTravel),
    thumbHeight,
  };
}

export function panYFromVerticalScrollbarThumb(
  thumbTop: number,
  trackHeight: number,
  viewport: CanvasSize,
  canvas: CanvasSize,
  options: CanvasScrollbarOptions = {},
): number {
  const metrics = verticalScrollbarMetrics({ x: 0, y: 0 }, viewport, canvas, trackHeight, options);
  if (!metrics.visible) return 0;

  const thumbTravel = Math.max(1, metrics.trackHeight - metrics.thumbHeight);
  const progress = clamp(thumbTop / thumbTravel, 0, 1);
  return Math.round(bottomPanLimit(viewport, canvas, options) * progress);
}

export function meaningfulTerminalCanvasHeight(input: MeaningfulTerminalCanvasHeightInput): number {
  const measuredHeight = Math.max(0, input.measuredHeight);
  const rows = Math.max(0, Math.floor(input.rows));
  if (measuredHeight <= 0 || rows <= 0) return measuredHeight;

  const rowHeight = measuredHeight / rows;
  if (!Number.isFinite(rowHeight) || rowHeight <= 0) return measuredHeight;

  const maxRow = rows - 1;
  const meaningfulRow = clamp(Math.max(input.cursorY, input.lastNonBlankRow, 0), 0, maxRow);
  return Math.min(measuredHeight, Math.ceil((meaningfulRow + 1) * rowHeight));
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function bottomPanLimit(viewport: CanvasSize, canvas: CanvasSize, options: CanvasPanOptions): number {
  const bottomGutter = Math.max(0, options.bottomGutter ?? 0);
  return Math.min(0, viewport.height - canvas.height - bottomGutter);
}

function shouldKeepBottomAnchored(options: ResizeCanvasPanOptions): boolean {
  if (!options.previousViewport) return true;
  const previousBottom = bottomPanLimit(options.previousViewport, options.canvas, options);
  const previousCanvasFit =
    options.canvas.height + Math.max(0, options.bottomGutter ?? 0) <= options.previousViewport.height;
  return previousCanvasFit || Math.abs(options.pan.y - previousBottom) <= BOTTOM_ANCHOR_EPSILON;
}
