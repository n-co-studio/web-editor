import { useEffect, useId, useMemo, useRef } from 'react';
import { createNoise2D } from 'simplex-noise';
import styles from './LavaBackground.module.css';

/* ------------------------------------------------------------------------ *
 * Lava gradient — configuration
 *
 * Each colour becomes one irregular, organically-morphing blob (NOT a circle):
 * its outline is a closed spline whose points bulge and recede over time, so
 * the shape is asymmetric at rest and continuously reshapes like a lava lamp.
 * Blobs drift across the canvas, merge at their edges with their neighbours
 * (metaball / gooey filter), and blend colour where fields meet. Each is
 * seeded to its own region so they float and merge without fully stacking.
 *
 * Edit LAVA_CONFIG below to control the look. Nothing else needs to change.
 * ------------------------------------------------------------------------ */
/** One horizontal bundle of a wide multi-region lava field. */
export interface LavaRegion {
  colors: string[];
  /** Keys the bundle's blob layout/motion (defaults to its position). */
  seed?: number;
}

export interface LavaConfig {
  /** Wash painted behind the blobs. A dark value makes the colours glow. */
  background: string;
  /** One blob is created per colour. 3–6 colours reads best. */
  colors: string[];
  /**
   * How overlapping blobs mix. SVG has no z-index — blobs paint in array order —
   * so with 'normal' the last colour sits on top and looks dominant. 'screen'
   * (or 'lighten') blends overlaps so every colour reads evenly, order-free.
   */
  blend: 'normal' | 'screen' | 'lighten' | 'plus-lighter' | 'multiply' | 'darken';
  /** Blob softness — SVG blur radius in viewBox units. Higher = softer, more blended. */
  blur: number;
  /** Base blob size in viewBox units (canvas is 100×100). Larger = more overlap/merging. */
  size: number;
  /** Outline resolution — control points per blob. 6–9 gives smooth lava lobes. */
  points: number;
  /** Baseline lumpiness of the resting shape (0 = circle, 0.5 = very irregular). */
  irregularity: number;
  /** How much the outline pulses/reshapes over time (0 = rigid, ~0.3 = liquid). */
  morph: number;
  /** Drift speed of the whole shape across the canvas. */
  speed: number;
  /** How far a blob wanders from its home region, in viewBox units. */
  drift: number;
  /** Enable subtle cursor tracking on pointer-capable (desktop) devices. */
  pointerTracking: boolean;
  /** Max distance a blob leans toward the cursor, in viewBox units. 0 disables it. */
  pointerStrength: number;
  /** When true the blobs lean AWAY from the cursor instead of toward it. */
  pointerRepel?: boolean;
  /** Opacity of the whole blob field (0–1). Applied AFTER the gooey filter so it
      fades the metaballs without breaking the alpha-crush that forms them. */
  blobOpacity?: number;
  /**
   * Layout seed. Two instances with the same colours but different seeds place
   * and morph their blobs independently (rotated ring + offset noise tracks)
   * instead of sharing one deterministic layout. Defaults to 0.
   */
  seed?: number;
  /**
   * Hover-scatter (ported from the nco.studio landing page). When
   * `scatterEase` is set, any `[data-lava-scatter]` element inside the field's
   * `[data-lava-scope]` ancestor sends every blob out to the canvas edge while
   * it is hovered or keyboard-focused, clearing the middle. Omit these and the
   * behaviour — and its listeners — are never attached.
   *
   * Each blob's centre lands this many CSS pixels in from the edge, a fresh
   * random value per blob per hover.
   */
  scatterInsetMin?: number;
  scatterInsetMax?: number;
  /** Blob radius multiplier while scattered — a slight loosening of the field. */
  scatterScale?: number;
  /** Per-frame easing toward/away from the scattered layout (0–1). ~0.011 ≈ 3–4s. */
  scatterEase?: number;
  /**
   * Wide multi-bundle layout. When set, the canvas is `regions.length` VB-units
   * wide (rendered with preserveAspectRatio="none" so each bundle maps to its
   * own on-screen band) and each bundle clusters its own palette. Overrides
   * `colors`. Each region's `seed` keys its layout so wrap clones match.
   */
  regions?: LavaRegion[];
}

