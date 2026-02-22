// ---------------------------------------------------------------------------
// Matched rules cache — WeakMap + LRU + MutationObserver invalidation
// ---------------------------------------------------------------------------

import type { MatchedRule, AccessLevel, MatchResult } from '../../shared/css-types';
import { getMatchedRules } from './css-rules';

const LRU_CAP = 50;

interface CacheEntry {
  version: number;
  rules: MatchedRule[];
  accessLevel: AccessLevel;
  accessMessage?: string;
  excludeSheetsCount: number;
  hasExcludeHost: boolean;
}

/**
 * Caches matched CSS rules per element with automatic invalidation.
 *
 * - Document-level MutationObserver watches for <style>/<link> additions/removals
 *   anywhere in the document (catches CSS-in-JS style injections in <body>).
 * - Element-level MutationObserver watches for class/id changes on the selected
 *   element (which affect rule matching).
 * - LRU cap of 50 element entries.
 * - Inline style changes by the extension (element.style.setProperty) do NOT
 *   invalidate the rule cache.
 */
export class MatchedRulesCache {
  private cache = new WeakMap<Element, CacheEntry>();
  private lruKeys: Element[] = [];
  private globalVersion = 0;
  private documentObserver: MutationObserver | null = null;
  private elementObserver: MutationObserver | null = null;
  private watchedElement: Element | null = null;

  constructor() {
    this.initDocumentObserver();
  }

  /**
   * Get matched rules for an element (cached or freshly computed).
   * Returns null only if element is null/undefined.
   */
  get(
    el: Element,
    excludeSheets?: Set<CSSStyleSheet>,
    excludeHost?: Element,
  ): MatchResult {
    const entry = this.cache.get(el);
    const sheetsCount = excludeSheets?.size ?? 0;
    const hasHost = excludeHost != null;

    if (entry && entry.version === this.globalVersion
      && entry.excludeSheetsCount === sheetsCount
      && entry.hasExcludeHost === hasHost) {
      this.touchLru(el);
      return {
        rules: entry.rules,
        accessLevel: entry.accessLevel,
        accessMessage: entry.accessMessage,
      };
    }

    // Cache miss, stale, or exclusion params changed — recompute
    const result = getMatchedRules(el, excludeSheets, excludeHost);
    this.cache.set(el, {
      version: this.globalVersion,
      rules: result.rules,
      accessLevel: result.accessLevel,
      accessMessage: result.accessMessage,
      excludeSheetsCount: sheetsCount,
      hasExcludeHost: hasHost,
    });
    this.touchLru(el);
    this.evictIfNeeded();

    return result;
  }

  /** Check if an element has cached data without recomputing. */
  has(el: Element): boolean {
    const entry = this.cache.get(el);
    return entry != null && entry.version === this.globalVersion;
  }

  /** Invalidate a specific element's cache, or all entries if no element given. */
  invalidate(el?: Element): void {
    if (el) {
      this.cache.delete(el);
      this.lruKeys = this.lruKeys.filter((k) => k !== el);
    } else {
      // Bump global version — all entries become stale on next access
      this.globalVersion++;
    }
  }

  /**
   * Start watching the selected element for attribute changes
   * that affect rule matching (class, id).
   */
  startWatching(el: Element): void {
    this.stopWatching();
    this.watchedElement = el;
    this.elementObserver = new MutationObserver(() => {
      this.invalidate(el);
    });
    this.elementObserver.observe(el, {
      attributes: true,
      attributeFilter: ['class', 'id'],
    });
  }

  /** Stop watching the previously selected element. */
  stopWatching(): void {
    this.elementObserver?.disconnect();
    this.elementObserver = null;
    this.watchedElement = null;
  }

  /** Disconnect all observers and clear cache state. */
  dispose(): void {
    this.stopWatching();
    this.documentObserver?.disconnect();
    this.documentObserver = null;
    this.lruKeys = [];
    // WeakMap entries are GC'd automatically
  }

  // ---------------------------------------------------------------------------
  // Document-level MutationObserver
  // ---------------------------------------------------------------------------

  private initDocumentObserver(): void {
    this.documentObserver = new MutationObserver((mutations) => {
      let shouldInvalidate = false;

      for (const mutation of mutations) {
        if (mutation.type !== 'childList') continue;

        for (const node of mutation.addedNodes) {
          if (this.isStyleNode(node)) {
            shouldInvalidate = true;
            break;
          }
        }
        if (shouldInvalidate) break;

        for (const node of mutation.removedNodes) {
          if (this.isStyleNode(node)) {
            shouldInvalidate = true;
            break;
          }
        }
        if (shouldInvalidate) break;
      }

      if (shouldInvalidate) {
        this.invalidate(); // bump global version
      }
    });

    this.documentObserver.observe(document, {
      childList: true,
      subtree: true,
    });
  }

  private isStyleNode(node: Node): boolean {
    if (node.nodeType !== Node.ELEMENT_NODE) return false;
    const el = node as Element;
    if (el.tagName === 'STYLE') return true;
    if (el.tagName === 'LINK' && el.getAttribute('rel') === 'stylesheet') return true;
    return false;
  }

  // ---------------------------------------------------------------------------
  // LRU tracking
  // ---------------------------------------------------------------------------

  private touchLru(el: Element): void {
    const idx = this.lruKeys.indexOf(el);
    if (idx !== -1) {
      this.lruKeys.splice(idx, 1);
    }
    this.lruKeys.push(el);
  }

  private evictIfNeeded(): void {
    while (this.lruKeys.length > LRU_CAP) {
      const evicted = this.lruKeys.shift();
      if (evicted) this.cache.delete(evicted);
    }
  }
}
