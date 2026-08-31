/**
 * @contract -- unit tests for the shape comparison itself. No server, no
 * network: every assertion here is a pure function call.
 *
 * These exist because a bug in shapeMismatches is indistinguishable, from the
 * outside, from a target that breaks the contract. The `prism` project failed
 * on "Payments / List Payment Methods / 200 OK" with
 *
 *   $.methods[1].billingAddress.line2: expected string, got null
 *
 * which cannot be a real contract failure: Prism replays the saved example
 * verbatim, so the response WAS the example. The comparison was reporting the
 * example as violating itself, because it checked every array element against
 * `expected[0]` and line2 is a string in element 0 and null in element 1.
 *
 * The first test below is the general form of that -- it would have caught the
 * bug for any endpoint, without Prism running at all.
 */

import { test, expect } from '../src/fixtures.ts';
import { loadCases } from '../src/collection.ts';
import { shapeMismatches, formatMismatches } from '../src/shape.ts';

test.describe('shape comparison', () => {
  test('every saved example satisfies its own shape', { tag: '@contract' }, () => {
    // The invariant that makes a `prism` failure meaningful. If an example
    // does not match itself then the mock can never be green, and the failure
    // says nothing about the collection or the app.
    const selfInconsistent = loadCases()
      .filter((testCase) => testCase.expectedBody !== undefined)
      .map((testCase) => ({
        id: testCase.id,
        mismatches: shapeMismatches(testCase.expectedBody, testCase.expectedBody),
      }))
      .filter(({ mismatches }) => mismatches.length > 0)
      .map(({ id, mismatches }) => `${id}\n${formatMismatches(mismatches)}`);

    expect(
      selfInconsistent,
      `These examples do not match their own shape, so the comparison is wrong,\n` +
        `not the target:\n\n${selfInconsistent.join('\n\n')}`,
    ).toEqual([]);
  });

  test('a field null in any example element is nullable in all', { tag: '@contract' }, () => {
    const example = [{ line1: 'a', line2: 'b' }, { line1: 'c', line2: null }];

    // The exact regression: element 0 documents a string, element 1 documents
    // the same field as nullable, and both readings must be accepted.
    expect(shapeMismatches([{ line1: 'x', line2: null }], example)).toEqual([]);
    expect(shapeMismatches([{ line1: 'x', line2: 'y' }], example)).toEqual([]);
  });

  test('a field absent from any example element is optional', { tag: '@contract' }, () => {
    const example = [{ id: 'a', nickname: 'n' }, { id: 'b' }];

    expect(shapeMismatches([{ id: 'x' }], example)).toEqual([]);
  });

  test('a field present and typed in every element is still enforced', { tag: '@contract' }, () => {
    // Widening must not become "anything goes" -- a field every element agrees
    // on is the one thing the example does unambiguously document.
    const example = [{ id: 'a', count: 1 }, { id: 'b', count: 2 }];

    expect(shapeMismatches([{ id: 'x', count: 'not-a-number' }], example)).toEqual([
      { path: '$[0].count', expected: 'number', actual: 'string' },
    ]);
    expect(shapeMismatches([{ count: 3 }], example)).toEqual([
      { path: '$[0].id', expected: 'string', actual: 'missing' },
    ]);
  });

  test('merging recurses into nested objects and arrays', { tag: '@contract' }, () => {
    const example = [
      { meta: { tag: 't' }, items: [{ v: 1 }] },
      { meta: { tag: null }, items: [{ v: 2, extra: null }] },
    ];

    expect(shapeMismatches([{ meta: { tag: null }, items: [{ v: 9 }] }], example)).toEqual([]);
    expect(shapeMismatches([{ meta: { tag: 5 }, items: [{ v: 'no' }] }], example)).toEqual([
      { path: '$[0].items[0].v', expected: 'number', actual: 'string' },
    ]);
  });
});