export const LAVA_CONFIG: LavaConfig = {
  background: '#0F0F0F',
  colors: ['#FF3D2E', '#FF8A00', '#E01E8B', '#5B2BFF', '#00C2A8', '#2ED97B'],
  blend: 'multiply',
  blur: 6,
  size: 29,
  points: 8,
  irregularity: 0.34,
  morph: 0.26,
  speed: 0.06,
  drift: 9,
  pointerTracking: true,
  pointerStrength: 9,
  pointerRepel: true,
  blobOpacity: 0.4,
};

interface Blob {
  color: string;
  /** Home position in viewBox units (fixed anchor the blob drifts around). */
  homeX: number;
  homeY: number;
  /** Base radius (viewBox units) before per-point irregularity/morph. */
  radius: number;
  /** Static per-point radius multipliers — the resting (non-circular) shape. */
  shape: number[];
  /** Independent noise offsets so no two blobs drift or morph in sync. */
  seedX: number;
  seedY: number;
  seedShape: number;
  /** Parallax depth — how strongly this blob leans toward the cursor. */
  depth: number;
  /** Hover-scatter target, resolved per hover (see rollScatterTargets). */
  edgeSide?: 'left' | 'right' | 'top' | 'bottom';
  /** 0–1 position along the chosen edge. */
  edgeAlong?: number;
  /** Inset from that edge, held in CSS pixels so it survives a resize. */
  insetPx?: number;
  edgeX?: number;
  edgeY?: number;
}

/**
 * Roll a fresh scatter target per blob: each goes to whichever edge it is
 * already nearest — so the field stays spread around the perimeter and no blob
 * makes a long diagonal trip — but to a random position along that edge,
 * re-rolled on every hover, so it never lands the same way twice.
 */
function rollScatterTargets(blobs: Blob[], config: LavaConfig, vbw: number): void {
  const lo = config.scatterInsetMin ?? 0;
  const hi = config.scatterInsetMax ?? 40;
  for (const b of blobs) {
    const dLeft = b.homeX;
    const dRight = vbw - b.homeX;
    const dTop = b.homeY;
    const dBottom = VB - b.homeY;
    const nearest = Math.min(dLeft, dRight, dTop, dBottom);
    b.edgeSide =
      nearest === dLeft ? 'left' : nearest === dRight ? 'right' : nearest === dTop ? 'top' : 'bottom';
    b.edgeAlong = Math.random();
    b.insetPx = lo + Math.random() * (hi - lo);
  }
}

/** Resolve each blob's stored scatter choice into viewBox coordinates. */
function applyEdgeTargets(blobs: Blob[], vbw: number, pxToVb: number): void {
  for (const b of blobs) {
    const inset = (b.insetPx ?? 0) * pxToVb;
    if (b.edgeSide === 'left' || b.edgeSide === 'right') {
      b.edgeX = b.edgeSide === 'left' ? inset : vbw - inset;
      b.edgeY = (b.edgeAlong ?? 0.5) * VB;
    } else {
      b.edgeX = (b.edgeAlong ?? 0.5) * vbw;
      b.edgeY = b.edgeSide === 'top' ? inset : VB - inset;
    }
  }
}

const VB = 100; // viewBox is 0 0 VB VB
const CENTER = VB / 2;
// Wide-layout region width (viewBox units). ~2:1 vs VB to match a content band's
// on-screen aspect (≈ viewport-width : section-height), so preserveAspectRatio
// ="none" scales near-uniformly and the blobs stay round rather than squished.
const REGION_W = 200;
// Cursor-repel gap radius in viewBox units — no blob centre is allowed nearer
// than this to the cursor, so a clear void opens around a resting pointer.
const GAP_RADIUS = 40;

/**
 * Deterministic pseudo-random in [-1, 1] from two integers — a hash, not RNG,
 * so the server render and first client paint produce the identical resting
 * shape (no hydration mismatch). Noise only animates on top after mount.
 */
function hash(a: number, b: number): number {
  const s = Math.sin(a * 127.1 + b * 311.7) * 43758.5453;
  return (s - Math.floor(s)) * 2 - 1;
}

