import type { TokenCategory } from '@nco-studio/shared';

/**
 * Which harvest pass surfaced a page value. `custom-property` (a `:root --*`
 * declaration) is the page author's *declared* intent and is treated as
 * highest-confidence — it is exempt from the frequency floor. Confidence order
 * for dedup: `custom-property` > `cssom` > `computed`.
 */
export type InferredOrigin = 'computed' | 'cssom' | 'custom-property';

/**
 * A harvested, normalized, page-observed CSS value offered as an editor default
 * (feature-011). It intentionally **parallels** {@link DesignToken} in shape so
 * editors can render it beside the token path, while being a **distinct type**
 * that never crosses into the token registry or the WebSocket protocol.
 *
 * `InferredOption` is deliberately NOT assignable to `DesignToken`: it has no
 * `name` and no `source` file, and it adds `frequency` / `origin` /
 * `fromPageInference`. This type-level distinction is the first line of defense
 * against a page value being fed into a token-only code path — page values are
 * observed reality, not design intent.
 */
export interface InferredOption {
  /** Normalized, ready-to-apply CSS value (e.g. `#3b82f6`, `16px`, `"Inter", sans-serif`). */
  readonly value: string;
  /** Reuses the existing `TokenCategory` union so editors bucket page values as they bucket tokens. */
  readonly category: TokenCategory;
  /** CSS longhands this option applies to — mirrors `DesignToken.cssProperties`. */
  readonly cssProperties: readonly string[];
  /** How many sampled elements / declarations exhibited this normalized value. The ranking key. */
  readonly frequency: number;
  /** Which harvest pass surfaced the value. */
  readonly origin: InferredOrigin;
  /** Provenance discriminant — always `true`. Marks this as observed reality, not a design token. */
  readonly fromPageInference: true;
  /** Optional short human label (e.g. the source `--custom-property` name); never used as identity. */
  readonly label?: string;
}

/** Rank comparator: frequency desc, deterministic tiebreak on normalized value. */
function rankByFrequency(a: InferredOption, b: InferredOption): number {
  if (b.frequency !== a.frequency) return b.frequency - a.frequency;
  return a.value < b.value ? -1 : a.value > b.value ? 1 : 0;
}

/**
 * Client-side registry parallel to {@link TokenStore} but holding
 * {@link InferredOption}[] indexed by CSS property and category. It is **never**
 * the `TokenStore` and **never** merges into it (feature-011 § Non-Token
 * Semantics). Populated by a completed page harvest when no design tokens exist;
 * cleared (superseded) the moment real tokens arrive over WebSocket.
 */
export class PageValueStore {
  private options: InferredOption[] = [];
  private byCategory = new Map<TokenCategory, InferredOption[]>();
  private byProperty = new Map<string, InferredOption[]>();
  private updateCallbacks: Array<() => void> = [];

  /** True when the store holds at least one harvested page value. */
  get loaded(): boolean {
    return this.options.length > 0;
  }

  /** Replace the store from a completed harvest, ranked by frequency. */
  load(options: readonly InferredOption[]): void {
    this.options = [...options];
    this.rebuildIndexes();
    this.notify();
  }

  /** Property-indexed lookup, ranked by `frequency` desc (parallel to `TokenStore.getForProperty`). */
  getForProperty(cssProperty: string): InferredOption[] {
    return this.byProperty.get(cssProperty) ?? [];
  }

  /** Category lookup, ranked by `frequency` desc. */
  getForCategory(category: TokenCategory): InferredOption[] {
    return this.byCategory.get(category) ?? [];
  }

  /**
   * Drop all page values (called on token supersession). Idempotent and safe to
   * call when the store is already empty — a no-op that skips notification so
   * editors don't re-render spuriously.
   */
  clear(): void {
    if (this.options.length === 0) return;
    this.options = [];
    this.byCategory.clear();
    this.byProperty.clear();
    this.notify();
  }

  /** Register a callback fired on harvest completion or supersession (UI refresh). */
  onUpdate(cb: () => void): void {
    this.updateCallbacks.push(cb);
  }

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

  private rebuildIndexes(): void {
    this.byCategory.clear();
    this.byProperty.clear();

    for (const opt of this.options) {
      const catList = this.byCategory.get(opt.category);
      if (catList) catList.push(opt);
      else this.byCategory.set(opt.category, [opt]);

      for (const prop of opt.cssProperties) {
        const propList = this.byProperty.get(prop);
        if (propList) propList.push(opt);
        else this.byProperty.set(prop, [opt]);
      }
    }

    // Defensive re-sort so lookup order is deterministic even if `load` received
    // an unranked set. The harvester already ranks per category, but a property
    // index can interleave options from multiple source buckets.
    for (const list of this.byProperty.values()) list.sort(rankByFrequency);
    for (const list of this.byCategory.values()) list.sort(rankByFrequency);
  }

  private notify(): void {
    for (const cb of this.updateCallbacks) cb();
  }
}
