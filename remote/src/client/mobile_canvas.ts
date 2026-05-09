export const CANVAS_PAN_TAP_THRESHOLD = 8;

export type CanvasPoint = {
  x: number;
  y: number;
};

export type CanvasSize = {
  width: number;
  height: number;
};

export function clampCanvasPan(pan: CanvasPoint, viewport: CanvasSize, canvas: CanvasSize): CanvasPoint {
  const minX = Math.min(0, viewport.width - canvas.width);
  const minY = Math.min(0, viewport.height - canvas.height);
  return {
    x: clamp(pan.x, minX, 0),
    y: clamp(pan.y, minY, 0),
  };
}

export function defaultCanvasPan(viewport: CanvasSize, canvas: CanvasSize): CanvasPoint {
  return clampCanvasPan({ x: 0, y: viewport.height - canvas.height }, viewport, canvas);
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

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
