/**
 * @contract -- runs against BOTH Prism and the Python backend.
 *
 * Generated at run time from postman/awuca.postman_collection.json. There is
 * no per-endpoint test code here and there should never be any: adding a
 * request or an example to the collection is what adds coverage. That is the
 * property ai/tasks/apps.md result #4 depends on.
 *
 * What this proves: for every documented (request, response) pair, the target
 * returns the documented status code and a body of the documented shape.
 *
 * What this deliberately does NOT prove: that state changes. Prism is
 * stateless -- it replays canned examples -- so any assertion about a POST
 * affecting a later GET would either fail against Prism or be too weak to mean
 * anything. Those live in stateful.spec.ts.
 */

import { test, expect, bearer, preferHeaders } from '../src/fixtures.ts';
import { loadCases, requestsWithoutExamples } from '../src/collection.ts';
import { shapeMismatches, formatMismatches } from '../src/shape.ts';

const cases = loadCases();

test.describe('Postman collection contract', () => {
  for (const testCase of cases) {
    test(testCase.id, { tag: '@contract' }, async ({ request, target, authenticate }) => {
      const headers: Record<string, string> = {
        Accept: 'application/json',
        ...testCase.headers,
        ...preferHeaders(target, testCase.expectedCode),
      };

      // The collection's bearer auth is inherited unless the example opts out.
      // The 401 example opts out, which is exactly how it provokes a 401.
      if (!testCase.noAuth) {
        const accountCount = Number(testCase.headers['x-account-count'] ?? 3);
        Object.assign(headers, bearer(await authenticate({ accountCount })));
      }

      const response = await request.fetch(testCase.path, {
        method: testCase.method,
        headers,
        params: testCase.query,
        ...(testCase.body === undefined ? {} : { data: testCase.body }),
        failOnStatusCode: false,
      });

      expect(
        response.status(),
        `${testCase.method} ${testCase.path} returned an undocumented status.\n` +
          `Body: ${(await response.text()).slice(0, 500)}`,
      ).toBe(testCase.expectedCode);

      if (testCase.expectedBody === undefined) {
        expect(await response.text(), 'example documents an empty body').toBe('');
        return;
      }

      const actual = await response.json();
      const mismatches = shapeMismatches(actual, testCase.expectedBody);

      expect(
        mismatches.length,
        `Response shape does not match the saved example.\n${formatMismatches(mismatches)}\n\n` +
          `Actual: ${JSON.stringify(actual).slice(0, 500)}`,
      ).toBe(0);
    });
  }
});

test('every request in the collection has at least one saved example', { tag: '@contract' }, () => {
  // A request with no saved example is invisible to both Prism and to the
  // generator above, so it would silently escape all contract coverage. This
  // guards the guard: without it, deleting every example would turn the suite
  // green rather than red.
  const uncovered = requestsWithoutExamples();
  expect(
    uncovered,
    `These requests have no saved example, so nothing tests them:\n  ${uncovered.join('\n  ')}`,
  ).toEqual([]);
});