/**
 * Lay the blobs out on a ring around the centre so their home regions are
 * spread apart, and give each an irregular resting outline. With drift +
 * overlap they merge at the edges without any one blob sitting permanently on
 * top of another.
 */
/** Total viewBox width: REGION_W per bundle, else a single square VB. */
function viewBoxWidth(config: LavaConfig): number {
  return config.regions && config.regions.length > 0
    ? config.regions.length * REGION_W
    : VB;
}

/** Lay one bundle's palette as an (elliptical) ring around a horizontal centre.
    The ring is wider than tall so blobs spread across the ~2:1 band; blob radii
    stay isotropic so they render round under the near-uniform none-scale. */
function buildRegionBlobs(
  colors: string[],
  seed: number,
  centerX: number,
  config: LavaConfig,
): Blob[] {
  const { size, points, irregularity } = config;
  const n = colors.length;
  const ringX = n === 1 ? 0 : REGION_W * 0.3;
  const ringY = n === 1 ? 0 : VB * 0.3;
  return colors.map((color, i) => {
    const angle = (i / n) * Math.PI * 2 - Math.PI / 2 + seed * 1.3;
    const variety = (((i + seed) * 7) % 5) / 5;
    const shape = Array.from(
      { length: points },
      (_, k) => 1 + irregularity * hash(i + 1 + seed * 17, k + 1),
    );
    // Seed the noise tracks by palette identity so bundles sharing a seed
    // (a carousel's wrap clones) move identically.
    const ns = seed * 10 + i;
    return {
      color,
      homeX: centerX + Math.cos(angle) * ringX,
      homeY: CENTER + Math.sin(angle) * ringY,
      // Scale radius by the region:VB ratio so blobs render the same on-screen
      // size as the square layout despite the wide layout's smaller none-scale.
      radius: size * (0.82 + variety * 0.36) * (REGION_W / VB),
      shape,
      seedX: ns * 12.7,
      seedY: ns * 12.7 + 100,
      seedShape: ns * 31.4,
      depth: 0.5 + variety * 0.8,
    };
  });
}

function buildBlobs(config: LavaConfig): Blob[] {
  if (config.regions && config.regions.length > 0) {
    return config.regions.flatMap((region, r) =>
      buildRegionBlobs(region.colors, region.seed ?? r, r * REGION_W + REGION_W / 2, config),
    );
  }
  const { colors, size, points, irregularity } = config;
  const seed = config.seed ?? 0;
  const n = colors.length;
  const ringRadius = n === 1 ? 0 : 30;
  return colors.map((color, i) => {
    // Seed rotates the home ring and offsets every noise track, so separate
    // instances lay out and morph independently rather than sharing one layout.
    const angle = (i / n) * Math.PI * 2 - Math.PI / 2 + seed * 1.3;
    // Per-blob variety in size and depth, derived from the index (+ seed) so it
    // stays deterministic across renders but differs per instance.
    const variety = (((i + seed) * 7) % 5) / 5; // 0, 0.4, 0.8, 0.2, 0.6, …
    // Resting outline: each control point gets its own static radius multiplier
    // so the shape is lumpy (never a circle) even before it starts morphing.
    const shape = Array.from(
      { length: points },
      (_, k) => 1 + irregularity * hash(i + 1 + seed * 17, k + 1),
    );
    return {
      color,
      homeX: CENTER + Math.cos(angle) * ringRadius,
      homeY: CENTER + Math.sin(angle) * ringRadius,
      radius: size * (0.82 + variety * 0.36),
      shape,
      seedX: i * 12.7 + seed * 53.3,
      seedY: i * 12.7 + 100 + seed * 53.3,
      seedShape: i * 31.4 + seed * 71.9,
      depth: 0.5 + variety * 0.8,
    };
  });
}

/**
 * Build a smooth closed SVG path through the blob's control points using a
 * Catmull-Rom → cubic-bézier conversion. `radii[k]` is the distance of point k
 * from the centre; angles are evenly spaced around the circle.
 */
