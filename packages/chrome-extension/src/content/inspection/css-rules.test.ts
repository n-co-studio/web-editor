import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Minimal CSSOM + window mocks (no jsdom). The css-rules module checks rule
// types via `instanceof CSSStyleRule` / `CSSMediaRule` / `CSSSupportsRule`
// and via duck-typing for CSSContainerRule. We install global constructors
// here so the runtime checks pass against our test doubles.
// ---------------------------------------------------------------------------

class FakeCSSStyleRule {
  selectorText: string;
  style: { length: number; [i: number]: string; getPropertyValue: (k: string) => string; getPropertyPriority: (k: string) => string };
  constructor(selectorText: string, declarations: Record<string, string>) {
    this.selectorText = selectorText;
    const props = Object.keys(declarations);
    const decls = { ...declarations };
    this.style = {
      length: props.length,
      getPropertyValue: (k: string) => decls[k] ?? '',
      getPropertyPriority: () => '',
    };
    for (let i = 0; i < props.length; i++) (this.style as Record<number, string>)[i] = props[i];
  }
}

class FakeCSSMediaRule {
  conditionText: string;
  cssRules: FakeCSSRuleList;
  constructor(conditionText: string, rules: FakeCSSRule[]) {
    this.conditionText = conditionText;
    this.cssRules = new FakeCSSRuleList(rules);
  }
}

class FakeCSSSupportsRule {
  conditionText: string;
  cssRules: FakeCSSRuleList;
  constructor(conditionText: string, rules: FakeCSSRule[]) {
    this.conditionText = conditionText;
    this.cssRules = new FakeCSSRuleList(rules);
  }
}

class FakeCSSContainerRule {
  containerName: string;
  containerQuery: string;
  cssRules: FakeCSSRuleList;
  constructor(containerQuery: string, rules: FakeCSSRule[]) {
    this.containerName = '';
    this.containerQuery = containerQuery;
    this.cssRules = new FakeCSSRuleList(rules);
  }
}

type FakeCSSRule =
  | FakeCSSStyleRule
  | FakeCSSMediaRule
  | FakeCSSSupportsRule
  | FakeCSSContainerRule;

class FakeCSSRuleList {
  length: number;
  [index: number]: FakeCSSRule;
  constructor(rules: FakeCSSRule[]) {
    this.length = rules.length;
    for (let i = 0; i < rules.length; i++) this[i] = rules[i];
  }
}

interface FakeSheet {
  href: string | null;
  cssRules: FakeCSSRuleList;
  ownerNode?: Node | null;
  _corsThrows?: boolean;
}

function sheetFrom(rules: FakeCSSRule[], opts: { href?: string | null; corsThrows?: boolean } = {}): FakeSheet {
  const list = new FakeCSSRuleList(rules);
  const sheet: FakeSheet = {
    href: opts.href ?? null,
    get cssRules() {
      if (opts.corsThrows) {
        const e: Error & { name?: string } = new Error('cross-origin');
        e.name = 'SecurityError';
        throw e;
      }
      return list;
    },
    _corsThrows: opts.corsThrows,
  } as unknown as FakeSheet;
  return sheet;
}

// Element double — only `.matches(selector)` is exercised. Match any non-empty selector.
function fakeElement(matchedSelectors: string[]): Element {
  return {
    matches(selector: string): boolean {
      return matchedSelectors.includes(selector);
    },
  } as unknown as Element;
}

// ---------------------------------------------------------------------------
// Install globals before importing the module under test.
// ---------------------------------------------------------------------------

interface GlobalsWithCss {
  CSSStyleRule: unknown;
  CSSMediaRule: unknown;
  CSSSupportsRule: unknown;
  CSSContainerRule: unknown;
  document: { styleSheets: FakeSheet[]; adoptedStyleSheets: FakeSheet[] };
  window: { matchMedia: (q: string) => { matches: boolean } };
}

const g = globalThis as unknown as GlobalsWithCss;
g.CSSStyleRule = FakeCSSStyleRule;
g.CSSMediaRule = FakeCSSMediaRule;
g.CSSSupportsRule = FakeCSSSupportsRule;
g.CSSContainerRule = FakeCSSContainerRule;

const sheets: FakeSheet[] = [];
g.document = { styleSheets: sheets, adoptedStyleSheets: [] };

// matchMedia stub — viewport is 800px wide for these tests.
g.window = {
  matchMedia(q: string) {
    // Parse simple `(min-width: Npx)` and `(max-width: Npx)` clauses.
    let matches = true;
    const minWidth = /min-width\s*:\s*(\d+)px/.exec(q);
    if (minWidth) matches = matches && 800 >= parseInt(minWidth[1], 10);
    const maxWidth = /max-width\s*:\s*(\d+)px/.exec(q);
    if (maxWidth) matches = matches && 800 <= parseInt(maxWidth[1], 10);
    return { matches };
  },
};

// Now import the SUT (after globals installed).
// eslint-disable-next-line @typescript-eslint/no-require-imports
const css = await import('./css-rules.js');

