import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import type {
  VisualDiff,
  PropertyChange,
  RuleSource,
  CrossBreakpointRuleSource,
  PageContext,
} from '@frontend-editor/shared';
import { serializeToPrompt, formatSourceContext } from './prompt-serializer.js';

const baseRect = {
  x: 0, y: 0, width: 100, height: 20,
  top: 0, right: 100, bottom: 20, left: 0,
};

function makeDiff(opts: {
  context?: Partial<PageContext>;
  change?: Partial<PropertyChange>;
  source?: RuleSource;
  allBreakpointSources?: readonly CrossBreakpointRuleSource[];
}): VisualDiff {
  const change: PropertyChange = {
    property: 'padding-top',
    fromValue: '8px',
    toValue: '12px',
    ...(opts.source ? { source: opts.source } : {}),
    ...(opts.allBreakpointSources ? { allBreakpointSources: opts.allBreakpointSources } : {}),
    ...opts.change,
  };
  return {
    id: 'd1',
    timestamp: '2026-05-13T00:00:00Z',
    element: {
      selector: '.card',
      tagName: 'div',
      sourceFile: 'src/Card.tsx',
      sourceLine: 10,
      attributes: {},
      boundingRect: baseRect,
    },
    changes: [change],
    context: {
      url: 'http://localhost',
      viewport: { width: 1280, height: 800 },
      tabId: 't1',
      ...opts.context,
    },
    status: 'pending',
    sourceVerified: true,
  };
}

