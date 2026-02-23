/**
 * Pure snap-to-guide resolution.
 * Returns the nearest guide position within threshold, or null.
 */
export function snapToGuides(
  value: number,
  guidePositions: number[],
  threshold: number,
): { snapped: number } | null {
  let best: number | null = null;
  let bestDist = Infinity;

  for (const pos of guidePositions) {
    const dist = Math.abs(value - pos);
    if (dist <= threshold && dist < bestDist) {
      best = pos;
      bestDist = dist;
    }
  }

  return best !== null ? { snapped: best } : null;
}