function blobPath(
  cx: number,
  cy: number,
  radii: number[],
  angles: number[],
): string {
  const k = radii.length;
  const px: number[] = new Array(k);
  const py: number[] = new Array(k);
  for (let i = 0; i < k; i++) {
    px[i] = cx + Math.cos(angles[i]) * radii[i];
    py[i] = cy + Math.sin(angles[i]) * radii[i];
  }
  let d = `M ${px[0].toFixed(2)} ${py[0].toFixed(2)}`;
  for (let i = 0; i < k; i++) {
    const p0x = px[(i - 1 + k) % k];
    const p0y = py[(i - 1 + k) % k];
    const p1x = px[i];
    const p1y = py[i];
    const p2x = px[(i + 1) % k];
    const p2y = py[(i + 1) % k];
    const p3x = px[(i + 2) % k];
    const p3y = py[(i + 2) % k];
    const c1x = p1x + (p2x - p0x) / 6;
    const c1y = p1y + (p2y - p0y) / 6;
    const c2x = p2x - (p3x - p1x) / 6;
    const c2y = p2y - (p3y - p1y) / 6;
    d += ` C ${c1x.toFixed(2)} ${c1y.toFixed(2)} ${c2x.toFixed(2)} ${c2y.toFixed(2)} ${p2x.toFixed(2)} ${p2y.toFixed(2)}`;
  }
  return `${d} Z`;
}

