/**
 * @stateful -- runs against the Python backend ONLY (local or ECS).
 *
 * These are the round-trips the contract suite cannot check, because Prism
 * replays canned examples and holds no state. Against Prism, "POST a closure
 * then GET Pending" passes without the POST, and "set the loyalty ID then read
 * it back" returns the canned id rather than the one you set. Asserting them
 * there would be theatre.
 *
 * Isolation: every test gets a fresh `customerId` fixture. Without that, a
 * closure raised by one test would make another test's 404 case fail, and the
 * suite would only pass when run in order.
 */

import { test, expect, bearer } from '../src/fixtures.ts';

test.describe('stateful behaviour', () => {
  test.skip(({ target }) => target === 'prism', 'Prism is stateless by design');

  test('x-account-count decides how many accounts the token can see', { tag: '@stateful' }, async ({
    request,
    authenticate,
    customerId,
  }) => {
    for (const accountCount of [1, 5]) {
      // A customer's account count is fixed at FIRST token issue and a later
      // request for a different one is a deliberate 400 -- reseeding would
      // destroy their data (routers/auth.py). So each count needs its own
      // customer, not merely its own token.
      const token = await authenticate({ accountCount, customerId: `${customerId}-n${accountCount}` });
      const response = await request.get('/v1/accounts', { headers: bearer(token) });

      expect(response.status()).toBe(200);
      const body = (await response.json()) as { accounts: unknown[]; count: number };

      expect(body.accounts, `x-account-count: ${accountCount}`).toHaveLength(accountCount);
      expect(body.count).toBe(accountCount);
    }
  });

  test('accounts carry an open or closed status', { tag: '@stateful' }, async ({ request, accessToken }) => {
    const response = await request.get('/v1/accounts', { headers: bearer(accessToken) });
    const body = (await response.json()) as { accounts: Array<{ status: string }> };

    expect(body.accounts.length).toBeGreaterThan(0);
    for (const account of body.accounts) {
      expect(['open', 'closed']).toContain(account.status);
    }
  });

  test('loyalty id set by signup is the id returned by get', { tag: '@stateful' }, async ({
    request,
    accessToken,
  }) => {
    // acc-0002, not acc-0001: the seeded data enrols acc-0001 already, so it
    // cannot demonstrate the not-enrolled -> enrolled transition.
    const accountId = 'acc-0002';

    const before = await request.get('/v1/loyalty', {
      headers: bearer(accessToken),
      params: { accountId },
      failOnStatusCode: false,
    });
    expect(before.status(), 'acc-0002 starts unenrolled in the seed').toBe(404);

    const signup = await request.post('/v1/loyalty/signup', {
      headers: { ...bearer(accessToken), 'Content-Type': 'application/json' },
      data: { accountId, optIn: true },
    });
    expect(signup.status()).toBe(201);
    const enrolled = (await signup.json()) as { loyaltyId: string; accountId: string };
    expect(enrolled.loyaltyId).toBeTruthy();
    expect(enrolled.accountId).toBe(accountId);

    const after = await request.get('/v1/loyalty', {
      headers: bearer(accessToken),
      params: { accountId },
    });
    expect(after.status()).toBe(200);
    const fetched = (await after.json()) as { loyaltyId: string; status: string };

    expect(fetched.loyaltyId, 'get must return the id that signup minted').toBe(enrolled.loyaltyId);
    expect(fetched.status).toBe('active');
  });

  test('signup is idempotent for an already enrolled account', { tag: '@stateful' }, async ({
    request,
    accessToken,
  }) => {
    // The collection documents this: it is what keeps the 201 example
    // satisfiable against seeded data where acc-0001 is already enrolled.
    const existing = await request.get('/v1/loyalty', {
      headers: bearer(accessToken),
      params: { accountId: 'acc-0001' },
    });
    expect(existing.status(), 'acc-0001 starts enrolled in the seed').toBe(200);
    const { loyaltyId } = (await existing.json()) as { loyaltyId: string };

    const again = await request.post('/v1/loyalty/signup', {
      headers: { ...bearer(accessToken), 'Content-Type': 'application/json' },
      data: { accountId: 'acc-0001', optIn: true },
    });
    expect(again.status()).toBe(201);
    expect((await again.json()).loyaltyId, 'must not mint a second id').toBe(loyaltyId);
  });

  test('closure request moves the account from no-request to Pending', { tag: '@stateful' }, async ({
    request,
    accessToken,
  }) => {
    // acc-0002 again: acc-0001 has a seeded Pending closure.
    const accountId = 'acc-0002';

    const before = await request.get(`/v1/accounts/${accountId}/closure`, {
      headers: bearer(accessToken),
      failOnStatusCode: false,
    });
    expect(before.status(), 'acc-0002 has no closure in the seed').toBe(404);

    const requested = await request.post(`/v1/accounts/${accountId}/closure`, {
      headers: { ...bearer(accessToken), 'Content-Type': 'application/json' },
      data: { reason: 'Lorem ipsum relocation', effectiveDate: '2026-09-30' },
    });
    expect(requested.status()).toBe(202);
    const created = (await requested.json()) as { closureRequestId: string; status: string };
    expect(created.status).toBe('Pending');

    const after = await request.get(`/v1/accounts/${accountId}/closure`, { headers: bearer(accessToken) });
    expect(after.status()).toBe(200);
    const status = (await after.json()) as { closureRequestId: string; status: string };

    expect(status.closureRequestId).toBe(created.closureRequestId);
    expect(status.status, 'purpose 8 specifies Pending').toBe('Pending');
  });

  test('payment method survives create, update and delete', { tag: '@stateful' }, async ({
    request,
    accessToken,
  }) => {
    const auth = { ...bearer(accessToken), 'Content-Type': 'application/json' };

    const created = await request.post('/v1/payments/methods', {
      headers: auth,
      data: {
        type: 'card',
        label: 'Sit amet card ending 5454',
        default: false,
        billingAddress: {
          line1: '9 Dolor Way',
          line2: null,
          city: 'Doloropolis',
          region: 'Ametshire',
          postalCode: 'LI3 4TX',
          country: 'GB',
        },
      },
    });
    expect(created.status()).toBe(201);
    const { methodId } = (await created.json()) as { methodId: string };

    const listed = await request.get('/v1/payments/methods', { headers: bearer(accessToken) });
    const list = (await listed.json()) as { methods: Array<{ methodId: string }>; count: number };
    expect(list.methods.map((m) => m.methodId)).toContain(methodId);
    expect(list.count).toBe(list.methods.length);

    // Purpose 5 is specifically about updating the billing address.
    const updated = await request.put(`/v1/payments/methods/${methodId}`, {
      headers: auth,
      data: {
        type: 'card',
        label: 'Sit amet card ending 5454',
        default: true,
        billingAddress: {
          line1: '77 Consectetur Close',
          line2: 'Adipiscing Park',
          city: 'Doloropolis',
          region: 'Ametshire',
          postalCode: 'LI5 6QR',
          country: 'GB',
        },
      },
    });
    expect(updated.status()).toBe(200);

    const reread = await request.get(`/v1/payments/methods/${methodId}`, { headers: bearer(accessToken) });
    const method = (await reread.json()) as {
      default: boolean;
      billingAddress: { line1: string; postalCode: string };
    };
    expect(method.billingAddress.line1).toBe('77 Consectetur Close');
    expect(method.billingAddress.postalCode).toBe('LI5 6QR');
    expect(method.default).toBe(true);

    const deleted = await request.delete(`/v1/payments/methods/${methodId}`, { headers: bearer(accessToken) });
    expect(deleted.status()).toBe(204);

    const gone = await request.get(`/v1/payments/methods/${methodId}`, {
      headers: bearer(accessToken),
      failOnStatusCode: false,
    });
    expect(gone.status()).toBe(404);
  });

  test('the account address resource is read only', { tag: '@stateful' }, async ({ request, accessToken }) => {
    // Purpose 4 says read-only. If a write verb ever appears, this fails.
    for (const method of ['PUT', 'POST', 'DELETE', 'PATCH'] as const) {
      const response = await request.fetch('/v1/accounts/acc-0001/address', {
        method,
        headers: { ...bearer(accessToken), 'Content-Type': 'application/json' },
        data: { line1: 'should not be writable' },
        failOnStatusCode: false,
      });
      expect([404, 405], `${method} on address should not be routed`).toContain(response.status());
    }
  });

  test('protected routes reject a missing or bogus token', { tag: '@stateful' }, async ({ request }) => {
    const protectedPaths = ['/v1/accounts', '/v1/payments/methods', '/v1/loyalty'];

    for (const path of protectedPaths) {
      const missing = await request.get(path, { failOnStatusCode: false });
      expect(missing.status(), `${path} with no token`).toBe(401);

      const bogus = await request.get(path, {
        headers: bearer('not-a-real-token'),
        failOnStatusCode: false,
      });
      expect(bogus.status(), `${path} with a bogus token`).toBe(401);
    }
  });

  test('whoami reports which pool served the request', { tag: '@stateful' }, async ({ request }) => {
    // This is what makes an atomic blue/green swap observable. If it stops
    // working, the harness can no longer demonstrate its central claim.
    const response = await request.get('/v1/whoami');
    expect(response.status()).toBe(200);

    const body = (await response.json()) as { pool: string; version: string; workload: string };
    expect(['blue', 'green']).toContain(body.pool);
    expect(body.version).toBeTruthy();
    expect(['ecs', 'lambda']).toContain(body.workload);
  });
});
