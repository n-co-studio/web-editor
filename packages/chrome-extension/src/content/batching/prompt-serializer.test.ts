import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import type {
  VisualDiff,
  PropertyChange,
  RuleSource,
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
}): VisualDiff {
  const change: PropertyChange = {
    property: 'padding-top',
    fromValue: '8px',
    toValue: '12px',
    ...(opts.source ? { source: opts.source } : {}),
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