export default function LavaBackground({
  config = LAVA_CONFIG,
  active = true,
}: {
  config?: LavaConfig;
  /** When false, the animation loop + listeners are not attached (blobs rest). */
  active?: boolean;
}) {
  const blobs = useMemo(() => buildBlobs(config), [config]);
  const wide = !!config.regions && config.regions.length > 0;
  const vbw = viewBoxWidth(config);
  // Match the square layout's on-screen softness despite the wide layout's
  // smaller none-scale (see the radius scaling in buildRegionBlobs).
  const blur = wide ? config.blur * (REGION_W / VB) : config.blur;
  const angles = useMemo(
    () =>
      Array.from(
        { length: config.points },
        (_, k) => (k / config.points) * Math.PI * 2,
      ),
    [config.points],
  );
  const pathRefs = useRef<(SVGPathElement | null)[]>([]);
  const svgRef = useRef<SVGSVGElement>(null);
  // Stable per-instance filter id (SSR-safe) so multiple mounts don't collide.
  // useId can contain colons, which are invalid in an HTML id attribute (and so
  // in the matching url(#…) reference) — strip them.
  const filterId = `lava-goo-${useId().replace(/:/g, '')}`;

  useEffect(() => {
    const reduceMotion = window.matchMedia(
      '(prefers-reduced-motion: reduce)',
    ).matches;
    if (reduceMotion) return; // static composition — resting shapes stay put.
    if (!active) return; // inactive — do not attach the rAF / listeners.

    // Track on ANY pointing device — a fine cursor (desktop) OR a coarse pointer
    // (touch): `pointermove` fires for touch drags too, so a finger moving across
    // the screen drives the same repel/attract effect as the mouse. (Only devices
    // with no pointer at all — `(pointer: none)` — opt out.)
    const canTrack =
      config.pointerTracking &&
      config.pointerStrength > 0 &&
      window.matchMedia('(pointer: fine), (pointer: coarse)').matches;

    // Hover-scatter: only attached when the config asks for it AND the field
    // sits inside a [data-lava-scope] container, so one field's triggers never
    // move another's blobs (the page-wide field has no scope ancestor).
    const scatterEase = config.scatterEase ?? 0;
    const scope = scatterEase > 0 ? svgRef.current?.closest('[data-lava-scope]') ?? null : null;
    const triggers: Element[] = scope
      ? Array.from(scope.querySelectorAll('[data-lava-scatter]'))
      : [];
    let scatter = 0;
    let scatterTo = 0;

    const pxToVb = () => vbw / Math.max(svgRef.current?.clientWidth ?? 1, 1);
    const onScatterIn = () => {
      rollScatterTargets(blobs, config, vbw);
      applyEdgeTargets(blobs, vbw, pxToVb());
      scatterTo = 1;
    };
    const onScatterOut = () => {
      scatterTo = 0;
    };
    for (const trigger of triggers) {
      trigger.addEventListener('pointerenter', onScatterIn);
      trigger.addEventListener('focus', onScatterIn);
      trigger.addEventListener('pointerleave', onScatterOut);
      trigger.addEventListener('blur', onScatterOut);
    }

    // Drop any refs left over from a longer previous blob set.
    pathRefs.current.length = blobs.length;

    const noiseX = createNoise2D();
    const noiseY = createNoise2D();
    const noiseR = createNoise2D();

    // Cursor state, in viewBox units. current lags target for an eased,
    // "tracking" feel rather than a rigid lock.
    // Repel tracks the cursor in this instance's viewBox coords (per-blob radial
    // push); attract uses a single viewport-centre lean of the whole field.
    // Start off-canvas so nothing is pushed before the first pointer move.
    const repel = config.pointerRepel === true;
    // Scale the repel gap by the region:VB ratio in the wide layout so it opens
    // the same on-screen void as the square layout (smaller none-scale).
    const gapRadius = wide ? GAP_RADIUS * (REGION_W / VB) : GAP_RADIUS;
    let targetX = repel ? -9999 : 0;
    let targetY = repel ? -9999 : 0;
    let curX = targetX;
    let curY = targetY;
    let primed = false;

    // Last pointer screen position. A stationary cursor fires no pointermove,
    // but its position *within* a scrolling section still changes — so we re-map
    // this against the moved section rect on scroll too.
    let lastClientX = 0;
    let lastClientY = 0;
    let hasPointer = false;

    const updateTarget = () => {
      if (repel) {
        const svg = svgRef.current;
        if (!svg) return;
        const rect = svg.getBoundingClientRect();
        if (wide) {
          // preserveAspectRatio="none": each axis maps proportionally.
          targetX = ((lastClientX - rect.left) / rect.width) * vbw;
          targetY = ((lastClientY - rect.top) / rect.height) * VB;
        } else {
          // xMidYMid-slice: uniform scale, centred, so the cursor lines up with
          // what's actually painted.
          const scale = Math.max(rect.width, rect.height) / VB;
          const offX = (rect.width - VB * scale) / 2;
          const offY = (rect.height - VB * scale) / 2;
          targetX = (lastClientX - rect.left - offX) / scale;
          targetY = (lastClientY - rect.top - offY) / scale;
        }
        if (!primed) {
          curX = targetX;
          curY = targetY;
          primed = true;
        }
      } else {
        targetX = (lastClientX / window.innerWidth - 0.5) * 2 * config.pointerStrength;
        targetY = (lastClientY / window.innerHeight - 0.5) * 2 * config.pointerStrength;
      }
    };

    const onPointerMove = (e: PointerEvent) => {
      lastClientX = e.clientX;
      lastClientY = e.clientY;
      hasPointer = true;
      updateTarget();
    };
    // Re-map the last cursor position as the section scrolls under it, so the
    // effect tracks during scroll instead of snapping when the scroll stops.
    const onScroll = () => {
      if (!hasPointer) return;
      updateTarget();
    };
    if (canTrack) {
      window.addEventListener('pointermove', onPointerMove, { passive: true });
      window.addEventListener('scroll', onScroll, { passive: true });
    }

    const k = config.points;
    const radii = new Array(k);
    let raf = 0;
    let start = 0;

    const frame = (now: number) => {
      if (!start) start = now;
      const t = ((now - start) / 1000) * config.speed;

      // The wide layer translates during navigation with no pointer/scroll
      // event firing, which would leave the cursor→viewBox mapping stale and
      // make the repel snap when the mouse next moves. Re-map every frame so the
      // void tracks the cursor's screen position continuously through the slide.
      if (wide && hasPointer) {
        updateTarget();
        // The carousel's wrap-around is an instant translate jump; ease across
        // it and the void would sweep the strip. A jump this large is that snap
        // (a real slide moves the target only gradually) — follow it instantly.
        if (Math.abs(targetX - curX) > REGION_W) {
          curX = targetX;
          curY = targetY;
        }
      }

      curX += (targetX - curX) * 0.05;
      curY += (targetY - curY) * 0.05;
      scatter += (scatterTo - scatter) * scatterEase;
      // Ease the blend itself (smoothstep) so the departure and the return both
      // start and finish gently rather than yanking at the extremes.
      const s = scatter * scatter * (3 - 2 * scatter);

      for (let i = 0; i < blobs.length; i++) {
        const b = blobs[i];
        const el = pathRefs.current[i];
        if (!el) continue;
        // Whole-shape drift (before any cursor influence).
        const bx = b.homeX + noiseX(b.seedX + t, b.seedY) * config.drift;
        const by = b.homeY + noiseY(b.seedX, b.seedY + t) * config.drift;
        let cx = bx;
        let cy = by;
        if (repel) {
          // Keep every blob at least GAP_RADIUS from the cursor: any blob nearer
          // is slid straight out along its away-vector to the gap edge, so the
          // blobs vacate a resting cursor and expose the background behind them.
          const dx = bx - curX;
          const dy = by - curY;
          const dist = Math.hypot(dx, dy) || 0.001;
          const targetDist = Math.max(dist, gapRadius);
          cx = curX + (dx / dist) * targetDist;
          cy = curY + (dy / dist) * targetDist;
        } else {
          // Toward-cursor lean of the whole field.
          cx = bx + curX * b.depth;
          cy = by + curY * b.depth;
        }
        // Blend toward the parked edge position while a trigger is hovered. At
        // s = 1 the blob sits on its edge target, so the cursor repel and the
        // drift above fade out rather than fighting it.
        if (s > 0.001) {
          cx += ((b.edgeX ?? cx) - cx) * s;
          cy += ((b.edgeY ?? cy) - cy) * s;
        }
        // Per-point outline morph — each lobe bulges on its own noise track, so
        // the shape churns like liquid instead of scaling uniformly.
        const r = b.radius + (b.radius * (config.scatterScale ?? 1) - b.radius) * s;
        for (let p = 0; p < k; p++) {
          const wobble = noiseR(b.seedShape + p * 1.7, t + p * 0.35) * config.morph;
          radii[p] = r * (b.shape[p] + wobble);
        }
        el.setAttribute('d', blobPath(cx, cy, radii, angles));
      }
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      for (const trigger of triggers) {
        trigger.removeEventListener('pointerenter', onScatterIn);
        trigger.removeEventListener('focus', onScatterIn);
        trigger.removeEventListener('pointerleave', onScatterOut);
        trigger.removeEventListener('blur', onScatterOut);
      }
      if (canTrack) {
        window.removeEventListener('pointermove', onPointerMove);
        window.removeEventListener('scroll', onScroll);
      }
    };
  }, [blobs, angles, config, wide, vbw, active]);

  return (
    <svg
      ref={svgRef}
      className={styles.svg}
      viewBox={`0 0 ${vbw} ${VB}`}
      preserveAspectRatio={wide ? 'none' : 'xMidYMid slice'}
      aria-hidden="true"
    >
      <defs>
        {/*
          Gooey / metaball filter: blur the blobs, then crush alpha so nearby
          fields fuse into a single lava shape, then soften the fused edge so
          the colours read as a gradient blend rather than hard cutouts.
        */}
        <filter
          id={filterId}
          x="-50%"
          y="-50%"
          width="200%"
          height="200%"
          colorInterpolationFilters="sRGB"
        >
          <feGaussianBlur in="SourceGraphic" stdDeviation={blur} result="blur" />
          <feColorMatrix
            in="blur"
            type="matrix"
            values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 20 -8"
            result="goo"
          />
          <feGaussianBlur in="goo" stdDeviation={blur * 0.4} />
        </filter>
      </defs>

      <rect x="0" y="0" width={vbw} height={VB} fill={config.background} />

      <g filter={`url(#${filterId})`} opacity={config.blobOpacity ?? 1}>
        {blobs.map((b, i) => (
          <path
            key={i}
            ref={(el) => {
              pathRefs.current[i] = el;
            }}
            d={blobPath(
              b.homeX,
              b.homeY,
              b.shape.map((s) => b.radius * s),
              angles,
            )}
            fill={b.color}
            style={{ mixBlendMode: config.blend }}
          />
        ))}
      </g>
    </svg>
  );
}