function resetSheets(newSheets: FakeSheet[]): void {
  sheets.length = 0;
  for (const s of newSheets) sheets.push(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('getAllBreakpointRules', () => {
  before(() => {
    // smoke: ensure import succeeded with globals available
    assert.equal(typeof css.getAllBreakpointRules, 'function');
  });

  it('returns rules from @media (min-width: 1024px) at viewport 800px with matchesCurrentViewport: false', () => {
    const inactive = new FakeCSSStyleRule('.card', { 'font-size': '18px' });
    const media = new FakeCSSMediaRule('(min-width: 1024px)', [inactive]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 1);
    assert.equal(result.rules[0].mediaQuery, '(min-width: 1024px)');
    assert.equal(result.rules[0].matchesCurrentViewport, false);
    assert.equal(result.accessLevel, 'full');
  });

  it('flags active media as matchesCurrentViewport: true', () => {
    const active = new FakeCSSStyleRule('.card', { 'font-size': '14px' });
    const media = new FakeCSSMediaRule('(min-width: 768px)', [active]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 1);
    assert.equal(result.rules[0].matchesCurrentViewport, true);
  });

  it('excludes @media print', () => {
    const r = new FakeCSSStyleRule('.card', { 'font-size': '12pt' });
    const media = new FakeCSSMediaRule('print', [r]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('excludes @media (hover: hover)', () => {
    const r = new FakeCSSStyleRule('.card', { cursor: 'pointer' });
    const media = new FakeCSSMediaRule('(hover: hover)', [r]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('excludes @media (prefers-color-scheme: dark)', () => {
    const r = new FakeCSSStyleRule('.card', { color: 'white' });
    const media = new FakeCSSMediaRule('(prefers-color-scheme: dark)', [r]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('excludes @media (orientation: portrait)', () => {
    const r = new FakeCSSStyleRule('.card', { display: 'block' });
    const media = new FakeCSSMediaRule('(orientation: portrait)', [r]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('skips CSSContainerRule without throwing', () => {
    const inner = new FakeCSSStyleRule('.card', { width: '50%' });
    const container = new FakeCSSContainerRule('(min-width: 400px)', [inner]);
    resetSheets([sheetFrom([container])]);
    assert.doesNotThrow(() => css.getAllBreakpointRules(fakeElement(['.card'])));
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('CORS-tainted stylesheet contributes to accessLevel: partial', () => {
    const r = new FakeCSSStyleRule('.card', { color: 'red' });
    const media = new FakeCSSMediaRule('(min-width: 1024px)', [r]);
    resetSheets([
      sheetFrom([], { href: 'https://cdn.example.com/x.css', corsThrows: true }),
      sheetFrom([media]),
    ]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.accessLevel, 'partial');
    assert.ok(result.accessMessage);
    // The non-tainted sheet still contributes its rule.
    assert.equal(result.rules.length, 1);
  });

  it('ceiling hit returns partial without throwing', () => {
    const rules: FakeCSSRule[] = [];
    for (let i = 0; i < 10; i++) {
      const inner = new FakeCSSStyleRule(`.card-${i}`, { 'font-size': '14px' });
      rules.push(new FakeCSSMediaRule('(min-width: 1024px)', [inner]));
    }
    resetSheets([sheetFrom(rules)]);
    const result = css.getAllBreakpointRules(
      fakeElement(rules.flatMap((_r, i) => [`.card-${i}`])),
      { ceiling: 3 },
    );
    assert.equal(result.accessLevel, 'partial');
    assert.ok(result.accessMessage?.includes('truncated'));
    // Ceiling counts only style rules processed inside @media; 3 collected.
    assert.equal(result.rules.length, 3);
  });

  it('does not collect top-level (non-@media) style rules', () => {
    // The cascade path covers them; the dormant walk is breakpoint-scoped only.
    const r = new FakeCSSStyleRule('.card', { color: 'blue' });
    resetSheets([sheetFrom([r])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 0);
  });

  it('recurses through @supports inside @media, preserving mediaQuery', () => {
    const r = new FakeCSSStyleRule('.card', { gap: '8px' });
    const supports = new FakeCSSSupportsRule('(display: grid)', [r]);
    const media = new FakeCSSMediaRule('(min-width: 1024px)', [supports]);
    resetSheets([sheetFrom([media])]);
    const result = css.getAllBreakpointRules(fakeElement(['.card']));
    assert.equal(result.rules.length, 1);
    assert.equal(result.rules[0].mediaQuery, '(min-width: 1024px)');
    assert.equal(result.rules[0].matchesCurrentViewport, false);
  });
});

describe('toCrossBreakpointSources', () => {
  it('filters to rules declaring the target property', () => {
    const dormant = [
      {
        selectorText: '.a',
        specificity: [0, 1, 0] as [number, number, number],
        sourceHref: null,
        sourceIndex: 0,
        declarations: new Map([['font-size', '14px']]),
        isInline: false,
        mediaQuery: '(min-width: 1024px)',
        matchesCurrentViewport: false,
      },
      {
        selectorText: '.b',
        specificity: [0, 1, 0] as [number, number, number],
        sourceHref: null,
        sourceIndex: 1,
        declarations: new Map([['color', 'red']]),
        isInline: false,
        mediaQuery: '(min-width: 1024px)',
        matchesCurrentViewport: false,
      },
    ];
    const out = css.toCrossBreakpointSources(dormant, 'font-size', null);
    assert.equal(out.length, 1);
    assert.equal(out[0].selector, '.a');
    assert.equal(out[0].matchesCurrentViewport, false);
  });

  it('dedups the cascade winner from the result', () => {
    const owning = {
      selectorText: '.a',
      specificity: [0, 1, 0] as [number, number, number],
      sourceHref: null,
      sourceIndex: 0,
      declarations: new Map([['font-size', '14px']]),
      isInline: false,
      mediaQuery: '(min-width: 768px)',
    };
    const dormant = [
      // Same rule as owning (active match) — should be dedup'd
      {
        ...owning,
        matchesCurrentViewport: true,
      },
      // Different breakpoint — should be kept
      {
        ...owning,
        sourceIndex: 1,
        mediaQuery: '(min-width: 1024px)',
        matchesCurrentViewport: false,
      },
    ];
    const out = css.toCrossBreakpointSources(dormant, 'font-size', owning);
    assert.equal(out.length, 1);
    assert.equal(out[0].mediaQuery, '(min-width: 1024px)');
  });
});