describe('prompt-serializer breakpoint context', () => {
  it('(a) breakpoint + source matching active breakpoint: heading carries token + value, no per-property annotation, blockquote present', () => {
    const diff = makeDiff({
      context: { breakpoint: 'lg', breakpointValue: '1280px' },
      source: {
        selector: '.card',
        sourceHref: null,
        sourceIndex: 0,
        specificity: [0, 1, 0],
        isInline: false,
        mediaQuery: '1280px',
      },
    });
    const out = serializeToPrompt([diff]);
    assert.match(out, /### `\.card` \(line 10\) — @ lg \(1280px\)\n/);
    assert.doesNotMatch(out, /^- .*\[@ /m);
    assert.match(out, /^> Scope edits to the active breakpoint/m);
  });

  it('(b) breakpoint context, no source: heading carries annotation, no per-property annotation', () => {
    const diff = makeDiff({
      context: { breakpoint: 'md', breakpointValue: '768px' },
    });
    const out = serializeToPrompt([diff]);
    assert.match(out, /### `\.card` \(line 10\) — @ md \(768px\)\n/);
    assert.doesNotMatch(out, /^- .*\[@ /m);
    assert.match(out, /^> Scope edits/m);
  });

  it('(b2) breakpoint token-only (no value): heading carries token alone', () => {
    const diff = makeDiff({
      context: { breakpoint: 'lg' },
    });
    const out = serializeToPrompt([diff]);
    assert.match(out, /### `\.card` \(line 10\) — @ lg\n/);
    assert.match(out, /^> Scope edits/m);
  });

  it('(c) no breakpoint, no source: no heading annotation, no blockquote, no per-property annotation', () => {
    const diff = makeDiff({});
    const out = serializeToPrompt([diff]);
    assert.match(out, /### `\.card` \(line 10\)\n/);
    assert.doesNotMatch(out, / — @ /);
    assert.doesNotMatch(out, /^- .*\[@ /m);
    assert.doesNotMatch(out, /^> Scope edits/m);
  });

  it('(d) source.mediaQuery diverges from active breakpoint: per-property [@ ...] annotation emitted', () => {
    const diff = makeDiff({
      context: { breakpoint: 'lg', breakpointValue: '1280px' },
      source: {
        selector: '.card',
        sourceHref: null,
        sourceIndex: 0,
        specificity: [0, 1, 0],
        isInline: false,
        mediaQuery: '(min-width: 768px)',
      },
    });
    const out = serializeToPrompt([diff]);
    assert.match(out, /### `\.card` \(line 10\) — @ lg \(1280px\)\n/);
    assert.match(out, /- `padding-top`: 8px → 12px \[@ \(min-width: 768px\)\]/);
    assert.match(out, /^> Scope edits/m);
  });

  it('(d2) near-match: "768px" active vs "(min-width: 768px)" source — heuristic treats as divergent', () => {
    const diff = makeDiff({
      context: { breakpoint: 'md', breakpointValue: '768px' },
      source: {
        selector: '.card',
        sourceHref: null,
        sourceIndex: 0,
        specificity: [0, 1, 0],
        isInline: false,
        mediaQuery: '(min-width: 768px)',
      },
    });
    const out = serializeToPrompt([diff]);
    assert.match(out, /\[@ \(min-width: 768px\)\]/);
  });

  it('raw-JSON HTML comment is preserved verbatim', () => {
    const diff = makeDiff({
      context: { breakpoint: 'lg', breakpointValue: '1280px' },
    });
    const out = serializeToPrompt([diff]);
    const m = out.match(/<!-- frontend-editor-raw: (.*?) -->/);
    assert.ok(m, 'raw comment present');
    const parsed = JSON.parse(m![1]);
    assert.equal(parsed.diffs.length, 1);
    assert.equal(parsed.diffs[0].context.breakpoint, 'lg');
  });
});

describe('formatSourceContext helper', () => {
  const baseSource: RuleSource = {
    selector: '.card',
    sourceHref: null,
    sourceIndex: 0,
    specificity: [0, 1, 0],
    isInline: false,
  };

  it('returns "" when source is undefined', () => {
    assert.equal(formatSourceContext(undefined, '1280px'), '');
  });

  it('returns "" when source has no mediaQuery', () => {
    assert.equal(formatSourceContext(baseSource, '1280px'), '');
  });

  it('returns "" when normalised mediaQuery matches active breakpoint', () => {
    assert.equal(
      formatSourceContext({ ...baseSource, mediaQuery: ' 1280PX ' }, '1280px'),
      '',
    );
  });

  it('returns annotation when mediaQuery differs', () => {
    assert.equal(
      formatSourceContext({ ...baseSource, mediaQuery: '(min-width: 768px)' }, '1280px'),
      ' [@ (min-width: 768px)]',
    );
  });

  it('returns annotation when active breakpoint is undefined and source has mediaQuery', () => {
    assert.equal(
      formatSourceContext({ ...baseSource, mediaQuery: '(min-width: 768px)' }, undefined),
      ' [@ (min-width: 768px)]',
    );
  });
});

describe('formatSourceContext cross-breakpoint sub-bullet', () => {
  const baseSource: RuleSource = {
    selector: '.card',
    sourceHref: null,
    sourceIndex: 0,
    specificity: [0, 1, 0],
    isInline: false,
  };

  const crossLg: CrossBreakpointRuleSource = {
    ...baseSource,
    sourceIndex: 1,
    mediaQuery: '(min-width: 1024px)',
    matchesCurrentViewport: false,
  };
  const crossMd: CrossBreakpointRuleSource = {
    ...baseSource,
    sourceIndex: 2,
    mediaQuery: '(min-width: 768px)',
    matchesCurrentViewport: false,
  };

  it('emits sub-bullet when allBreakpointSources is populated', () => {
    const out = formatSourceContext(undefined, '375px', [crossLg, crossMd], 'sm (375px)');
    assert.match(out, /\n {2}- Also defined at: \(min-width: 1024px\), \(min-width: 768px\)\. /);
    assert.match(out, /the active edit applies only to sm \(375px\)\./);
  });

  it('dedups repeated mediaQuery strings — multiple selectors under one @media render once', () => {
    const dupLg: CrossBreakpointRuleSource = {
      ...baseSource,
      selector: '.card .label',
      sourceIndex: 3,
      mediaQuery: '(min-width: 1024px)',
      matchesCurrentViewport: false,
    };
    const out = formatSourceContext(undefined, '375px', [crossLg, dupLg, crossMd], 'sm (375px)');
    assert.match(out, /Also defined at: \(min-width: 1024px\), \(min-width: 768px\)\./);
    assert.doesNotMatch(out, /1024px\), \(min-width: 1024px\)/);
  });

  it('emits no sub-bullet when allBreakpointSources is absent', () => {
    assert.equal(formatSourceContext(undefined, '1280px', undefined, 'lg (1280px)'), '');
  });

  it('emits no sub-bullet when allBreakpointSources is an empty array', () => {
    assert.equal(formatSourceContext(undefined, '1280px', [], 'lg (1280px)'), '');
  });

  it('combines inline source annotation and cross-breakpoint sub-bullet', () => {
    const source: RuleSource = { ...baseSource, mediaQuery: '(min-width: 375px)' };
    const out = formatSourceContext(source, '1280px', [crossLg], 'lg (1280px)');
    assert.match(out, /^ \[@ \(min-width: 375px\)\]\n {2}- Also defined at: \(min-width: 1024px\)\./);
  });

  it('full-pipeline: serializeToPrompt renders sub-bullet beneath property line', () => {
    const diff = makeDiff({
      context: { breakpoint: 'sm', breakpointValue: '375px' },
      allBreakpointSources: [crossLg],
    });
    const out = serializeToPrompt([diff]);
    assert.match(
      out,
      /^- `padding-top`: 8px → 12px\n {2}- Also defined at: \(min-width: 1024px\)\. Do not modify these; the active edit applies only to sm \(375px\)\./m,
    );
  });

  it('full-pipeline: omits sub-bullet when allBreakpointSources absent', () => {
    const diff = makeDiff({ context: { breakpoint: 'sm', breakpointValue: '375px' } });
    const out = serializeToPrompt([diff]);
    assert.doesNotMatch(out, /Also defined at:/);
  });

  it('hasResponsiveContext triggers blockquote when only allBreakpointSources is set', () => {
    const diff = makeDiff({ allBreakpointSources: [crossLg] });
    const out = serializeToPrompt([diff]);
    assert.match(out, /^> Scope edits to the active breakpoint/m);
  });
});

describe('prompt-serializer insert changes', () => {
  function makeInsertDiff(insertChange: VisualDiff['insertChanges']): VisualDiff {
    return {
      id: 'ins1',
      timestamp: '2026-05-13T00:00:00Z',
      element: {
        selector: '.container',
        tagName: 'div',
        sourceFile: 'src/App.tsx',
        sourceLine: 5,
        attributes: {},
        boundingRect: baseRect,
      },
      changes: [],
      insertChanges: insertChange,
      context: { url: 'http://localhost', viewport: { width: 1280, height: 800 }, tabId: 't1' },
      status: 'pending',
      sourceVerified: true,
    };
  }

  it('emits full outerHTML verbatim for clone/duplicate inserts', () => {
    const diff = makeInsertDiff([{
      type: 'insert',
      tagName: 'div',
      insertIndex: 1,
      containerSelector: '.container',
      prevSibling: null,
      nextSibling: null,
      sameSiblingSource: false,
      crossFileInsertion: false,
      initialStyles: [],
      outerHTML: '<div class="card"><span>Hi</span></div>',
    }]);
    const out = serializeToPrompt([diff]);
    assert.match(out, /Full HTML \(reproduce exactly\):/);
    assert.match(out, /<div class="card"><span>Hi<\/span><\/div>/);
  });

  it('renders per-child styles for compound (layout preset) inserts', () => {
    const diff = makeInsertDiff([{
      type: 'insert',
      tagName: 'div',
      insertIndex: 0,
      containerSelector: '.container',
      prevSibling: null,
      nextSibling: null,
      sameSiblingSource: false,
      crossFileInsertion: false,
      initialStyles: [],
      compoundChildren: [
        { tagName: 'div', styles: [{ property: 'flex', value: '2' }] },
        { tagName: 'div', styles: [{ property: 'flex', value: '1' }] },
      ],
    }]);
    const out = serializeToPrompt([diff]);
    assert.match(out, /Children: <div> \{flex: 2\}, <div> \{flex: 1\}/);
  });
});
