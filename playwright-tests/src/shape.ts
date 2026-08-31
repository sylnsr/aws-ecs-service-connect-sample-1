/**
 * Structural comparison of a live response against a saved Postman example.
 *
 * The contract suite runs against two targets that return DIFFERENT DATA for
 * the same contract: Prism replays the canned example verbatim, while the
 * Python backend returns real values (a freshly minted loyaltyId, today's
 * timestamp, an account list sized by x-account-count). Comparing values would
 * therefore fail against Python for reasons that have nothing to do with the
 * contract holding.
 *
 * So we compare SHAPE: key presence and value types, recursively.
 *
 * Four deliberate rules:
 *
 *   1. Extra keys in the response are allowed. Adding a field is a backwards
 *      compatible change and should not fail a consumer's contract test.
 *   2. A null in the example means "nullable, type unspecified" and matches
 *      anything. `billingAddress.line2` is null in the example precisely
 *      because it is optional.
 *   3. An empty array in the response matches a non-empty example array. The
 *      customer may legitimately have zero payment methods; the example only
 *      documents what an element looks like when present.
 *   4. EVERY element of an example array contributes to the element shape,
 *      not just the first. See `mergeShapes`.
 */

export type Mismatch = { path: string; expected: string; actual: string };

function typeName(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Folds every element of an example array into a single element shape.
 *
 * Rules 1-3 are per-field, but the array comparison was per-element: it
 * checked every element of the response against `expected[0]` alone. A saved
 * example is free to vary across its own elements, and the payment methods
 * example does exactly that -- `methods[0].billingAddress.line2` is
 * "Ipsum Quarter" while `methods[1].billingAddress.line2` is null, which is
 * precisely the optional field rule 2 exists for. Checking element 1 against
 * element 0 therefore reported the example as violating itself, and Prism
 * failed on it, because Prism replays the example verbatim.
 *
 * The invariant this restores, and the reason the `prism` project is worth
 * running at all: an example always satisfies its own shape. A failure there
 * is a statement about the collection, never about this comparison.
 *
 * Merging is widest-wins. A field that is null in any element, or absent from
 * any element, is nullable in all of them -- the same conflation of "nullable"
 * and "optional" that rule 2 already makes for a missing key.
 */
function mergeShapes(values: unknown[]): unknown {
  return values.reduce((merged, value) => {
    // Rule 2: a null anywhere makes the field a wildcard.
    if (merged === null || value === null) return null;

    if (Array.isArray(merged) && Array.isArray(value)) return [...merged, ...value];

    if (isPlainObject(merged) && isPlainObject(value)) {
      const keys = new Set([...Object.keys(merged), ...Object.keys(value)]);
      const out: Record<string, unknown> = {};
      for (const key of keys) {
        out[key] =
          key in merged && key in value ? mergeShapes([merged[key], value[key]]) : null;
      }
      return out;
    }

    // Primitives, or a type that differs between elements: keep the first.
    // A genuinely heterogeneous array is not something an example can
    // usefully document, so there is nothing better to say than "like [0]".
    return merged;
  });
}

/**
 * Collects every way `actual` fails to satisfy the shape documented by
 * `expected`. Returns an empty array when the shape holds.
 */
export function shapeMismatches(actual: unknown, expected: unknown, at = '$'): Mismatch[] {
  // Rule 2: null in the example is a wildcard.
  if (expected === null) return [];

  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) {
      return [{ path: at, expected: 'array', actual: typeName(actual) }];
    }
    // Rule 3: nothing to check if either side has no elements to compare.
    if (expected.length === 0 || actual.length === 0) return [];
    // Rule 4: the whole example array defines the element shape, not just [0].
    const element = mergeShapes(expected);
    return actual.flatMap((value, i) => shapeMismatches(value, element, `${at}[${i}]`));
  }

  if (expected && typeof expected === 'object') {
    if (!actual || typeof actual !== 'object' || Array.isArray(actual)) {
      return [{ path: at, expected: 'object', actual: typeName(actual) }];
    }
    const actualObject = actual as Record<string, unknown>;
    return Object.entries(expected as Record<string, unknown>).flatMap(([key, expectedValue]) => {
      if (!(key in actualObject)) {
        // Rule 2 again: a nullable field may be omitted entirely.
        if (expectedValue === null) return [];
        return [{ path: `${at}.${key}`, expected: typeName(expectedValue), actual: 'missing' }];
      }
      return shapeMismatches(actualObject[key], expectedValue, `${at}.${key}`);
    });
    // Rule 1: keys present in actual but absent from expected are not checked.
  }

  // Primitive.
  if (typeName(actual) !== typeName(expected)) {
    return [{ path: at, expected: typeName(expected), actual: typeName(actual) }];
  }
  return [];
}

export function formatMismatches(mismatches: Mismatch[]): string {
  return mismatches
    .map((m) => `  ${m.path}: expected ${m.expected}, got ${m.actual}`)
    .join('\n');
}
